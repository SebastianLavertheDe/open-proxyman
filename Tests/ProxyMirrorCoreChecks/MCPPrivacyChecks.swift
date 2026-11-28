import Foundation
@testable import ProxyMirrorCore

func checkMCPPrivacy(_ test: CoreAssertions) throws {
    let json = #"{"nested":{"token":"json-token","password":"json-password","ok":"visible"}}"#
    let form = "access_token=form-secret&tag=one&tag=two"
    let data: [String: Any] = [
        "url": "https://url-user:url-password@example.test/path?api_key=url-secret&tag=one",
        "query": "token=query-secret&tag=one",
        "requestHeaders": [["name": "Authorization", "value": "Bearer header-secret"], ["name": "X-Visible", "value": "visible"]],
        "responseHeaders": [["name": "Set-Cookie", "value": "sid=cookie-secret; HttpOnly"]],
        "requestBody": Data(json.utf8).base64EncodedString(),
        "responseBody": Data(form.utf8).base64EncodedString(),
        "websocketFrames": [["payload": Data([0, 255, 1]).base64EncodedString(), "decompressedPreview": Data(json.utf8).base64EncodedString()]],
        "sse": ["events": [["data": json]]],
        "rule": ["source": "const password = 'rule-secret';\nconst token = \"rule-token\";"],
        "har": ["postData": ["params": [["name": "password", "value": "har-secret"]]]]
    ]
    let original = try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
    let result = try MCPDataRedaction.jsonData(original)
    let safe = try JSONSerialization.jsonObject(with: result) as! [String: Any]
    let output = String(decoding: result, as: UTF8.self)
    for secret in ["url-user", "url-password", "url-secret", "query-secret", "header-secret", "cookie-secret", "rule-secret", "rule-token", "har-secret"] {
        test.expect(!output.contains(secret), "MCP hides \(secret) outside payloads")
    }
    let request = String(decoding: Data(base64Encoded: safe["requestBody"] as! String)!, as: UTF8.self)
    test.expect(!request.contains("json-token") && !request.contains("json-password") && request.contains("visible"),
                "MCP redacts nested JSON credentials while retaining benign fields")
    let response = String(decoding: Data(base64Encoded: safe["responseBody"] as! String)!, as: UTF8.self)
    test.expect(!response.contains("form-secret") && response.contains("tag=one&tag=two"), "MCP redacts form credentials and preserves repeated benign fields")
    let frames = safe["websocketFrames"] as! [[String: Any]]
    test.equal(Data(base64Encoded: frames[0]["payload"] as! String), Data(MCPDataRedaction.marker.utf8), "Opaque binary WS payloads are hidden")
    let preview = String(decoding: Data(base64Encoded: frames[0]["decompressedPreview"] as! String)!, as: UTF8.self)
    test.expect(!preview.contains("json-token"), "MCP redacts decompressed WebSocket previews")
    test.expect(!MCPDataRedaction.text("data: " + json + "\n\ndata: " + json + "\n\n").contains("json-token"), "Every SSE event is redacted")
    let binary = MCPDataRedaction.sanitize(Data([0, 1, 2, 255]).base64EncodedString(), key: "responseBody") as! String
    test.equal(Data(base64Encoded: binary), Data(MCPDataRedaction.marker.utf8), "Opaque HTTP response bodies are hidden")
    let plain = MCPDataRedaction.sanitize(Data("ordinary text".utf8).base64EncodedString(), key: "requestBody") as! String
    test.equal(Data(base64Encoded: plain), Data("ordinary text".utf8), "Benign UTF-8 body text is retained")
    let multipart = "--fixture\r\nContent-Disposition: form-data; name=\"password\"\r\n\r\nmultipart-secret\r\n--fixture\r\nContent-Disposition: form-data; name=\"label\"\r\n\r\nvisible\r\n--fixture--\r\n"
    let safeMultipart = MCPDataRedaction.text(multipart)
    test.expect(!safeMultipart.contains("multipart-secret") && safeMultipart.contains("visible"), "Multipart credentials are removed without hiding benign fields")
    let headerLikeJSON = #"{"name":"token","value":"header-secret","password":"sibling-secret","nested":{"access_token":"nested-secret","ok":"visible"}}"#
    let safeHeaderLikeJSON = MCPDataRedaction.text(headerLikeJSON)
    for secret in ["header-secret", "sibling-secret", "nested-secret"] {
        test.expect(!safeHeaderLikeJSON.contains(secret), "Header-shaped JSON still recursively hides \(secret)")
    }
    test.expect(safeHeaderLikeJSON.contains("visible"), "Header-shaped JSON retains benign nested fields")
    let encodedHeaderLikeJSON = MCPDataRedaction.sanitize(Data(headerLikeJSON.utf8).base64EncodedString(), key: "responseBody") as! String
    test.expect(!String(decoding: Data(base64Encoded: encodedHeaderLikeJSON)!, as: UTF8.self).contains("sibling-secret"),
                "Base64 response-body redaction traverses header-shaped JSON")
    for disposition in ["Content-Disposition: form-data; name=password", "content-disposition: FORM-DATA; NAME = password",
                        "Content-Disposition: form-data; name=\"pass\\word\"", "Content-Disposition: form-data;\r\n name=password"] {
        let input = "--fixture\r\n\(disposition)\r\n\r\nunquoted-secret\r\n--fixture\r\nContent-Disposition: form-data; name=label\r\n\r\nvisible --fixture text\r\n--fixture--\r\n"
        let safe = MCPDataRedaction.text(input)
        test.expect(!safe.contains("unquoted-secret") && safe.contains("visible --fixture text"),
                    "Multipart accepts token/quoted names, header case and folding without splitting body substrings")
    }
    let malformedMultipart = "--fixture\r\nContent-Disposition: form-data; name=label; name=password\r\n\r\nambiguous-secret\r\n--fixture--\r\n"
    test.expect(!MCPDataRedaction.text(malformedMultipart).contains("ambiguous-secret"), "Ambiguous multipart names hide the body conservatively")
    let unfinishedMultipart = "--fixture\r\nContent-Disposition: form-data; name=label\r\n\r\nvisible\r\n--fixture\r\nContent-Disposition: form-data; name=password\r\n\r\nunfinished-secret"
    test.expect(!MCPDataRedaction.text(unfinishedMultipart).contains("unfinished-secret"), "Unclosed multipart envelopes do not expose an unparsed trailing part")
    let nestedMultipart = "--fixture\r\nContent-Disposition: form-data; name=metadata\r\n\r\n{\"password\":\"nested-form-secret\",\"ok\":\"visible\"}\r\n--fixture--\r\n"
    let safeNestedMultipart = MCPDataRedaction.text(nestedMultipart)
    test.expect(!safeNestedMultipart.contains("nested-form-secret") && safeNestedMultipart.contains("visible"), "Benign multipart fields still redact nested JSON credentials")
    let preambleMultipart = "MIME preamble\r\n--fixture\r\nContent-Disposition: form-data; name=password\r\n\r\npreamble-secret\r\n--fixture--\r\n"
    let safePreamble = MCPDataRedaction.text(preambleMultipart)
    test.expect(!safePreamble.contains("preamble-secret") && safePreamble.contains("MIME preamble"), "MIME preamble does not bypass multipart redaction")
    let sseMultipart = "--fixture\r\nContent-Disposition: form-data; name=password\r\n\r\nouter-secret\r\n--fixture\r\nContent-Disposition: form-data; name=note\r\n\r\ndata: hello\r\n--fixture--\r\n"
    let safeSSEMultipart = MCPDataRedaction.text(sseMultipart)
    test.expect(!safeSSEMultipart.contains("outer-secret") && safeSSEMultipart.contains("data:hello"), "SSE text inside a MIME part does not bypass the outer credential field")
    test.expect(!MCPDataRedaction.text("password=non-data-secret\ndata: hello\n").contains("non-data-secret"), "SSE detection does not bypass redaction of other lines")
    let multilineSSE = "id: 42\nevent: credentials\n: keep comment\ndata: {\"password\":\ndata: \"split-event-secret\",\"ok\":\"visible\"}\n\nid: 43\ndata: ordinary\ndata: multiline text\n\n"
    let safeMultilineSSE = MCPDataRedaction.text(multilineSSE)
    test.expect(!safeMultilineSSE.contains("split-event-secret") && safeMultilineSSE.contains("visible"), "SSE data fields are combined before JSON credential redaction")
    test.expect(safeMultilineSSE.contains("id: 42") && safeMultilineSSE.contains("event: credentials") && safeMultilineSSE.contains(": keep comment")
                && safeMultilineSSE.contains("id: 43") && safeMultilineSSE.contains("data: ordinary\ndata: multiline text"),
                "Multiline SSE preserves event metadata, comments, boundaries and ordinary text")
    test.expect(!MCPDataRedaction.text("data: {\"password\":\ndata: \"incomplete-event-secret\"\n\n").contains("incomplete-event-secret"),
                "Incomplete JSON SSE event data is hidden conservatively")
    let nestedQuery = "data=%7B%22password%22%3A%22nested-form-secret%22%7D&tag=one"
    test.expect(!MCPDataRedaction.text(nestedQuery).contains("nested-form-secret"), "Encoded JSON inside a form/query field is redacted")
    let graphQLCases: [(String, String)] = [
        (#"mutation Login { login(password: "graphql-inline-secret", label: "visible") { token } }"#, "graphql-inline-secret"),
        (#"{ login(password: "escaped\"graphql-escaped-secret tail") { id } }"#, "graphql-escaped-secret"),
        ("{ login(password: \"\"\"block\ngraphql-block-secret\n\"\"\") { id } }", "graphql-block-secret"),
        ("{ login(password # comment\n: \"graphql-comment-secret\") { id } }", "graphql-comment-secret"),
        (#"query Login($apiKey: String! = "graphql-default-secret") { user(key: $apiKey) { id } }"#, "graphql-default-secret"),
        (#"query Login($value: String = "graphql-alias-default-secret") { login(password: $value) { id } }"#, "graphql-alias-default-secret"),
        (#"mutation Login($value: String = "graphql-container-default-secret") { login(password: [$value]) { id } }"#, "graphql-container-default-secret"),
        (#"mutation { login(credentials: { value: "graphql-object-secret", password: "nested-secret" }) { id } }"#, "graphql-object-secret"),
        (#"{ login(token: 123456789) { id } }"#, "123456789"),
        (#"{ login(email: "graphql-email-secret") { id } }"#, "graphql-email-secret"),
        ("\u{FEFF}{ login(password: \"graphql-bom-secret\") { id } }", "graphql-bom-secret"),
        ("# leading comment\n,\u{FEFF}query# inline comment\nLogin { login(password: \"graphql-ignored-secret\") { id } }", "graphql-ignored-secret"),
    ]
    for (query, secret) in graphQLCases {
        let envelope = try JSONSerialization.data(withJSONObject: ["query": query, "operationName": "visible"])
        let safe = MCPDataRedaction.text(String(decoding: envelope, as: UTF8.self))
        test.expect(!safe.contains(secret) && safe.contains("visible"), "GraphQL JSON query hides the complete \(secret) literal")
        let native = try MCPDataRedaction.jsonData(JSONSerialization.data(withJSONObject: ["requestBody": envelope.base64EncodedString()]))
        let fields = try JSONSerialization.jsonObject(with: native) as! [String: String]
        test.expect(!String(decoding: Data(base64Encoded: fields["requestBody"]!)!, as: UTF8.self).contains(secret),
                    "Native GraphQL base64 bodies hide \(secret)")
        test.expect(!MCPDataRedaction.text("data: " + String(decoding: envelope, as: UTF8.self) + "\n\n").contains(secret),
                    "GraphQL SSE envelopes hide \(secret)")
    }
    let validGraphQL = #"query Login { login(password: "secret") { id } }"#
    let safeGraphQL = MCPDataRedaction.text(validGraphQL)
    test.expect(safeGraphQL.contains(#"password: "<redacted>""#), "GraphQL redaction retains a quoted string value")
    let benignGraphQL = #"query Visible($id: ID!) { session: viewer(id: $id) { token: publicName label } }"#
    test.equal(MCPDataRedaction.text(benignGraphQL), benignGraphQL, "Benign GraphQL selections, aliases and variables remain intact")
    let aliasEnvelope: [String: Any] = ["query": #"mutation Login($value: String!) { login(password: $value) { id } }"#,
        "variables": ["value": "graphql-indirect-secret", "label": "visible"]]
    let safeAlias = MCPDataRedaction.sanitize(aliasEnvelope) as! [String: Any]
    test.equal((safeAlias["variables"] as? [String: String])?["value"], MCPDataRedaction.marker,
               "Sensitive GraphQL argument references redact the corresponding variables")
    test.equal((safeAlias["variables"] as? [String: String])?["label"], "visible", "GraphQL keeps nonsensitive variables")
    // Valid input shapes for password: [String!] and a CredentialsInput with
    // opaque: String, tokens: [String!] and nested: CredentialsInput fields.
    let containerReferences: [(String, [String: String])] = [
        (#"mutation Login($v: String!) { login(password: [$v]) { id } }"#, ["v": "graphql-array-variable-secret"]),
        (#"mutation Login($v: String!) { login(credentials: {opaque: $v}) { id } }"#, ["v": "graphql-object-variable-secret"]),
        (#"mutation Login($left: String!, $right: String!) { login(credentials: {tokens: [$left], nested: {opaque: $right}}) { id } }"#,
         ["left": "graphql-nested-left-secret", "right": "graphql-nested-right-secret"]),
    ]
    for (query, variables) in containerReferences {
        let envelope: [String: Any] = ["query": query, "variables": variables.merging(["label": "visible"]) { old, _ in old }]
        let safe = MCPDataRedaction.sanitize(envelope) as! [String: Any]
        let safeVariables = safe["variables"] as! [String: String]
        for name in variables.keys { test.equal(safeVariables[name], MCPDataRedaction.marker, "Sensitive GraphQL value subtrees hide variable \(name)") }
        test.equal(safeVariables["label"], "visible", "GraphQL container taint leaves unrelated variables intact")
        let bytes = try JSONSerialization.data(withJSONObject: envelope)
        let safeText = MCPDataRedaction.text(String(decoding: bytes, as: UTF8.self))
        let native = MCPDataRedaction.sanitize(bytes.base64EncodedString(), key: "requestBody") as! String
        let nativeText = String(decoding: Data(base64Encoded: native)!, as: UTF8.self)
        let sse = MCPDataRedaction.text("data: " + String(decoding: bytes, as: UTF8.self) + "\n\n")
        for output in [safeText, nativeText, sse] {
            test.expect(variables.values.allSatisfy { !output.contains($0) }, "GraphQL containers hide referenced credentials in JSON, native bodies and SSE")
        }
    }
    let benignAliasVariables = MCPDataRedaction.sanitize(["query": #"query Visible($v: String!) { token: displayName user(id: $v) { email: displayName } }"#,
        "variables": ["v": "visible-identifier"]]) as! [String: Any]
    test.equal((benignAliasVariables["variables"] as? [String: String])?["v"], "visible-identifier",
               "Selection aliases do not taint unrelated argument variables")
    test.equal(MCPDataRedaction.text(#"{ login(password: "truncated-secret"#), MCPDataRedaction.marker,
               "Truncated GraphQL strings are hidden conservatively")
    let graphQLMultipart = "--fixture\r\nContent-Disposition: form-data; name=operations\r\n\r\n{\"query\":\"{login(password: \\\"multipart-graphql-secret\\\") {id}}\"}\r\n--fixture--\r\n"
    test.expect(!MCPDataRedaction.text(graphQLMultipart).contains("multipart-graphql-secret"), "GraphQL multipart operation JSON is redacted")
    let graphQLURL = #"query { lookup(url: "https://url-user:url-password@example.test/?token=graphql-url-secret") { id } }"#
    let safeGraphQLURL = MCPDataRedaction.text(graphQLURL)
    test.expect(!safeGraphQLURL.contains("url-user") && !safeGraphQLURL.contains("url-password") && !safeGraphQLURL.contains("graphql-url-secret"),
                "Benign GraphQL string arguments still redact embedded URL credentials")
    let nestedGraphQL = "mutation { login(credentials: " + String(repeating: "{credentials:", count: 1000)
        + "\"deep-graphql-secret\"" + String(repeating: "}", count: 1000) + ") { id } }"
    test.expect(!MCPDataRedaction.text(nestedGraphQL).contains("deep-graphql-secret"), "Deep GraphQL credential objects are hidden as one complete value")
    test.equal(MCPDataRedaction.text("query { " + String(repeating: "field ", count: 70_000) + "}"), MCPDataRedaction.marker,
               "GraphQL token scanning is bounded for very large documents")
    let queryJSON = #"{"password":"query-json-secret&tail","ok":"visible"}"#
    let safeQueryJSON = MCPDataRedaction.sanitize(queryJSON, key: "query") as! String
    test.expect(!safeQueryJSON.contains("query-json-secret") && !safeQueryJSON.contains("tail") && safeQueryJSON.contains("visible"),
                "JSON strings named query are sanitized before URL parameter splitting")
    let source = "const url = \"https://source-user:source-password@example.test/?token=source-token\";"
    let safeSource = MCPDataRedaction.text(source)
    test.expect(!safeSource.contains("source-user") && !safeSource.contains("source-password") && !safeSource.contains("source-token"), "Rule source URLs are redacted")
    let native = MCPDataRedaction.sanitize(["session": ["version": 1, "records": [["query": "token=native-secret"]]]]) as! [String: Any]
    test.expect(native["session"] is [String: Any] && !String(describing: native).contains("native-secret"), "Native session containers keep their schema while hiding credentials")
    let session = native["session"] as? [String: Any]
    test.equal(session?["version"] as? Int, 1, "Native session version survives redaction")
    test.equal((session?["records"] as? [[String: Any]])?.count, 1, "Native session records retain their container shape")
    let originalHeaders = [("Content-Length", "999"), ("Content-Encoding", "gzip"), ("Transfer-Encoding", "chunked"),
                           ("Trailer", "X-Footer"), ("Proxy-Authorization", "proxy-secret"), ("Host", "old.invalid"),
                           (":authority", "old.invalid"), ("Connection", "X-Only-This-Connection"), ("X-Only-This-Connection", "secret")]
    let replay = MCPDataRedaction.replayHeaders(originalHeaders, body: Data(MCPDataRedaction.marker.utf8))
    test.equal(replay.first(where: { $0.0 == "Content-Length" })?.1, String(MCPDataRedaction.marker.utf8.count), "MCP code replay length matches the sanitized byte count")
    test.expect(!replay.contains(where: { ["content-encoding", "transfer-encoding", "trailer", "proxy-authorization", "host", ":authority", "x-only-this-connection"].contains($0.0.lowercased()) }), "MCP code replay omits stale coding, proxy credentials and connection headers")
    test.equal(originalHeaders.first?.1, "999", "Replay framing normalization preserves original capture headers")
    test.equal(try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]), original, "Redaction preserves the original capture representation")
}

@MainActor
func checkMCPPreferencesRuntime(_ test: CoreAssertions) {
    let suite = "test.proxymirror.mcp.preferences.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    test.expect(settings.mcpEnabled && settings.mcpRedactSensitiveData, "MCP starts enabled with privacy enabled")
    let controller = MCPPreferencesController(settings: settings)
    var calls: [Bool] = []
    controller.register(applyEnabled: { enabled in
        calls.append(enabled)
        controller.update(isRunning: enabled, endpoint: enabled ? "http://127.0.0.1:12345/mcp" : nil)
    }, configuration: { client, transport in "\(client.rawValue):\(transport.rawValue)" })
    test.expect(controller.isRunning && calls == [true], "Registration applies the persisted state immediately")
    controller.setEnabled(false)
    test.expect(!settings.mcpEnabled && !controller.isRunning && controller.endpoint == nil, "Disabling MCP updates live state and persisted preference")
    controller.setEnabled(true)
    test.expect(settings.mcpEnabled && controller.isRunning && calls == [true, false, true], "MCP can restart without restarting the app")
    controller.update(isRunning: false, error: "fixture start failed")
    test.equal(controller.errorMessage, "fixture start failed", "Transport errors reach the settings UI")
    controller.refresh()
    test.expect(controller.isRunning && controller.errorMessage == nil, "Retry clears stale transport errors")
    test.equal(controller.configuration(client: .codex, transport: .stdio), "codex:stdio", "Configuration uses the selected client and transport")
    do { try checkMCPGraphQLAutomation(test) }
    catch { test.expect(false, "GraphQL MCP export regression: \(error)") }
}

@MainActor
private func checkMCPGraphQLAutomation(_ test: CoreAssertions) throws {
    let directory = try makeCheckDirectory()
    let previousSupport = ProcessInfo.processInfo.environment["PM_SUPPORT_DIR"]
    setenv("PM_SUPPORT_DIR", directory.path, 1)
    let suite = "ProxyMirror.MCPGraphQL.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer {
        defaults.removePersistentDomain(forName: suite)
        if let previousSupport { setenv("PM_SUPPORT_DIR", previousSupport, 1) } else { unsetenv("PM_SUPPORT_DIR") }
        try? FileManager.default.removeItem(at: directory)
    }
    let settings = AppSettings(defaults: defaults)
    settings.autoStartProxy = false
    settings.autoTakeOverSystemProxy = false
    settings.mcpEnabled = true
    settings.mcpRedactSensitiveData = true
    let app = AppState(settings: settings, launchServices: false)
    let tx = Transaction(captureBudget: CaptureBudget(limit: 1024 * 1024))
    tx.method = "POST"; tx.host = "graphql.example"; tx.path = "/graphql"
    tx.requestHeaders = HTTPHeaders([("Content-Type", "application/json")])
    tx.requestBody = try JSONSerialization.data(withJSONObject: [
        "query": #"mutation Login($v: String!, $w: String!) { login(password: [$v], credentials: {opaque: $w}, token: "automation-graphql-secret", label: "visible") { id } }"#,
        "variables": ["v": "automation-array-secret", "w": "automation-object-secret"]] as [String: Any])
    tx.requestBodyComplete = true
    app.store.add(tx)
    let original = tx.requestBody
    let secrets = ["automation-graphql-secret", "automation-array-secret", "automation-object-secret"]
    func containsSecret(_ text: String) -> Bool {
        if secrets.contains(where: text.contains) { return true }
        let pattern = try! NSRegularExpression(pattern: "[A-Za-z0-9+/]{16,}={0,2}")
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).contains { match in
            guard let range = Range(match.range, in: text), let bytes = Data(base64Encoded: String(text[range])),
                  let decoded = String(data: bytes, encoding: .utf8) else { return false }
            return secrets.contains(where: decoded.contains)
        }
    }
    for operation in ["get_flow", "export_flows", "copy_as_code"] {
        for option in operation == "export_flows" ? ["har", "json", "session"] : operation == "copy_as_code" ? ["curl", "python", "fetch"] : [""] {
            var arguments: [String: Any] = ["operation": operation, "id": tx.id.uuidString]
            if operation == "export_flows" { arguments["format"] = option }
            if operation == "copy_as_code" { arguments["language"] = option }
            let result = try AutomationControl.execute(arguments, app: app, isMCP: true)
            test.expect(!containsSecret(String(decoding: result, as: UTF8.self)), "Real MCP \(operation)/\(option) hides GraphQL literals and encoded bodies")
        }
    }
    test.equal(tx.requestBody, original, "MCP GraphQL exports preserve the original captured body")
}
