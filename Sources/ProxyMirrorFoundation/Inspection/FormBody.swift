import Foundation

package enum FormBody {
    package struct Part: Sendable, Equatable {
        package let name: String
        package let filename: String?
        package let contentType: String
        package let range: Range<Int>
    }
    package struct Multipart: Sendable {
        package let parts: [Part]
        package let complete: Bool
    }

    package static func urlEncoded(_ data: Data) -> [(String, String)] {
        guard !data.isEmpty else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "&", omittingEmptySubsequences: false).map { entry in
            let pair = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ value: Substring) -> String {
                let replaced = value.replacingOccurrences(of: "+", with: " ")
                return replaced.removingPercentEncoding ?? replaced
            }
            return (decode(pair[0]), pair.count > 1 ? decode(pair[1]) : "")
        }
    }

    package static func multipart(_ data: Data, contentType: String) -> Multipart? {
        guard let boundary = parameter("boundary", in: contentType), !boundary.isEmpty,
              boundary.utf8.count <= 70, !boundary.contains("\r"), !boundary.contains("\n") else { return nil }
        let opening = Data("--\(boundary)".utf8), delimiter = Data("\r\n--\(boundary)".utf8)
        var parts: [Part] = [], cursor: Int
        if data.starts(with: opening) { cursor = opening.count }
        else if let first = data.range(of: delimiter) { cursor = first.upperBound }
        else { return Multipart(parts: [], complete: false) }
        while cursor <= data.count, parts.count < 10_000 {
            if data[cursor...].starts(with: Data("--".utf8)) {
                let after = cursor + 2
                return Multipart(parts: parts, complete: after == data.count || data[after...].starts(with: Data("\r\n".utf8)))
            }
            guard data[cursor...].starts(with: Data("\r\n".utf8)) else { return Multipart(parts: parts, complete: false) }
            cursor += 2
            guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8), in: cursor..<data.count),
                  headerEnd.lowerBound - cursor <= 65_536 else { return Multipart(parts: parts, complete: false) }
            let header = String(decoding: data[cursor..<headerEnd.lowerBound], as: UTF8.self)
            let start = headerEnd.upperBound
            var search = start, next: Range<Int>?
            while search < data.count, let candidate = data.range(of: delimiter, in: search..<data.count) {
                let suffix = data[candidate.upperBound...]
                let closing = suffix.starts(with: Data("--".utf8)) && (suffix.count == 2 || suffix.dropFirst(2).starts(with: Data("\r\n".utf8)))
                if suffix.starts(with: Data("\r\n".utf8)) || closing { next = candidate; break }
                search = candidate.upperBound
            }
            guard let next else { return Multipart(parts: parts, complete: false) }
            let headers = header.components(separatedBy: "\r\n").compactMap { line -> (String, String)? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
            let disposition = headers.first { $0.0 == "content-disposition" }?.1 ?? ""
            parts.append(Part(name: parameter("name", in: disposition) ?? "", filename: parameter("filename", in: disposition),
                              contentType: headers.first { $0.0 == "content-type" }?.1 ?? "text/plain", range: start..<next.lowerBound))
            cursor = next.upperBound
        }
        return Multipart(parts: parts, complete: false)
    }

    private static func parameter(_ key: String, in value: String) -> String? {
        // Split only unquoted semicolons, retaining quoted file names and escaped quotes.
        var fields: [String] = [], field = "", quoted = false, escaped = false
        for character in value {
            if escaped { field.append(character); escaped = false; continue }
            if character == "\\", quoted { escaped = true; continue }
            if character == "\"" { quoted.toggle(); field.append(character) }
            else if character == ";", !quoted { fields.append(field); field = "" }
            else { field.append(character) }
        }
        fields.append(field)
        for field in fields.dropFirst() {
            let pair = field.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].lowercased() == key {
                return pair[1].hasPrefix("\"") && pair[1].hasSuffix("\"") ? String(pair[1].dropFirst().dropLast()) : pair[1]
            }
        }
        return nil
    }
}
