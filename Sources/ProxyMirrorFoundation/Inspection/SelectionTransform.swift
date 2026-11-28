import Foundation

package enum SelectionTransform: String, CaseIterable {
    case prettifyJSON, prettifyXML, decodeBase64, decodeJWT, convertTimestamp, keyValue

    package func apply(_ input: String, timeZone: TimeZone = .current) -> String? {
        guard input.utf8.count <= 1_048_576 else { return nil }
        switch self {
        case .prettifyJSON:
            guard let data = input.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let result = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) else { return nil }
            return String(decoding: result, as: UTF8.self)
        case .prettifyXML:
            let result = MarkupFormatter.format(input)
            return result.formatted ? result.text : nil
        case .decodeBase64:
            guard let data = Self.base64(input.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            return String(data: data, encoding: .utf8) ?? (data.prefix(65_536).map { String(format: "%02x", $0) }.joined(separator: " ") + (data.count > 65_536 ? "\n…" : ""))
        case .decodeJWT:
            let segments = input.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
            guard segments.count == 3, let header = Self.base64(String(segments[0])), let payload = Self.base64(String(segments[1])),
                  let h = Self.prettifyJSON.apply(String(decoding: header, as: UTF8.self)),
                  let p = Self.prettifyJSON.apply(String(decoding: payload, as: UTF8.self)), let signature = Self.base64(String(segments[2])) else { return nil }
            return "Header\n\(h)\n\nPayload\n\(p)\n\nSignature: \(signature.count) bytes"
        case .convertTimestamp:
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard [10, 13].contains(trimmed.count), trimmed.allSatisfy({ $0.isNumber }), let number = Double(trimmed) else { return nil }
            let date = Date(timeIntervalSince1970: number / (trimmed.count == 13 ? 1000 : 1))
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = timeZone
            let local = formatter.string(from: date)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return "Local: \(local)\nUTC: \(formatter.string(from: date))"
        case .keyValue:
            return FormBody.urlEncoded(Data(input.utf8)).map { "\($0.0)\t\($0.1)" }.joined(separator: "\n")
        }
    }

    private static func base64(_ input: String) -> Data? {
        let normalized = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard normalized.count % 4 != 1 else { return nil }
        return Data(base64Encoded: normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4))
    }
}
