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
            let graphQLDocument = (fields["query"] as? String).flatMap { graphQL($0, depth: depth + 1) }
            let graphQLVariables = graphQLDocument?.variables ?? []
            var safe: [String: Any] = [:]
            for (field, nested) in fields {
                if normalized(field) == "cookies" { safe[field] = [] as [Any] }
                else if field == "variables", graphQLDocument?.text == marker { safe[field] = marker }
                else if field == "variables", let variables = nested as? [String: Any], !graphQLVariables.isEmpty {
                    safe[field] = variables.reduce(into: [String: Any]()) { output, pair in
                        output[pair.key] = graphQLVariables.contains(pair.key) ? marker
                            : sanitize(pair.value, key: pair.key, depth: depth + 1)
                    }
                }
                else if field == "text", fields["encoding"] as? String == "base64", let encoded = nested as? String {
                    safe[field] = sanitizedBase64(encoded, depth: depth + 1)
                } else { safe[field] = sanitize(nested, key: field, depth: depth + 1) }
            }
            if let header = fields["name"] as? String, sensitiveKeys.contains(normalized(header)), fields["value"] != nil {
                safe["value"] = marker
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
        // A MIME part can itself contain SSE text. Parse the outer container
        // before looking for data: lines, including when MIME has a preamble.
        if let multipart = multipart(input, depth: depth) { return multipart }
        let lines = input.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.count > 1, lines.contains(where: { $0.hasPrefix("data:") }) {
            var output: [String] = [], event: [String] = []
            func appendEvent() {
                let fields = event.indices.filter { event[$0].hasPrefix("data:") }
                guard let first = fields.first else {
                    output += event.map { text($0, depth: depth + 1) }; return
                }
                // SSE joins every data field in the same event with LF. A JSON
                // key and its credential may be on different physical lines.
                let payload = fields.map { index -> String in
                    let value = event[index].dropFirst(5)
                    return String(value.hasPrefix(" ") ? value.dropFirst() : value)
                }.joined(separator: "\n")
                let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                let incompleteJSON = (trimmed.hasPrefix("{") || trimmed.hasPrefix("["))
                    && (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) == nil
                let safe = incompleteJSON ? marker : text(payload, depth: depth + 1)
                let prefix = event[first].hasPrefix("data: ") ? "data: " : "data:"
                let fieldIndices = Set(fields)
                for index in event.indices {
                    if index == first { output += safe.components(separatedBy: "\n").map { prefix + $0 } }
                    else if !fieldIndices.contains(index) { output.append(text(event[index], depth: depth + 1)) }
                }
            }
            for line in lines {
                if line.isEmpty { appendEvent(); event.removeAll(); output.append("") }
                else { event.append(line) }
            }
            if !event.isEmpty { appendEvent() }
            return output.joined(separator: "\n")
        }
        if input.hasPrefix("data:") {
            return "data:" + text(String(input.dropFirst(5)).trimmingCharacters(in: .whitespaces), depth: depth + 1)
        }
        if let bytes = input.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: bytes),
           let encoded = try? JSONSerialization.data(withJSONObject: sanitize(object, depth: depth + 1), options: [.sortedKeys, .withoutEscapingSlashes]) {
            return String(decoding: encoded, as: UTF8.self)
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
        if let document = graphQL(input, depth: depth + 1) { return document.text }
        return credentialText(input, depth: depth)
    }

    private static func credentialText(_ input: String, depth: Int) -> String {
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

    /// MIME parameter names and disposition types are case-insensitive. Values
    /// can be tokens or quoted strings with quoted-pair escaping (RFC 2183).
    private static func dispositionName(_ input: String) -> String? {
        var segments: [String] = [], segment = "", quoted = false, escaped = false
        for character in input {
            if escaped { segment.append(character); escaped = false }
            else if quoted && character == "\\" { segment.append(character); escaped = true }
            else if character == "\"" { segment.append(character); quoted.toggle() }
            else if character == ";" && !quoted { segments.append(segment); segment = "" }
            else { segment.append(character) }
        }
        guard !quoted, !escaped else { return nil }
        segments.append(segment)
        guard segments.removeFirst().trimmingCharacters(in: .whitespaces).lowercased() == "form-data" else { return nil }
        func token(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.allSatisfy { $0 > 32 && $0 < 127 && !Array("()<>@,;:\\\"/[]?=".utf8).contains($0) }
        }
        var parameters: [String: String] = [:]
        for segment in segments {
            guard let equals = segment.firstIndex(of: "=") else { return nil }
            let key = segment[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let raw = segment[segment.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard token(key), parameters[key] == nil else { return nil }
            let value: String
            if raw.hasPrefix("\"") {
                var decoded = "", escaped = false, closed = false
                for character in raw.dropFirst() {
                    guard !closed else { return nil }
                    if escaped { decoded.append(character); escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { closed = true }
                    else { decoded.append(character) }
                }
                guard closed, !escaped else { return nil }
                value = decoded
            } else {
                guard token(raw) else { return nil }
                value = raw
            }
            parameters[key] = value
        }
        // Extended/ambiguous names cannot safely select a credential field.
        guard parameters["name*"] == nil else { return nil }
        return parameters["name"]
    }

    private static func multipart(_ input: String, depth: Int) -> String? {
        let lines = input.components(separatedBy: .newlines)
        guard let boundary = lines.first(where: { $0.hasPrefix("--") }),
              input.range(of: "content-disposition", options: .caseInsensitive) != nil
                || lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == boundary + "--" }) else { return nil }
        guard boundary.utf8.count <= 202,
              let pattern = try? NSRegularExpression(pattern: "(?m)^" + NSRegularExpression.escapedPattern(for: boundary) + "(?:--)?[ \\t]*(?:\\r?\\n|$)") else { return marker }
        let delimiters = pattern.matches(in: input, range: NSRange(input.startIndex..., in: input))
        guard delimiters.count >= 2, let last = delimiters.last.flatMap({ Range($0.range, in: input) }),
              input[last].trimmingCharacters(in: .whitespacesAndNewlines) == boundary + "--" else { return marker }
        guard let first = Range(delimiters[0].range, in: input) else { return marker }
        var output = text(String(input[..<first.lowerBound]), depth: depth + 1)
        for (index, delimiter) in delimiters.enumerated() {
            guard let range = Range(delimiter.range, in: input) else { return marker }
            output += input[range]
            let end = index + 1 < delimiters.count ? Range(delimiters[index + 1].range, in: input)!.lowerBound : input.endIndex
            let part = String(input[range.upperBound..<end])
            if index + 1 == delimiters.count {
                output += text(part, depth: depth + 1)
                continue
            }
            guard let divider = part.range(of: "\r\n\r\n") ?? part.range(of: "\n\n") else {
                output += marker + "\r\n"; continue
            }
            let head = String(part[..<divider.lowerBound])
            var fields: [String: String] = [:], last: String?, malformed = false
            for line in head.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
                if line.hasPrefix(" ") || line.hasPrefix("\t"), let last {
                    fields[last, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
                } else if let colon = line.firstIndex(of: ":") {
                    let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    if fields[key] != nil { malformed = true }
                    fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    last = key
                } else { malformed = true }
            }
            let body = String(part[divider.upperBound...])
            let ending = body.hasSuffix("\r\n") ? "\r\n" : body.hasSuffix("\n") ? "\n" : ""
            let content = String(body.dropLast(ending.count))
            let name = fields["content-disposition"].flatMap(dispositionName)
            let safe = !malformed && name.map({ !sensitiveKeys.contains(normalized($0)) }) == true
                ? text(content, depth: depth + 1) : marker
            output += String(part[..<divider.upperBound]) + safe + ending
        }
        return output
    }

    private static func sanitizeQuery(_ query: String, depth: Int = 0) -> String {
        guard depth < 48 else { return marker }
        // A JSON field called "query" can contain a GraphQL document rather
        // than URL parameters. Never split a document's strings on '&' or '='.
        if graphQL(query, depth: depth + 1) != nil
            || (try? JSONSerialization.jsonObject(with: Data(query.utf8))) != nil { return text(query, depth: depth + 1) }
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
            return pair.count == 1 ? text(String(item), depth: depth + 1) : String(item)
        }.joined(separator: "&")
    }

    private struct GraphQLRedaction {
        let text: String
        let variables: Set<String>
    }

    private struct GraphQLToken {
        let span: Range<Int>
        var name: String? = nil
        var symbol: UInt8? = nil
    }

    /// Lex values instead of matching a quoted substring: GraphQL supports
    /// escaped quotes, block strings, input objects and variable defaults.
    /// Malformed/truncated documents are hidden rather than partly exposed.
    private static func graphQL(_ input: String, depth: Int) -> GraphQLRedaction? {
        let bytes = Array(input.utf8)
        var tokens: [GraphQLToken] = [], index = 0
        var replacements: [(span: Range<Int>, text: String)] = []
        func isName(_ byte: UInt8) -> Bool { byte == 95 || (65...90).contains(byte) || (97...122).contains(byte) }
        func result(_ text: String = marker, variables: Set<String> = []) -> GraphQLRedaction {
            GraphQLRedaction(text: text, variables: variables)
        }
        // Avoid treating URL query parameters such as query=... as a document.
        var leading = 0
        while leading < bytes.count {
            if [9, 10, 13, 32, 44].contains(bytes[leading]) { leading += 1 }
            else if leading + 2 < bytes.count, bytes[leading...leading + 2].elementsEqual([239, 187, 191]) { leading += 3 }
            else if bytes[leading] == 35 { while leading < bytes.count, bytes[leading] != 10, bytes[leading] != 13 { leading += 1 } }
            else { break }
        }
        let prefix = String(decoding: bytes[leading...], as: UTF8.self)
        guard prefix.hasPrefix("{") || ["query", "mutation", "subscription", "fragment"].contains(where: {
            prefix.hasPrefix($0) && prefix.dropFirst($0.count).first.map { $0.isWhitespace || ["{", "(", ",", "#", "\u{FEFF}"].contains($0) } == true
        }), input.contains("{") else { return nil }
        guard depth < 48 else { return result() }
        while index < bytes.count {
            let start = index, byte = bytes[index]
            if index + 2 < bytes.count, bytes[index...index + 2].elementsEqual([239, 187, 191]) { index += 3; continue }
            if [9, 10, 13, 32, 44].contains(byte) { index += 1; continue }
            if byte == 35 {
                while index < bytes.count, bytes[index] != 10, bytes[index] != 13 { index += 1 }
                let comment = String(decoding: bytes[start..<index], as: UTF8.self)
                let safe = credentialText(comment, depth: depth + 1)
                if safe != comment { replacements.append((start..<index, safe)) }
                continue
            }
            if byte == 34 {
                let block = index + 2 < bytes.count && bytes[index + 1] == 34 && bytes[index + 2] == 34
                index += block ? 3 : 1
                var closed = false
                while index < bytes.count {
                    if bytes[index] == 92 {
                        if block, index + 3 < bytes.count, bytes[index + 1...index + 3].allSatisfy({ $0 == 34 }) { index += 4 }
                        else { index += 2 }
                    } else if bytes[index] == 34, !block || (index + 2 < bytes.count && bytes[index + 1] == 34 && bytes[index + 2] == 34) {
                        index += block ? 3 : 1; closed = true; break
                    } else { index += 1 }
                }
                guard closed else { return result() }
                tokens.append(GraphQLToken(span: start..<index))
                let value: String?
                if block {
                    value = String(decoding: bytes[start + 3..<index - 3], as: UTF8.self)
                        .replacingOccurrences(of: "\\\"\"\"", with: "\"\"\"")
                } else {
                    value = (try? JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed])) as? String
                }
                guard let value else { return result() }
                let safe = text(value, depth: depth + 1)
                if safe != value, let encoded = try? JSONSerialization.data(withJSONObject: safe, options: [.fragmentsAllowed, .withoutEscapingSlashes]) {
                    replacements.append((start..<index, String(decoding: encoded, as: UTF8.self)))
                }
            } else if isName(byte) {
                index += 1
                while index < bytes.count, isName(bytes[index]) || (48...57).contains(bytes[index]) { index += 1 }
                tokens.append(GraphQLToken(span: start..<index, name: String(decoding: bytes[start..<index], as: UTF8.self)))
            } else if byte == 45 || (48...57).contains(byte) {
                index += 1
                while index < bytes.count, (48...57).contains(bytes[index]) || [43, 45, 46, 69, 101].contains(bytes[index]) { index += 1 }
                tokens.append(GraphQLToken(span: start..<index))
            } else {
                guard Array("!$():=@[]{|}.".utf8).contains(byte) else { return result() }
                index += 1; tokens.append(GraphQLToken(span: start..<index, symbol: byte))
            }
            guard tokens.count <= 65_536 else { return result() }
        }
        // A JSON object inside a query field still belongs to the JSON redactor.
        if tokens.first?.symbol == 123, tokens.count > 1, tokens[1].name == nil, tokens[1].symbol != 125 { return nil }
        var scopes: [(opening: Int, closing: UInt8, input: Bool)] = [], argumentPositions: Set<Int> = []
        var matchingEnds: [Int: Int] = [:]
        for position in tokens.indices {
            if scopes.last?.input == true { argumentPositions.insert(position) }
            guard let symbol = tokens[position].symbol else { continue }
            if symbol == 40 || symbol == 91 || symbol == 123 {
                let previous = position > 0 ? tokens[position - 1].symbol : nil
                let isInput = symbol != 123 || previous == 58 || previous == 61 || scopes.last?.closing == 93
                scopes.append((position, symbol == 40 ? 41 : symbol == 91 ? 93 : 125, isInput))
            } else if symbol == 41 || symbol == 93 || symbol == 125 {
                guard let scope = scopes.popLast(), scope.closing == symbol else { return result() }
                matchingEnds[scope.opening] = position
            }
        }
        guard scopes.isEmpty else { return result() }
        func valueTokens(at position: Int) -> Range<Int>? {
            guard position + 2 < tokens.count, tokens[position + 1].symbol == 58 else { return nil }
            var value = position + 2
            if position > 0, tokens[position - 1].symbol == 36 {
                // Variable declarations put a type before their optional default.
                while value < tokens.count, tokens[value].name != nil || [91, 93, 33].contains(tokens[value].symbol ?? 0) { value += 1 }
                guard value < tokens.count, tokens[value].symbol == 61 else { return nil }
                value += 1
            }
            guard value < tokens.count else { return nil }
            if tokens[value].symbol == 36 {
                guard value + 1 < tokens.count, tokens[value + 1].name != nil else { return nil }
                return value..<value + 2
            }
            if let opening = tokens[value].symbol, opening == 123 || opening == 91 {
                guard let end = matchingEnds[value] else { return nil }
                return value..<end + 1
            }
            guard tokens[value].symbol == nil else { return nil }
            return value..<value + 1
        }
        var variables: Set<String> = []
        // References can follow the variable declaration. Resolve their privacy
        // context over each complete sensitive value subtree, including arrays
        // and input objects, before redacting declarations and envelope variables.
        var sensitiveValues: [Range<Int>] = []
        for position in tokens.indices {
            guard argumentPositions.contains(position), let name = tokens[position].name, sensitiveKeys.contains(normalized(name)),
                  let value = valueTokens(at: position) else { continue }
            sensitiveValues.append(value)
        }
        var scannedUntil = 0
        for range in sensitiveValues.sorted(by: { $0.lowerBound < $1.lowerBound || ($0.lowerBound == $1.lowerBound && $0.upperBound > $1.upperBound) }) {
            guard range.lowerBound >= scannedUntil else { continue }
            for position in range where tokens[position].symbol == 36 && position + 1 < range.upperBound {
                if let variable = tokens[position + 1].name { variables.insert(variable) }
            }
            scannedUntil = range.upperBound
        }
        var hiddenUntil = 0
        for position in tokens.indices {
            guard position >= hiddenUntil else { continue }
            guard argumentPositions.contains(position), let name = tokens[position].name,
                  sensitiveKeys.contains(normalized(name)) || (position > 0 && tokens[position - 1].symbol == 36 && variables.contains(name)),
                  position + 2 < tokens.count, tokens[position + 1].symbol == 58 else { continue }
            guard let range = valueTokens(at: position) else {
                if position > 0, tokens[position - 1].symbol == 36 { continue }
                return result()
            }
            let value = range.lowerBound, end = range.upperBound
            if tokens[value].symbol == 36, value + 1 < tokens.count, let variable = tokens[value + 1].name {
                variables.insert(variable); continue
            }
            replacements.append((tokens[value].span.lowerBound..<tokens[end - 1].span.upperBound, "\"\(marker)\""))
            hiddenUntil = end
        }
        // Outer credential objects subsume any nested credential replacements.
        let ordered = replacements.sorted { $0.span.lowerBound < $1.span.lowerBound || ($0.span.lowerBound == $1.span.lowerBound && $0.span.upperBound > $1.span.upperBound) }
        var disjoint: [(span: Range<Int>, text: String)] = []
        for replacement in ordered where disjoint.last.map({ $0.span.upperBound <= replacement.span.lowerBound }) ?? true { disjoint.append(replacement) }
        var safe = bytes
        for replacement in disjoint.reversed() { safe.replaceSubrange(replacement.span, with: Array(replacement.text.utf8)) }
        return result(String(decoding: safe, as: UTF8.self), variables: variables)
    }
}
