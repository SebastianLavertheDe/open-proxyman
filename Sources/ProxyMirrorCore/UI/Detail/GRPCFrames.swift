import Foundation
import zlib

enum GRPCFrames {
    static let maxPayload = 1_048_576
    private static let maxFrames = 1024
    private static let maxTrailers = 65_536

    enum Transport: Equatable, Sendable {
        case native, webBinary, webText

        var label: String { self == .native ? "gRPC" : "gRPC-Web" }
    }

    struct MediaType: Equatable, Sendable {
        let rawValue: String
        let transport: Transport
        let format: String

        static let native = MediaType(rawValue: "application/grpc", transport: .native, format: "proto")
    }

    struct Message: Identifiable, Equatable, Sendable {
        let id: Int
        let payloadRange: Range<Int>
        let compressed: Bool
        var byteCount: Int { payloadRange.count }
    }

    struct Scan: Sendable {
        let messages: [Message]
        let trailers: HTTPHeaders
        let issue: String?

        init(messages: [Message], trailers: HTTPHeaders = HTTPHeaders(), issue: String?) {
            self.messages = messages
            self.trailers = trailers
            self.issue = issue
        }
    }

    struct Status {
        let code: String?
        let message: String?
        let details: String?

        var label: String? {
            guard let code else { return nil }
            let names = ["OK", "CANCELLED", "UNKNOWN", "INVALID_ARGUMENT", "DEADLINE_EXCEEDED",
                         "NOT_FOUND", "ALREADY_EXISTS", "PERMISSION_DENIED", "RESOURCE_EXHAUSTED",
                         "FAILED_PRECONDITION", "ABORTED", "OUT_OF_RANGE", "UNIMPLEMENTED", "INTERNAL",
                         "UNAVAILABLE", "DATA_LOSS", "UNAUTHENTICATED"]
            guard let index = Int(code), names.indices.contains(index), String(index) == code else { return code }
            return "\(code) · \(names[index])"
        }
    }

    static func contentType(_ value: String) -> MediaType? {
        let mime = value.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let parts = mime.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard let base = parts.first else { return nil }
        let transport: Transport
        switch base {
        case "application/grpc": transport = .native
        case "application/grpc-web": transport = .webBinary
        case "application/grpc-web-text": transport = .webText
        default: return nil
        }
        let format = parts.count == 2 ? String(parts[1]) : "proto"
        guard !format.isEmpty else { return nil }
        return MediaType(rawValue: mime, transport: transport, format: format)
    }

    static func scan(_ data: Data, complete: Bool, truncated: Bool) -> Scan {
        var scanner = Scanner()
        return scanner.scan(data, complete: complete, truncated: truncated)
    }

    struct Scanner {
        private var messages: [Message] = []
        private var offset = 0
        private var trailers: HTTPHeaders?
        private var textDecoder = WebTextDecoder()

        func frameData(_ data: Data, transport: Transport) -> Data {
            transport == .webText ? textDecoder.decoded : data
        }

        mutating func scan(_ data: Data, complete: Bool, truncated: Bool,
                           transport: Transport = .native, encoding: String? = nil) -> Scan {
            if transport == .webText { textDecoder.append(from: data) }
            let result = scanFrames(frameData(data, transport: transport), complete: complete,
                                    truncated: truncated, web: transport != .native, encoding: encoding)
            if transport == .webText,
               let issue = textDecoder.issue(complete: complete, truncated: truncated) {
                return Scan(messages: result.messages, trailers: result.trailers, issue: issue)
            }
            return result
        }

        private mutating func scanFrames(_ data: Data, complete: Bool, truncated: Bool,
                                         web: Bool, encoding: String?) -> Scan {
            var cursor = data.startIndex + offset
            func result(_ issue: String?) -> Scan {
                Scan(messages: messages, trailers: trailers ?? HTTPHeaders(), issue: issue)
            }
            func partial(_ description: String) -> Scan {
                let detail = truncated ? "捕获已截断" : (complete ? "报文不完整" : "仍在接收")
                return result("\(description) · \(detail)")
            }
            while cursor < data.endIndex {
                guard trailers == nil else {
                    return result("gRPC-Web Trailers 帧之后仍有数据 · 偏移 \(offset)")
                }
                guard data.endIndex - cursor >= 5 else { return partial("消息头不完整 · 偏移 \(offset)") }
                let flag = data[cursor]
                let isTrailer = web && (flag == 0x80 || flag == 0x81)
                guard flag == 0 || flag == 1 || isTrailer else {
                    return result("无效的帧标记 \(flag) · 偏移 \(offset)")
                }
                guard isTrailer || messages.count < maxFrames else {
                    return result("仅列出前 \(maxFrames) 条 gRPC 消息。")
                }
                let size = (Int(data[cursor + 1]) << 24) | (Int(data[cursor + 2]) << 16)
                    | (Int(data[cursor + 3]) << 8) | Int(data[cursor + 4])
                let start = cursor + 5
                if isTrailer && size > maxTrailers {
                    return result("gRPC-Web Trailers 帧超过 64 KiB 解码上限。")
                }
                let available = data.endIndex - start
                guard size <= available else {
                    let kind = isTrailer ? "gRPC-Web Trailers 帧" : "第 \(messages.count + 1) 条消息"
                    return partial("\(kind)声明 \(size) 字节，已捕获 \(available) 字节")
                }
                let message = Message(id: offset, payloadRange: start..<(start + size), compressed: flag & 1 != 0)
                if isTrailer {
                    do {
                        let bytes = try payload(of: message, in: data, encoding: encoding, limit: maxTrailers)
                        trailers = try parseTrailers(bytes)
                    } catch {
                        return result("无法解析 gRPC-Web Trailers · \(error.localizedDescription)")
                    }
                } else {
                    messages.append(message)
                }
                cursor = start + size
                offset = cursor - data.startIndex
            }
            return result(truncated ? "捕获已截断。可能还有后续 gRPC 消息。" : nil)
        }
    }

    // A gRPC-Web text stream can contain separately padded Base64 chunks. Each
    // quartet can be decoded independently of both HTTP chunks and gRPC frames.
    private struct WebTextDecoder {
        private static let alphabet: [UInt8] = {
            var table = [UInt8](repeating: 255, count: 256)
            for (index, byte) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8.enumerated() {
                table[Int(byte)] = UInt8(index)
            }
            table[61] = 64
            return table
        }()

        private(set) var decoded = Data()
        private var readCount = 0
        private var quartet = [UInt8](repeating: 0, count: 4)
        private var quartetCount = 0
        private var invalidOffset: Int?

        mutating func append(from data: Data) {
            guard invalidOffset == nil, readCount < data.count else { return }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(min(32_768, (data.count - readCount) / 4 * 3))
            for byte in data.dropFirst(readCount) {
                if readCount & 0xFFFF == 0 && Task.isCancelled { break }
                readCount += 1
                if byte == 9 || byte == 10 || byte == 13 || byte == 32 { continue }
                let digit = Self.alphabet[Int(byte)]
                guard digit != 255, digit != 64 || quartetCount >= 2 else {
                    invalidOffset = readCount - 1
                    break
                }
                quartet[quartetCount] = digit
                quartetCount += 1
                guard quartetCount == 4 else { continue }
                let a = quartet[0], b = quartet[1], c = quartet[2], d = quartet[3]
                guard c != 64 || d == 64 else {
                    invalidOffset = readCount - 1
                    break
                }
                bytes.append(a << 2 | b >> 4)
                if c != 64 { bytes.append(b << 4 | c >> 2) }
                if d != 64 { bytes.append(c << 6 | d) }
                quartetCount = 0
                if bytes.count >= 32_768 {
                    decoded.append(contentsOf: bytes)
                    bytes.removeAll(keepingCapacity: true)
                }
            }
            decoded.append(contentsOf: bytes)
        }

        func issue(complete: Bool, truncated: Bool) -> String? {
            if let invalidOffset { return "gRPC-Web Base64 无效 · 偏移 \(invalidOffset)" }
            guard quartetCount > 0 else { return nil }
            let detail = truncated ? "捕获已截断" : (complete ? "报文不完整" : "仍在接收")
            return "gRPC-Web Base64 组不完整 · \(detail)"
        }
    }

    private static func parseTrailers(_ data: Data) throws -> HTTPHeaders {
        let malformed = GRPCInspectionError("Trailers 头部格式无效。")
        guard let text = String(data: data, encoding: .utf8) else { throw malformed }
        var lines = text.components(separatedBy: "\r\n")
        if lines.last == "" { lines.removeLast() }
        let punctuation = Set("!#$%&'*+-.^`_|~".utf8)
        var headers = HTTPHeaders()
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw malformed }
            let name = line[..<colon].utf8
            let value = line[line.index(after: colon)...]
            guard !name.isEmpty, name.allSatisfy({ byte in
                (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                    || punctuation.contains(byte)
            }), value.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) }) else { throw malformed }
            headers.append(String(decoding: name, as: UTF8.self).lowercased(),
                           value.trimmingCharacters(in: CharacterSet(charactersIn: " \t")))
        }
        return headers
    }

    static func status(headers: HTTPHeaders, trailers: HTTPHeaders) -> Status {
        func value(_ name: String) -> String? { trailers.value(of: name) ?? headers.value(of: name) }
        let message = value("grpc-message")
        return Status(code: value("grpc-status"), message: message?.removingPercentEncoding ?? message,
                      details: value("grpc-status-details-bin"))
    }

    static func payload(of message: Message, in data: Data, encoding: String?, limit: Int = maxPayload) throws -> Data {
        guard message.byteCount <= limit else {
            throw GRPCInspectionError(limit == maxTrailers ? "消息超过 64 KiB 解码上限。" : "消息超过 1 MiB 解码上限。")
        }
        return try decodePayload(data.subdata(in: message.payloadRange), compressed: message.compressed,
                                 encoding: encoding, limit: limit)
    }

    static func decodePayload(_ payload: Data, compressed: Bool, encoding: String?, limit: Int = maxPayload) throws -> Data {
        guard compressed else { return payload }
        let limitLabel = limit == maxTrailers ? "64 KiB" : "1 MiB"
        switch encoding?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "gzip": return try decompress(payload, window: MAX_WBITS + 16, limit: limit, limitLabel: limitLabel)
        case "deflate": return try decompress(payload, window: MAX_WBITS, limit: limit, limitLabel: limitLabel)
        case nil, "", "identity": throw GRPCInspectionError("压缩标记已设置，缺少可用的 grpc-encoding。")
        default: throw GRPCInspectionError("暂不支持 \(encoding ?? "") 编码。")
        }
    }

    private static func decompress(_ data: Data, window: Int32, limit: Int, limitLabel: String) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, window, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw GRPCInspectionError("无法初始化解压。")
        }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var output = Data()
            var chunk = [UInt8](repeating: 0, count: 16_384)
            while true {
                try Task.checkCancellation()
                let result = chunk.withUnsafeMutableBufferPointer { target in
                    stream.next_out = target.baseAddress
                    stream.avail_out = uInt(target.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let written = chunk.count - Int(stream.avail_out)
                guard output.count + written <= limit else {
                    throw GRPCInspectionError("解压后正文超过 \(limitLabel)。")
                }
                output.append(contentsOf: chunk.prefix(written))
                if result == Z_STREAM_END, stream.avail_in == 0 { return output }
                guard result == Z_OK else { throw GRPCInspectionError("压缩消息损坏或含多余字节。") }
            }
        }
    }
}

struct GRPCInspectionError: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
