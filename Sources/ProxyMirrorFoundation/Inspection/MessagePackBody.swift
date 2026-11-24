import Foundation

/// MessagePack 正文解码（G5）：纯 Swift 实现，覆盖全部常规 format family
/// （int/uint/nil/bool/float/str/bin/array/map/ext/timestamp），
/// 输出保持键序的规范 JSON 文本，交给现有 JSON 高亮/树/查询管线渲染。
/// 非字符串键的 map 表示为 {"_map":[[key,value],...]}，保留键的值类型；
/// 非有限浮点数表示为 {"_float":"NaN"|"Infinity"|"-Infinity"}。
package enum MessagePackBody {
    package enum DecodeError: Error, Equatable, Sendable {
        case truncated
        case unsupported(UInt8)
        case tooDeep
        case tooLarge
        case outputLimit
        case cancelled
    }

    package static let maxDepth = 64
    package static let maxElements = 100_000
    package static let maxInputBytes = 8 * 1024 * 1024
    package static let maxOutputBytes = 1 * 1024 * 1024

    /// 解码成功返回规范 JSON（UTF-8）。内容类型或启发式判定为 MessagePack 时才转换；
    /// 已是合法 JSON 的正文不触碰。
    package static func decodeIfMessagePack(_ data: Data, contentTypeHint: String = "") -> Data? {
        try? conversion(data, contentTypeHint: contentTypeHint)
    }

    private static func conversion(_ data: Data, contentTypeHint: String) throws -> Data? {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= maxInputBytes else { return nil }
        let hint = contentTypeHint.lowercased()
        let hinted = hint.contains("msgpack") || hint.contains("messagepack")
        if hint.contains("json") || hint.contains("xml") || hint.contains("html") || hint.contains("protobuf") {
            return nil
        }
        if !hinted {
            // 启发式：根元素须是 map/array，且整段不是合法 JSON
            guard let first = data.first,
                  [0x80...0x8f, 0x90...0x9f, 0xdc...0xdd, 0xde...0xdf].contains(where: { $0.contains(first) }),
                  (try? JSONSerialization.jsonObject(with: data)) == nil else { return nil }
        } else if (try? JSONSerialization.jsonObject(with: data)) != nil {
            return nil
        }
        let json = try decodeToJSON(data)
        let decoded = Data(json.utf8)
        // Only advertise application/json after checking the complete output,
        // including scalar roots and the representations of non-JSON types.
        guard (try? JSONSerialization.jsonObject(with: decoded, options: [.fragmentsAllowed])) != nil else { return nil }
        return decoded
    }

    package struct Inspection: Sendable {
        package let data: Data
        package let contentType: String
        package let decoded: Bool
        package let issue: DecodeError?
        package init(data: Data, contentType: String, decoded: Bool, issue: DecodeError? = nil) {
            self.data = data; self.contentType = contentType; self.decoded = decoded; self.issue = issue
        }
    }

    package static func inspect(_ data: Data, contentType: String) -> Inspection {
        do {
            if let decoded = try conversion(data, contentTypeHint: contentType) {
                return Inspection(data: decoded, contentType: "application/json", decoded: true)
            }
        } catch is CancellationError {
            return Inspection(data: data, contentType: contentType, decoded: false, issue: .cancelled)
        } catch let error as DecodeError {
            return Inspection(data: data, contentType: contentType, decoded: false, issue: error)
        } catch {
            return Inspection(data: data, contentType: contentType, decoded: false)
        }
        return Inspection(data: data, contentType: contentType, decoded: false)
    }

    // MARK: - 解码

    struct Reader {
        let bytes: [UInt8]
        var index = 0
        init(_ data: Data) { self.bytes = [UInt8](data) }
        mutating func byte() throws -> UInt8 {
            guard index < bytes.count else { throw DecodeError.truncated }
            defer { index += 1 }
            return bytes[index]
        }
        mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, index + n <= bytes.count else { throw DecodeError.truncated }
            defer { index += n }
            return bytes[index..<index + n]
        }
        mutating func u16() throws -> UInt16 { UInt16(try byte()) << 8 | UInt16(try byte()) }
        mutating func u32() throws -> UInt32 { UInt32(try u16()) << 16 | UInt32(try u16()) }
        mutating func u64() throws -> UInt64 { UInt64(try u32()) << 32 | UInt64(try u32()) }
        var remaining: Int { bytes.count - index }
    }

    package static func decodeToJSON(_ data: Data, maximumOutputBytes: Int = maxOutputBytes) throws -> String {
        guard data.count <= maxInputBytes else { throw DecodeError.tooLarge }
        var reader = Reader(data)
        var writer = Writer(limit: maximumOutputBytes)
        try readValue(&reader, into: &writer, depth: 0)
        guard reader.remaining == 0 else { throw DecodeError.truncated }   // 必须整段消费
        return writer.text
    }

    private struct Writer {
        let limit: Int
        var text = ""
        private var bytes = 0
        init(limit: Int) { self.limit = max(0, limit) }
        mutating func append(_ value: String) throws {
            try Task.checkCancellation()
            let count = value.utf8.count
            guard count <= max(0, limit) - bytes else { throw DecodeError.outputLimit }
            text += value; bytes += count
        }
    }

    private static func readValue(_ reader: inout Reader, into out: inout Writer, depth: Int) throws {
        try Task.checkCancellation()
        guard depth <= maxDepth else { throw DecodeError.tooDeep }
        let header = try reader.byte()
        switch header {
        case 0x00...0x7f: try out.append(String(header))
        case 0xe0...0xff: try out.append(String(Int8(bitPattern: header)))
        case 0xc0: try out.append("null")
        case 0xc2: try out.append("false")
        case 0xc3: try out.append("true")
        case 0xcc: try out.append(String(try reader.byte()))
        case 0xcd: try out.append(String(try reader.u16()))
        case 0xce: try out.append(String(try reader.u32()))
        case 0xcf: try out.append(String(try reader.u64()))
        case 0xd0: try out.append(String(Int8(bitPattern: try reader.byte())))
        case 0xd1: try out.append(String(Int16(bitPattern: try reader.u16())))
        case 0xd2: try out.append(String(Int32(bitPattern: try reader.u32())))
        case 0xd3: try out.append(String(Int64(bitPattern: try reader.u64())))
        case 0xca:
            let bits = try reader.u32()
            try out.append(try formatDouble(Double(Float(bitPattern: bits))))
        case 0xcb:
            try out.append(try formatDouble(Double(bitPattern: try reader.u64())))
        case 0xa0...0xbf:
            try out.append(try jsonString(reader.take(Int(header & 0x1f))))
        case 0xd9: try out.append(try jsonString(reader.take(Int(try reader.byte()))))
        case 0xda: try out.append(try jsonString(reader.take(Int(try reader.u16()))))
        case 0xdb: try out.append(try jsonString(reader.take(Int(try reader.u32()))))
        case 0xc4...0xc6:                                          // bin 8/16/32 → base64
            let size: Int
            switch header {
            case 0xc4: size = Int(try reader.byte())
            case 0xc5: size = Int(try reader.u16())
            default: size = Int(try reader.u32())
            }
            try out.append(try base64String(reader.take(size)))
        case 0x90...0x9f: try readArray(reader: &reader, count: Int(header & 0x0f), into: &out, depth: depth)
        case 0xdc: try readArray(reader: &reader, count: Int(try reader.u16()), into: &out, depth: depth)
        case 0xdd: try readArray(reader: &reader, count: Int(try reader.u32()), into: &out, depth: depth)
        case 0x80...0x8f: try readMap(reader: &reader, count: Int(header & 0x0f), into: &out, depth: depth)
        case 0xde: try readMap(reader: &reader, count: Int(try reader.u16()), into: &out, depth: depth)
        case 0xdf: try readMap(reader: &reader, count: Int(try reader.u32()), into: &out, depth: depth)
        case 0xc7...0xc9, 0xd4...0xd8:                             // ext 8/16/32 与 fixext 1/2/4/8/16
            let size: Int
            switch header {
            case 0xc7: size = Int(try reader.byte())
            case 0xc8: size = Int(try reader.u16())
            case 0xc9: size = Int(try reader.u32())
            case 0xd4: size = 1
            case 0xd5: size = 2
            case 0xd6: size = 4
            case 0xd7: size = 8
            default: size = 16
            }
            let type = Int8(bitPattern: try reader.byte())
            let payload = try reader.take(size)
            try out.append(try extJSON(type: type, payload: payload))
        default:
            throw DecodeError.unsupported(header)
        }
    }

    private static func readArray(reader: inout Reader, count: Int, into out: inout Writer, depth: Int) throws {
        guard count <= maxElements else { throw DecodeError.tooLarge }
        try out.append("[")
        for index in 0..<count {
            if index > 0 { try out.append(",") }
            try readValue(&reader, into: &out, depth: depth + 1)
        }
        try out.append("]")
    }

    private static func readMap(reader: inout Reader, count: Int, into out: inout Writer, depth: Int) throws {
        guard count <= maxElements else { throw DecodeError.tooLarge }
        var entries: [(key: String, value: String)] = []
        entries.reserveCapacity(count)
        var onlyStringKeys = true
        var entryBytes = 0
        for _ in 0..<count {
            guard reader.remaining > 0 else { throw DecodeError.truncated }
            let header = reader.bytes[reader.index]
            onlyStringKeys = onlyStringKeys && ((0xa0...0xbf).contains(header) || (0xd9...0xdb).contains(header))
            var key = Writer(limit: out.limit)
            try readValue(&reader, into: &key, depth: depth + 1)
            var value = Writer(limit: out.limit)
            try readValue(&reader, into: &value, depth: depth + 1)
            entryBytes += key.text.utf8.count + value.text.utf8.count + 2
            guard entryBytes < out.limit else { throw DecodeError.outputLimit }
            entries.append((key.text, value.text))
        }
        try out.append(onlyStringKeys ? "{" : "{\"_map\":[")
        for (index, entry) in entries.enumerated() {
            if index > 0 { try out.append(",") }
            if !onlyStringKeys { try out.append("[") }
            try out.append(entry.key)
            try out.append(onlyStringKeys ? ":" : ",")
            try out.append(entry.value)
            if !onlyStringKeys { try out.append("]") }
        }
        try out.append(onlyStringKeys ? "}" : "]}")
    }

    // MARK: - JSON 编码辅助

    private static func jsonString(_ bytes: ArraySlice<UInt8>) throws -> String {
        try jsonString([UInt8](bytes))
    }

    private static func jsonString(_ bytes: [UInt8]) throws -> String {
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            return try quote(String(decoding: bytes, as: UTF8.self))
        }
        return try quote(text)
    }

    private static func quote(_ text: String) throws -> String {
        var out = Writer(limit: maxOutputBytes)
        try out.append("\"")
        let digits = Array("0123456789abcdef".utf8)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": try out.append("\\\"")
            case "\\": try out.append("\\\\")
            case "\n": try out.append("\\n")
            case "\r": try out.append("\\r")
            case "\t": try out.append("\\t")
            default:
                if scalar.value < 0x20 {
                    let value = Int(scalar.value)
                    try out.append(String(decoding: [92, 117, 48, 48, digits[value >> 4], digits[value & 15]], as: UTF8.self))
                } else {
                    try out.append(String(scalar))
                }
            }
        }
        try out.append("\"")
        return out.text
    }

    private static func base64String(_ bytes: ArraySlice<UInt8>) throws -> String {
        try quote(Data(bytes).base64EncodedString())
    }

    /// ext 类型：timestamp（-1）转 ISO8601，其余输出 {"_ext": type, "data": base64}
    private static func extJSON(type: Int8, payload: ArraySlice<UInt8>) throws -> String {
        let bytes = [UInt8](payload)
        if type == -1, bytes.count == 4 {
            let seconds = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            return try quote(Self.timestampFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds))))
        }
        if type == -1, bytes.count == 8 {
            let value = UInt64(bytes[0]) << 56 | UInt64(bytes[1]) << 48 | UInt64(bytes[2]) << 40 | UInt64(bytes[3]) << 32
                | UInt64(bytes[4]) << 24 | UInt64(bytes[5]) << 16 | UInt64(bytes[6]) << 8 | UInt64(bytes[7])
            let seconds = value & 0x3_FF_FF_FF_FF
            let nanos = value >> 34
            return try quote(Self.timestampFormatter.string(
                from: Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)))
        }
        let base64 = Data(bytes).base64EncodedString()
        return "{\"_ext\":\(type),\"data\":\(try quote(base64))}"
    }

    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func formatDouble(_ value: Double) throws -> String {
        guard value.isFinite else {
            let name = value.isNaN ? "NaN" : value.sign == .minus ? "-Infinity" : "Infinity"
            return "{\"_float\":" + (try quote(name)) + "}"
        }
        if value == value.rounded() && abs(value) < 1e15 {
            return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value) // 保留小数点，避免整数化歧义
        }
        return String(value)
    }
}
