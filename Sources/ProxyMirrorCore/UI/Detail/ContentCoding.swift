import zlib
import Foundation

/// Content-Encoding 正文解码：gzip（RFC1952）/ deflate（RFC1950 或 raw RFC1951）/ br / zstd。
/// 流式解码上限 32 MiB，与 BrotliBody 一致。gzip 和 zlib 容器由 zlib 校验。
enum ContentCoding {
    enum DecodeError: Error, Equatable {
        case unsupported([String])   // 不支持的编码组合
        case invalidStream
        case outputLimit
    }

    static let supported: Set<String> = ["gzip", "deflate", "br", "zstd"]
    static let maxDecodedBytes = 32 * 1024 * 1024

    /// 解码成功返回 (数据, 编码标签)；输入未压缩（无编码）返回 nil。
    /// 组合编码（如 "gzip, br"）按声明逆序逐层解开。
    static func decodeIfCompressed(_ data: Data, encodings: [String],
                                   maxOutputBytes: Int = maxDecodedBytes,
                                   allowTruncatedOutput: Bool = false) -> Result<(Data, String), DecodeError>? {
        let list = encodings.map { $0.lowercased() }.filter { !$0.isEmpty && $0 != "identity" }
        guard !list.isEmpty, !data.isEmpty else { return nil }
        let unsupported = list.filter { !supported.contains($0) }
        guard unsupported.isEmpty else { return .failure(.unsupported(list)) }
        var current = data
        var labels: [String] = []
        let layers = Array(list.reversed())
        for (index, coding) in layers.enumerated() {
            let finalLayer = index == layers.count - 1
            let limit = finalLayer ? min(maxDecodedBytes, max(0, maxOutputBytes)) : maxDecodedBytes
            switch inflate(coding: coding, data: current, limit: limit,
                           prefix: finalLayer && allowTruncatedOutput) {
            case .success(let out): current = out; labels.insert(coding, at: 0)
            case .failure(let error): return .failure(error)
            }
        }
        return .success((current, labels.joined(separator: " + ")))
    }

    // MARK: - 单层解码

    private static func inflate(coding: String, data: Data, limit: Int, prefix: Bool) -> Result<Data, DecodeError> {
        if coding == "zstd" {
            return ZstdBody.decode(data, limit: limit, allowTruncatedOutput: prefix)
        }
        if coding == "br" {
            do { return .success(try BrotliBody.decode(data, limit: limit, allowTruncatedOutput: prefix)) }
            catch BrotliBody.DecodeError.outputLimit { return .failure(.outputLimit) }
            catch { return .failure(.invalidStream) }
        }
        let bytes = Array(data.prefix(2))
        guard bytes.count == 2 else { return .failure(.invalidStream) }
        if bytes == [0x1f, 0x8b] {
            return inflateDeflate(data, window: MAX_WBITS + 16, concatenated: true, limit: limit, prefix: prefix)
        }
        let wrapped = bytes[0] & 0x0f == 8 && (Int(bytes[0]) * 256 + Int(bytes[1])) % 31 == 0
        if wrapped {
            let result = inflateDeflate(data, window: MAX_WBITS, concatenated: false, limit: limit, prefix: prefix)
            if case .failure(.invalidStream) = result {
                return inflateDeflate(data, window: -MAX_WBITS, concatenated: false, limit: limit, prefix: prefix)
            }
            return result
        }
        return inflateDeflate(data, window: -MAX_WBITS, concatenated: false, limit: limit, prefix: prefix)
    }

    private static func inflateDeflate(_ data: Data, window: Int32,
                                       concatenated: Bool, limit: Int, prefix: Bool) -> Result<Data, DecodeError> {
        guard data.count <= Int(uInt.max) else { return .failure(.invalidStream) }
        var stream = z_stream()
        guard inflateInit2_(&stream, window, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return .failure(.invalidStream)
        }
        defer { inflateEnd(&stream) }
        return data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var decoded = Data()
            var chunk = [UInt8](repeating: 0, count: 32 * 1024)
            while !Task.isCancelled {
                let previousInput = stream.avail_in
                let result = chunk.withUnsafeMutableBufferPointer { output in
                    stream.next_out = output.baseAddress
                    stream.avail_out = uInt(output.count)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let written = chunk.count - Int(stream.avail_out)
                if written > limit - decoded.count {
                    guard prefix else { return .failure(.outputLimit) }
                    decoded.append(contentsOf: chunk.prefix(limit - decoded.count))
                    return .success(decoded)
                }
                decoded.append(contentsOf: chunk.prefix(written))
                if result == Z_STREAM_END {
                    if stream.avail_in == 0 { return .success(decoded) }
                    guard concatenated, inflateReset2(&stream, window) == Z_OK else {
                        return .failure(.invalidStream)
                    }
                } else if result != Z_OK || (written == 0 && stream.avail_in == previousInput) {
                    return .failure(.invalidStream)
                }
            }
            return .failure(.invalidStream)
        }
    }
}
