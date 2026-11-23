import Foundation
import ProxyMirrorZstd

/// Statically linked Zstandard decoder. No external command or system dylib is needed.
enum ZstdBody {
    static func decode(_ data: Data, limit: Int, allowTruncatedOutput: Bool) -> Result<Data, ContentCoding.DecodeError> {
        guard !data.isEmpty, let decoder = pm_zstd_create() else { return .failure(.invalidStream) }
        defer { pm_zstd_destroy(decoder) }
        return data.withUnsafeBytes { input in
            var offset = 0
            var decoded = Data()
            var chunk = [UInt8](repeating: 0, count: 32 * 1024)
            while !Task.isCancelled {
                var consumed = input.count - offset
                var produced = chunk.count
                let status = chunk.withUnsafeMutableBytes { output in
                    pm_zstd_decode(decoder, input.baseAddress!.advanced(by: offset), &consumed,
                                   output.baseAddress, &produced)
                }
                guard status >= 0 else { return .failure(.invalidStream) }
                offset += consumed
                if produced > max(0, limit) - decoded.count {
                    guard allowTruncatedOutput else { return .failure(.outputLimit) }
                    decoded.append(contentsOf: chunk.prefix(max(0, limit) - decoded.count))
                    return .success(decoded)
                }
                decoded.append(contentsOf: chunk.prefix(produced))
                if status == 0, offset == input.count { return .success(decoded) }
                // A frame may have unconsumed input (concatenated/skippable frames),
                // or buffered output after all compressed input was consumed.
                guard consumed > 0 || produced > 0 else { return .failure(.invalidStream) }
            }
            return .failure(.invalidStream)
        }
    }
}
