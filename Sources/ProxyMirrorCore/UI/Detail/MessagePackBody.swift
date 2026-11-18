import Foundation

/// MessagePack 正文解码（G5）：纯 Swift 实现，覆盖全部常规 format family
/// （int/uint/nil/bool/float/str/bin/array/map/ext/timestamp），
/// 输出保持键序的规范 JSON 文本，交给现有 JSON 高亮/树/查询管线渲染。
enum MessagePackBody {
    enum DecodeError: Error, Equatable {
        case truncated
        case unsupported(UInt8)
        case tooDeep
        case tooLarge
    }

    static let maxDepth = 64
    static let maxElements = 100_000
    static let maxInputBytes = 8 * 1024 * 1024

    /// 解码成功返回规范 JSON（UTF-8）。内容类型或启发式判定为 MessagePack 时才转换；
    /// 已是合法 JSON 的正文不触碰。
    static func decodeIfMessagePack(_ data: Data, contentTypeHint: String = "") -> Data? {
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
        guard let json = try? decodeToJSON(data) else { return nil }
        return Data(json.utf8)
    }

    struct Inspection {
        let data: Data
        let contentType: String
        let decoded: Bool
    }

    static func inspect(_ data: Data, contentType: String) -> Inspection {
        if let decoded = decodeIfMessagePack(data, contentTypeHint: contentType) {
            return Inspection(data: decoded, contentType: "application/json", decoded: true)
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

    static func decodeToJSON(_ data: Data) throws -> String {
        var reader = Reader(data)
        var writer = ""
        try readValue(&reader, into: &writer, depth: 0)
        guard reader.remaining == 0 else { throw DecodeError.truncated }   // 必须整段消费
        return writer
    }

    private static func readValue(_ reader: inout Reader, into out: inout String, depth: Int) throws {
        guard depth <= maxDepth else { throw DecodeError.tooDeep }
        let header = try reader.byte()
        switch header {
        case 0x00...0x7f: out += String(header)
        case 0xe0...0xff: out += String(Int8(bitPattern: header))
        case 0xc0: out += "null"
        case 0xc2: out += "false"
        case 0xc3: out += "true"
        case 0xcc: out += String(try reader.byte())
        case 0xcd: out += String(try reader.u16())
        case 0xce: out += String(try reader.u32())
        case 0xcf: out += String(try reader.u64())
        case 0xd0: out += String(Int8(bitPattern: try reader.byte()))
        case 0xd1: out += String(Int16(bitPattern: try reader.u16()))
        case 0xd2: out += String(Int32(bitPattern: try reader.u32()))
        case 0xd3: out += String(Int64(bitPattern: try reader.u64()))
        case 0xca:
            let bits = try reader.u32()
            out += formatDouble(Double(Float(bitPattern: bits)))
        case 0xcb:
            out += formatDouble(Double(bitPattern: try reader.u64()))
        case 0xa0...0xbf:
            out += try jsonString(reader.take(Int(header & 0x1f)))
        case 0xd9: out += try jsonString(reader.take(Int(try reader.byte())))
        case 0xda: out += try jsonString(reader.take(Int(try reader.u16())))
        case 0xdb: out += try jsonString(reader.take(Int(try reader.u32())))
        case 0xc4...0xc6:                                          // bin 8/16/32 → base64
            let size: Int
            switch header {
            case 0xc4: size = Int(try reader.byte())
            case 0xc5: size = Int(try reader.u16())
            default: size = Int(try reader.u32())
            }
            out += try base64String(reader.take(size))
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
            out += extJSON(type: type, payload: payload)
        default:
            throw DecodeError.unsupported(header)
        }
    }

    private static func readArray(reader: inout Reader, count: Int, into out: inout String, depth: Int) throws {
        guard count <= maxElements else { throw DecodeError.tooLarge }
        out += "["
        for index in 0..<count {
            if index > 0 { out += "," }
            try readValue(&reader, into: &out, depth: depth + 1)
        }
        out += "]"
    }

    private static func readMap(reader: inout Reader, count: Int, into out: inout String, depth: Int) throws {
        guard count <= maxElements else { throw DecodeError.tooLarge }
        out += "{"
        for index in 0..<count {
            if index > 0 { out += "," }
            var key = ""
            try readValue(&reader, into: &key, depth: depth + 1)
            out += key
            out += ":"
            try readValue(&reader, into: &out, depth: depth + 1)
        }
        out += "}"
    }

    // MARK: - JSON 编码辅助

    private static func jsonString(_ bytes: ArraySlice<UInt8>) throws -> String {
        try jsonString([UInt8](bytes))
    }

    private static func jsonString(_ bytes: [UInt8]) throws -> String {
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            return quote(String(decoding: bytes, as: UTF8.self))
        }
        return quote(text)
    }

    private static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private static func base64String(_ bytes: ArraySlice<UInt8>) throws -> String {
        quote(Data(bytes).base64EncodedString())
    }

    /// ext 类型：timestamp（-1）转 ISO8601，其余输出 {"_ext": type, "data": base64}
    private static func extJSON(type: Int8, payload: ArraySlice<UInt8>) -> String {
        let bytes = [UInt8](payload)
        if type == -1, bytes.count == 4 {
            let seconds = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            return quote(Self.timestampFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds))))
        }
        if type == -1, bytes.count == 8 {
            let value = UInt64(bytes[0]) << 56 | UInt64(bytes[1]) << 48 | UInt64(bytes[2]) << 40 | UInt64(bytes[3]) << 32
                | UInt64(bytes[4]) << 24 | UInt64(bytes[5]) << 16 | UInt64(bytes[6]) << 8 | UInt64(bytes[7])
            let seconds = value & 0x3_FF_FF_FF_FF
            let nanos = value >> 34
            return quote(Self.timestampFormatter.string(
                from: Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)))
        }
        let base64 = Data(bytes).base64EncodedString()
        return "{\"_ext\":\(type),\"data\":\(quote(base64))}"
    }

    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func formatDouble(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(format: "%.1f", value)          // 保留小数点，避免整数化歧义
        }
        return String(value)
    }
}
