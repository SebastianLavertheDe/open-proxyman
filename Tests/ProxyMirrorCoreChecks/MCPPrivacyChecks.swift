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
}
