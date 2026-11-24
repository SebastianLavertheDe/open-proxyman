import Foundation

/// Formatting consumes immutable decoded bytes on a worker. Limits apply while
/// producing lines, before allocating a complete hex dump or line array.
package enum BoundedDiffDocument {
    package static let bodyLimit = 262_144
    package static let lineLimit = 1200
    package static let outputLimit = 1024 * 1024

    package struct Header: Hashable, Sendable {
        package let name: String
        package let value: String
        package init(_ name: String, _ value: String) { self.name = name; self.value = value }
    }
    package struct Messages: Sendable {
        package let unavailable: String
        package let bodyLimited: String
        package let linesLimited: String
        package let outputLimited: String
        package init(unavailable: String, bodyLimited: String, linesLimited: String, outputLimited: String? = nil) {
            self.unavailable = unavailable; self.bodyLimited = bodyLimited; self.linesLimited = linesLimited
            self.outputLimited = outputLimited ?? linesLimited
        }
    }
    package struct Input: Sendable {
        package let startLine: String?
        package let headers: [Header]
        package let includesBody: Bool
        package let body: Data?
        package let bodyWasLimited: Bool
        package init(startLine: String? = nil, headers: [Header] = [], includesBody: Bool,
                     body: Data? = nil, bodyWasLimited: Bool = false) {
            self.startLine = startLine; self.headers = headers; self.includesBody = includesBody
            self.body = body; self.bodyWasLimited = bodyWasLimited
        }
    }

    package static func lines(_ input: Input, sortJSON: Bool, sortHeaders: Bool, messages: Messages) throws -> [String] {
        try Task.checkCancellation()
        var result: [String] = [], bytes = 0, limited = false, byteLimited = false
        func append(_ line: String) -> Bool {
            guard result.count < lineLimit else { limited = true; return false }
            let available = outputLimit - bytes
            guard line.utf8.count <= available else {
                if available > 0 { result.append(utf8Prefix(line, limit: available)); bytes = outputLimit }
                limited = true; byteLimited = true; return false
            }
            result.append(line); bytes += line.utf8.count
            return true
        }
        if let start = input.startLine { _ = append(start) }
        let headers = sortHeaders ? input.headers.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.value < $1.value : order == .orderedAscending
        } : input.headers
        for field in headers {
            try Task.checkCancellation()
            let line = utf8Prefix(field.name, limit: outputLimit) + ": " + utf8Prefix(field.value, limit: outputLimit)
            guard append(line) else { break }
        }
        if input.includesBody, !limited {
            if input.startLine != nil || !headers.isEmpty { _ = append("") }
            if let original = input.body {
                let data = Data(original.prefix(bodyLimit))
                var formatted = false
                if sortJSON, !data.isEmpty {
                    try Task.checkCancellation()
                    if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                        // Stream pretty lines into the budget. Serializing the
                        // whole object first can amplify deeply indented JSON.
                        do {
                            _ = try BoundedJSONWriter.write(object, maximumLineBytes: outputLimit, append: append)
                        } catch BoundedJSONWriter.Failure.lineLimit { limited = true; byteLimited = true }
                        formatted = true
                    }
                }
                try Task.checkCancellation()
                if !formatted, let text = String(data: data, encoding: .utf8) {
                    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                    var remaining = normalized[...]
                    while true {
                        try Task.checkCancellation()
                        guard let newline = remaining.firstIndex(of: "\n") else {
                            _ = append(String(remaining)); break
                        }
                        guard append(String(remaining[..<newline])) else { break }
                        remaining = remaining[remaining.index(after: newline)...]
                    }
                } else if !formatted {
                    let digits = Array("0123456789abcdef".utf8)
                    try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                        for offset in stride(from: 0, to: raw.count, by: 16) {
                            try Task.checkCancellation()
                            guard result.count < lineLimit else { limited = true; break }
                            var line: [UInt8] = []
                            line.reserveCapacity(58)
                            for shift in stride(from: 28, through: 0, by: -4) { line.append(digits[(offset >> shift) & 15]) }
                            line.append(contentsOf: [32, 32])
                            for index in offset..<min(raw.count, offset + 16) {
                                if index != offset { line.append(32) }
                                line.append(digits[Int(raw[index] >> 4)]); line.append(digits[Int(raw[index] & 15)])
                            }
                            guard append(String(decoding: line, as: UTF8.self)) else { break }
                        }
                    }
                }
                if !limited, input.bodyWasLimited || original.count > bodyLimit { _ = append(messages.bodyLimited) }
            } else { _ = append(messages.unavailable) }
        }
        try Task.checkCancellation()
        if limited { result.append(byteLimited ? messages.outputLimited : messages.linesLimited) }
        return result
    }

    private static func utf8Prefix(_ text: String, limit: Int) -> String {
        let bytes = text.utf8
        guard bytes.count > limit else { return text }
        var end = bytes.index(bytes.startIndex, offsetBy: max(0, limit))
        while end > bytes.startIndex, bytes[end] & 0xc0 == 0x80 { end = bytes.index(before: end) }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
}
