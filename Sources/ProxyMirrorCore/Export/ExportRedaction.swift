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

    /// Copy clients construct their own connection/framing headers. Original
    /// header preservation never forwards proxy credentials or connection fields.
    static func commandHeaders(_ headers: [(String, String)], preserveOriginal: Bool,
                               omitAcceptEncodingByDefault: Bool = false) -> [(String, String)] {
        let connectionFields = headers.filter { $0.0.caseInsensitiveCompare("Connection") == .orderedSame }
            .flatMap { $0.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } }
        var omitted: Set<String> = ["host", "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
                                    "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade"]
        omitted.formUnion(connectionFields)
        if !preserveOriginal {
            omitted.insert("content-length")
            if omitAcceptEncodingByDefault { omitted.insert("accept-encoding") }
        }
        return headers.filter { !$0.0.hasPrefix(":") && !omitted.contains($0.0.lowercased()) }
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

/// MCP has its own opt-out privacy policy. Work on serialized copies so reading
/// a flow never changes the captured bytes or the user's replayable records.
enum MCPDataRedaction {
    static let marker = "<redacted>"
    private static let binaryKeys: Set<String> = ["requestbody", "responsebody", "payload", "decompressedpreview"]
    private static let sensitiveKeys: Set<String> = [
        "authorization", "proxyauthorization", "cookie", "cookie2", "setcookie", "setcookie2",
        "token", "accesstoken", "refreshtoken", "idtoken", "authtoken", "xauthtoken", "xaccesstoken",
        "apikey", "xapikey", "password", "passwd", "pwd", "secret", "clientsecret", "credential", "credentials",
        "privatekey", "session", "sessionid", "sessiontoken", "jwt", "email", "phone", "phonenumber"
    ]

    /// Only used on the detached copy passed to request code generators. The
    /// redacted bytes are plain text/JSON, never the original compressed entity.
    static func replayHeaders(_ headers: [(String, String)], body: Data) -> [(String, String)] {
        var safe = ExportRedaction.commandHeaders(headers, preserveOriginal: true).filter {
            !["content-length", "content-encoding", "content-md5", "digest", "content-digest", "repr-digest"].contains($0.0.lowercased())
        }
        if !body.isEmpty || headers.contains(where: { $0.0.caseInsensitiveCompare("Content-Length") == .orderedSame }) {
            safe.append(("Content-Length", String(body.count)))
        }
        if body == Data(marker.utf8) {
            safe.removeAll { $0.0.caseInsensitiveCompare("Content-Type") == .orderedSame }
            safe.append(("Content-Type", "text/plain; charset=utf-8"))
        }
        return safe
    }

    private static func normalized(_ key: String) -> String {
        String(key.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    static func jsonData(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try JSONSerialization.data(withJSONObject: sanitize(object), options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
    }

    static func sanitize(_ value: Any, key: String? = nil, depth: Int = 0) -> Any {
        guard depth < 48 else { return marker }
        let name = normalized(key ?? "")
        // Native domain exports use "session" for a structured SessionFile.
        // A scalar session credential is sensitive; its container is not.
        if sensitiveKeys.contains(name), !(name == "session" && (value is [String: Any] || value is [Any])) { return marker }
        if let fields = value as? [String: Any] {
            if let header = fields["name"] as? String, sensitiveKeys.contains(normalized(header)), fields["value"] != nil {
                var safe = fields; safe["value"] = marker; return safe
            }
            var safe: [String: Any] = [:]
            for (field, nested) in fields {
                if normalized(field) == "cookies" { safe[field] = [] as [Any] }
                else if field == "text", fields["encoding"] as? String == "base64", let encoded = nested as? String {
                    safe[field] = sanitizedBase64(encoded, depth: depth + 1)
                } else { safe[field] = sanitize(nested, key: field, depth: depth + 1) }
            }
            return safe
        }
        if let values = value as? [Any] { return values.map { sanitize($0, key: key, depth: depth + 1) } }
        guard let string = value as? String else { return value }
        if binaryKeys.contains(name) { return sanitizedBase64(string, depth: depth + 1) }
        if name == "query" || name == "querystring", !string.isEmpty { return sanitizeQuery(string, depth: depth + 1) }
        return text(string, depth: depth + 1)
    }

    private static func sanitizedBase64(_ encoded: String, depth: Int) -> String {
        guard !encoded.isEmpty else { return encoded }
        guard let bytes = Data(base64Encoded: encoded), let string = String(data: bytes, encoding: .utf8),
              !string.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) }) else {
            // Opaque/compressed bodies cannot be checked for credentials safely.
            return Data(marker.utf8).base64EncodedString()
        }
        return Data(text(string, depth: depth).utf8).base64EncodedString()
    }

    static func text(_ input: String, depth: Int = 0) -> String {
        guard depth < 48 else { return marker }
        let lines = input.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.count > 1, lines.contains(where: { $0.hasPrefix("data:") }) {
            return lines.map { line in
                line.hasPrefix("data:") ? text(line, depth: depth + 1) : line
            }.joined(separator: "\n")
        }
        if input.hasPrefix("data:") {
            return "data:" + text(String(input.dropFirst(5)).trimmingCharacters(in: .whitespaces), depth: depth + 1)
        }
        if let bytes = input.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: bytes),
           let encoded = try? JSONSerialization.data(withJSONObject: sanitize(object, depth: depth + 1), options: [.sortedKeys, .withoutEscapingSlashes]) {
            return String(decoding: encoded, as: UTF8.self)
        }
        if input.hasPrefix("--"), let boundary = input.components(separatedBy: .newlines).first,
           input.contains("Content-Disposition: form-data") {
            return input.components(separatedBy: boundary).map { part in
                guard let divider = part.range(of: "\r\n\r\n") ?? part.range(of: "\n\n"),
                      let regex = try? NSRegularExpression(pattern: #"(?i)\bname="([^"]+)""#),
                      let match = regex.firstMatch(in: String(part[..<divider.lowerBound]), range: NSRange(part.startIndex..<divider.lowerBound, in: part)),
                      let range = Range(match.range(at: 1), in: part), sensitiveKeys.contains(normalized(String(part[range]))) else { return part }
                return String(part[..<divider.upperBound]) + marker + "\r\n"
            }.joined(separator: boundary)
        }
        if var url = URLComponents(string: input), url.scheme != nil, url.host != nil {
            if url.user != nil { url.user = marker }
            if url.password != nil { url.password = marker }
            if let items = url.queryItems {
                url.queryItems = items.map { URLQueryItem(name: $0.name, value: sensitiveKeys.contains(normalized($0.name)) ? marker : $0.value.map { text($0, depth: depth + 1) }) }
            }
            return url.string ?? marker
        }
        // application/x-www-form-urlencoded payloads, including repeated keys.
        if input.contains("="), !input.contains("\n"), !input.contains(" "), !input.contains("{") {
            let safe = sanitizeQuery(input, depth: depth + 1)
            if safe != input { return safe }
        }
        var result = input
        if let regex = try? NSRegularExpression(pattern: #"https?://[^\s"'<>]+"#) {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let candidate = String(result[range])
                result.replaceSubrange(range, with: text(candidate, depth: depth + 1))
            }
        }
        let patterns = [
            #"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9+/_.~=-]+"#,
            #"(?i)((?:authorization|proxy-authorization|cookie|set-cookie|x-api-key|api[-_]?key|access[-_]?token|refresh[-_]?token|id[-_]?token|token|password|passwd|client[-_]?secret|secret|session[-_]?id)[\"']?\s*[=:]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s&,;\r\n]+)"#,
            #"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----[\s\S]*?-----END (?:[A-Z ]+ )?PRIVATE KEY-----"#
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: index == 1 ? "$1" + marker : marker)
        }
        return result
    }

    private static func sanitizeQuery(_ query: String, depth: Int = 0) -> String {
        guard depth < 48 else { return marker }
        // Replace values in place rather than re-encoding benign query fields.
        return query.split(separator: "&", omittingEmptySubsequences: false).map { item -> String in
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = pair.first else { return String(item) }
            let decoded = String(key).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(key)
            if sensitiveKeys.contains(normalized(decoded)) { return String(key) + "=%3Credacted%3E" }
            if pair.count == 2 {
                let raw = String(pair[1])
                let value = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw
                let safe = text(value, depth: depth + 1)
                if safe != value {
                    var allowed = CharacterSet.urlQueryAllowed
                    allowed.remove(charactersIn: "&=+#")
                    return String(key) + "=" + (safe.addingPercentEncoding(withAllowedCharacters: allowed) ?? "redacted")
                }
            }
            return String(item)
        }.joined(separator: "&")
    }
}
