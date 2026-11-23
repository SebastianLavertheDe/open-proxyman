import Foundation

/// Shared by local exports, code generators and the Gist preview.
enum ExportRedaction {
    static func jsonData(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let sanitized = har(["value": object])["value"] ?? NSNull()
        return try JSONSerialization.data(withJSONObject: sanitized, options: [.fragmentsAllowed])
    }
    static let headerNames: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "cookie2", "set-cookie", "set-cookie2",
        "x-api-key", "api-key", "x-auth-token", "x-access-token"
    ]

    static func headers(_ headers: [(String, String)], redact: Bool) -> [(String, String)] {
        guard redact else { return headers }
        return headers.map { name, value in (name, headerNames.contains(name.lowercased()) ? "<redacted>" : value) }
    }

    /// HAR stores credentials in header arrays and may also contain parsed cookies.
    static func har(_ value: [String: Any]) -> [String: Any] {
        func sanitize(_ value: Any, key: String? = nil) -> Any {
            if let object = value as? [String: Any] {
                if let name = object["name"] as? String, headerNames.contains(name.lowercased()), object["value"] != nil {
                    var output = object; output["value"] = "<redacted>"; return output
                }
                return object.mapValues { sanitize($0) }.reduce(into: [String: Any]()) { output, pair in
                    output[pair.key] = pair.key == "cookies" ? [] : pair.value
                }
            }
            if let array = value as? [Any] { return array.map { sanitize($0) } }
            return value
        }
        return sanitize(value) as? [String: Any] ?? [:]
    }
}
