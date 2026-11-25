import Foundation

/// Schema-free Tars/JCE inspection. JSON object keys are wire tags, never
/// guessed business field names. Maps retain typed keys as key/value pairs.
/// Wire format: https://tarscloud.github.io/TarsDocs/base/tars-protocol.html
package enum TarsBody {
    package enum DecodeError: Error, Equatable { case invalidStream, tooDeep, tooLarge, outputLimit }
    package static let maxInputBytes = 8 * 1024 * 1024
    package static let maxOutputBytes = 1 * 1024 * 1024
    private static let maxElements = 100_000
    private static let maxDepth = 64

    package static func decodeIfTars(_ data: Data, contentTypeHint: String = "",
                                     allowUnhinted: Bool = false) throws -> Data? {
        let mime = contentTypeHint.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let hinted = ["application/tars", "application/x-tars", "application/jce", "application/x-jce"].contains(mime)
        guard hinted || (allowUnhinted && ["", "application/octet-stream", "binary/octet-stream",
            "application/gzip", "application/x-gzip"].contains(mime)) else { return nil }
        guard !data.isEmpty else { return nil }
        guard data.count <= maxInputBytes else { throw DecodeError.tooLarge }
        try Task.checkCancellation()
        var reader = Reader(bytes: Array(data))
        let root: [String: Any]
        do { root = try reader.fields(depth: 0, terminated: false) }
        catch is CancellationError { throw CancellationError() }
        catch { if hinted { throw error }; return nil }
        // Unlabelled binary has no format magic. Require a complete, ordered
        // multi-field message with both numbers and readable strings; a byte or
        // arbitrary binary prefix must not become an invented JSON object.
        guard hinted || (root.count >= 3 && reader.numbers > 0 && reader.readableStrings > 0) else { return nil }
        var output = Data()
        let completed: Bool
        do {
            completed = try BoundedJSONWriter.write(root, maximumLineBytes: maxOutputBytes) { line in
                let separator = output.isEmpty ? 0 : 1
                guard separator + line.utf8.count <= maxOutputBytes - output.count else { return false }
                if separator > 0 { output.append(10) }
                output.append(contentsOf: line.utf8)
                return true
            }
        } catch BoundedJSONWriter.Failure.lineLimit { throw DecodeError.outputLimit }
        guard completed else { throw DecodeError.outputLimit }
        return output
    }

    private struct Header { let tag: Int; let type: UInt8 }
    private struct Reader {
        let bytes: [UInt8]
        var index = 0
        var elements = 0
        var readableStrings = 0
        var numbers = 0
        var remaining: Int { bytes.count - index }

        mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, count <= remaining else { throw DecodeError.invalidStream }
            defer { index += count }
            return bytes[index..<index + count]
        }
        mutating func unsigned(_ count: Int) throws -> UInt64 {
            try take(count).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        mutating func header() throws -> Header {
            let byte = UInt8(try unsigned(1))
            let tag = byte >> 4 == 15 ? Int(try unsigned(1)) : Int(byte >> 4)
            guard byte & 15 <= 13 else { throw DecodeError.invalidStream }
            return Header(tag: tag, type: byte & 15)
        }
        mutating func integer(_ type: UInt8) throws -> Int64 {
            switch type {
            case 0: return Int64(Int8(bitPattern: UInt8(try unsigned(1))))
            case 1: return Int64(Int16(bitPattern: UInt16(try unsigned(2))))
            case 2: return Int64(Int32(bitPattern: UInt32(try unsigned(4))))
            case 3: return Int64(bitPattern: try unsigned(8))
            case 12: return 0
            default: throw DecodeError.invalidStream
            }
        }
        mutating func count(maximum: Int = TarsBody.maxElements) throws -> Int {
            let head = try header()
            guard head.tag == 0, [0, 1, 2, 12].contains(head.type) else { throw DecodeError.invalidStream }
            let value = try integer(head.type)
            guard value >= 0, value <= Int64(maximum) else { throw DecodeError.tooLarge }
            return Int(value)
        }
        mutating func fields(depth: Int, terminated: Bool) throws -> [String: Any] {
            guard depth <= TarsBody.maxDepth else { throw DecodeError.tooDeep }
            var result: [String: Any] = [:]
            var previousTag = -1
            while remaining > 0 {
                let head = try header()
                if head.type == 11 {
                    guard terminated, head.tag == 0 else { throw DecodeError.invalidStream }
                    return result
                }
                guard head.tag > previousTag else { throw DecodeError.invalidStream }
                previousTag = head.tag
                result[String(head.tag)] = try value(head.type, depth: depth)
            }
            guard !terminated else { throw DecodeError.invalidStream }
            return result
        }
        mutating func value(_ type: UInt8, depth: Int) throws -> Any {
            try Task.checkCancellation()
            guard depth <= TarsBody.maxDepth else { throw DecodeError.tooDeep }
            elements += 1
            guard elements <= TarsBody.maxElements else { throw DecodeError.tooLarge }
            switch type {
            case 0...3, 12:
                numbers += 1
                return try integer(type)
            case 4, 5:
                numbers += 1
                let value = type == 4 ? Double(Float(bitPattern: UInt32(try unsigned(4))))
                    : Double(bitPattern: try unsigned(8))
                return value.isFinite ? value as Any : ["_float": value.isNaN ? "NaN" : (value > 0 ? "Infinity" : "-Infinity")]
            case 6, 7:
                let length = Int(try unsigned(type == 6 ? 1 : 4))
                guard length <= TarsBody.maxOutputBytes else { throw DecodeError.outputLimit }
                let data = Data(try take(length))
                if let text = String(data: data, encoding: .utf8) {
                    if !text.isEmpty, !data.contains(where: { $0 < 32 && $0 != 9 && $0 != 10 && $0 != 13 }) { readableStrings += 1 }
                    return text
                }
                return try binary(data)
            case 8:
                let size = try count()
                guard size <= remaining / 2 else { throw DecodeError.invalidStream }
                var pairs: [[Any]] = []
                for _ in 0..<size {
                    let key = try header()
                    guard key.tag == 0 else { throw DecodeError.invalidStream }
                    let keyValue = try value(key.type, depth: depth + 1)
                    let item = try header()
                    guard item.tag == 1 else { throw DecodeError.invalidStream }
                    pairs.append([keyValue, try value(item.type, depth: depth + 1)])
                }
                return ["_map": pairs]
            case 9:
                let size = try count()
                guard size <= remaining else { throw DecodeError.invalidStream }
                var values: [Any] = []
                for _ in 0..<size {
                    let item = try header()
                    guard item.tag == 0 else { throw DecodeError.invalidStream }
                    values.append(try value(item.type, depth: depth + 1))
                }
                return values
            case 10: return try fields(depth: depth + 1, terminated: true)
            case 13:
                let subtype = try header()
                guard subtype.tag == 0, subtype.type == 0 else { throw DecodeError.invalidStream }
                let size = try count(maximum: TarsBody.maxInputBytes)
                guard size <= remaining else { throw DecodeError.invalidStream }
                guard size <= TarsBody.maxOutputBytes / 4 * 3 else { throw DecodeError.outputLimit }
                return try binary(Data(take(size)))
            default: throw DecodeError.invalidStream
            }
        }
        func binary(_ data: Data) throws -> [String: String] {
            guard data.count <= TarsBody.maxOutputBytes / 4 * 3 else { throw DecodeError.outputLimit }
            return ["_bytes": data.base64EncodedString()]
        }
    }
}
