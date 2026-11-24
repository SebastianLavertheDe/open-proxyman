import Foundation

/// List metadata only. The caller supplies an immutable, already decoded body;
/// full GraphQL detail/variables rendering remains in the inspector pipeline.
package enum GraphQLColumnValue {
    package static let maximumInputBytes = 262_144
    package static let maximumValueBytes = 2_000
    private static let operation = try! NSRegularExpression(
        pattern: #"^\s*(query|mutation|subscription)\s+([_A-Za-z][_0-9A-Za-z]*)?"#,
        options: [.caseInsensitive])

    package static func operationName(path: String, query: String, contentType: String, body: Data) -> String {
        displayName(operationNameForMatching(path: path, query: query, contentType: contentType, body: body))
    }

    /// Matching preserves the full name: a display truncation must not change equals/regex predicates.
    package static func operationNameForMatching(path: String, query: String, contentType: String, body: Data) -> String {
        guard !Task.isCancelled, body.count <= maximumInputBytes else { return "" }
        var document: String?, declared: String?
        let media = contentType.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces).lowercased()
        if !body.isEmpty {
            if media == "application/graphql" { document = String(decoding: body, as: UTF8.self) }
            else if let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                    object["query"] is String || object["extensions"] is [String: Any] {
                document = object["query"] as? String ?? ""
                declared = object["operationName"] as? String
            }
        }
        guard !Task.isCancelled else { return "" }
        if document == nil, query.utf8.count <= maximumInputBytes,
           query.contains("query=") || query.contains("operationName="),
           let items = URLComponents(string: "http://x/?" + query)?.queryItems {
            declared = items.first { $0.name == "operationName" }?.value
            if let text = items.first(where: { $0.name == "query" })?.value, !text.isEmpty { document = text }
            else if path.range(of: "graphql", options: .caseInsensitive) != nil, declared?.isEmpty == false { document = "" }
        }
        guard !Task.isCancelled, let document else { return "" }
        if let declared, !declared.isEmpty { return declared }
        let withoutComments = document.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
        guard !Task.isCancelled,
              let match = operation.firstMatch(in: withoutComments, range: NSRange(withoutComments.startIndex..., in: withoutComments)),
              match.numberOfRanges > 2, let range = Range(match.range(at: 2), in: withoutComments) else { return "" }
        return String(withoutComments[range])
    }

    package static func displayName(_ value: String) -> String {
        // Avoid splitting a UTF-8 scalar while bounding retained display values.
        let bytes = value.utf8
        guard bytes.count > maximumValueBytes else { return value }
        var end = bytes.index(bytes.startIndex, offsetBy: maximumValueBytes)
        while end > bytes.startIndex, bytes[end] & 0xc0 == 0x80 { end = bytes.index(before: end) }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
}
