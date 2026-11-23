import Foundation
@testable import ProxyMirrorCore

func checkComposeExportFeatures(_ test: CoreAssertions) throws {
    try checkMCPPrivacy(test)
    let parsed = ComposeService.parseCurl("curl -L --max-time 15 -X QUERY 'https://example.test/search' --data-raw '{}'")
    test.equal(parsed?.timeoutSeconds, 15, "cURL import retains the overall deadline")
    test.equal(parsed?.followRedirects, true, "cURL import retains redirect behavior")
    test.equal(parsed?.method, "QUERY", "Compose accepts QUERY with a request body")
    test.expect(ComposeService.parseCurl("curl --max-time -1 https://example.test/") == nil,
                "cURL import rejects negative timeout")
    let saved = try JSONEncoder().encode(parsed!)
    let reopened = try JSONDecoder().decode(ComposeService.ParsedRequest.self, from: saved)
    test.equal(reopened.timeoutSeconds, 15, "Compose history retains timeout")
    test.equal(reopened.followRedirects, true, "Compose history retains redirects")
    test.equal(reopened.body, parsed?.body, "Compose history retains original body bytes")
    let legacy = Data(#"{"method":"GET","url":"https://example.test/","headers":[]}"#.utf8)
    let old = try JSONDecoder().decode(ComposeService.ParsedRequest.self, from: legacy)
    test.equal(old.timeoutSeconds, 60, "Legacy Compose history retains a bounded default")
    test.equal(old.followRedirects, false, "Legacy Compose history does not follow redirects")

    let multipart = ComposeService.Template.multipart.request(url: "https://example.test/upload")
    let contentType = multipart.headers.first { $0.0 == "Content-Type" }?.1 ?? ""
    let boundary = String(contentType.split(separator: "=").last ?? "")
    let multipartText = String(decoding: multipart.body ?? Data(), as: UTF8.self)
    test.expect(!boundary.isEmpty && multipartText.hasSuffix("--\(boundary)--\r\n"),
                "Multipart template uses a matching closing MIME boundary")
    test.expect(multipartText.contains("Content-Disposition: form-data; name=\"file\"; filename=\"example.txt\""),
                "Multipart template includes a valid file part")
    let socket = ComposeService.Template.websocket.request(url: "https://example.test/socket")
    test.equal(socket.url, "wss://example.test/socket", "WebSocket template uses the matching secure scheme")
    test.equal(ComposeService.parse(ComposeService.rawText(from: socket))?.url, socket.url,
               "Raw Compose mode preserves the WebSocket destination")

    let domain = "pm-compose-check-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    ComposeService.saveHistory(Array(repeating: reopened, count: 25), defaults: defaults)
    test.equal(ComposeService.loadHistory(defaults: defaults).count, 20, "Compose history is bounded to twenty requests")
    test.equal(ComposeService.loadHistory(defaults: defaults).first?.timeoutSeconds, 15,
               "Persisted Compose history restores execution options")

    let tx = Transaction()
    tx.method = "POST"; tx.scheme = "https"; tx.host = "example.test"
    tx.path = "/a%2Fb"; tx.query = "tag=a&tag=b"
    tx.requestBody = Data([0, 255, 128, 39, 10, 36, 92]); tx.requestBodyComplete = true
    tx.requestHeaders = HTTPHeaders([("Authorization", "Bearer sample-secret"), ("Cookie", "sid=sample-secret"),
                                     ("X-Test", "value \\\" $value"), ("X-Test", "second")])
    tx.responseHeaders = HTTPHeaders([("Set-Cookie", "session=sample-secret")])
    tx.statusCode = 200; tx.state = .completed; tx.responseBodyComplete = true
    test.expect(RequestCode.Format.allCases.count >= 19, "Copy as Code exposes at least nineteen formats")
    for format in RequestCode.Format.allCases {
        let output = RequestCode.generate(tx, format: format)
        test.expect(!output.isEmpty, "Copy as Code produces \(format.title)")
        if ![.curl, .httpie, .har].contains(format) {
            test.expect(output.contains(tx.requestBody.base64EncodedString()),
                        "\(format.title) preserves binary bytes through Base64 or a documented local file")
        }
    }
    let nodeHTTP = RequestCode.generate(tx, format: .nodeHTTP)
    test.expect(nodeHTTP.contains("[\"Host\", new URL("), "Native Node raw headers explicitly include the required HTTP Host")
    tx.requestHeaders.append("Expect", "100-continue")
    let java = RequestCode.generate(tx, format: .java)
    test.expect(java.contains("builder.expectContinue(true);") && !java.contains("builder.header(\"Expect\""),
                "Java uses its expectContinue API for restricted Expect headers")
    let collection = try JSONSerialization.jsonObject(with: Data(RequestCode.generate(tx, format: .postman).utf8)) as? [String: Any]
    let item = (collection?["item"] as? [[String: Any]])?.first
    let request = item?["request"] as? [String: Any]
    let binary = request?["body"] as? [String: Any]
    test.equal(binary?["mode"] as? String, "file", "Postman uses a local binary file instead of sending base64 as payload")
    test.expect(RequestCode.supported(.fetch, for: tx), "Fetch supports complete POST binary payloads")
    tx.method = "GET"
    test.expect(!RequestCode.supported(.fetch, for: tx), "Fetch cannot replay GET bodies")
    tx.method = "POST"

    let preview = try GistService.preview([tx])
    test.expect(!preview.contains("sample-secret"), "Gist preview always redacts credential headers")
    test.expect(preview.contains("<redacted>"), "Gist preview marks redacted values")
    let editedHAR = ExportService.buildHAR([tx])
    let edited = String(decoding: try JSONSerialization.data(withJSONObject: editedHAR), as: UTF8.self)
    let publish = try GistService.request(preview: edited, description: "fixture", isPublic: false, token: "test-token")
    test.equal(publish.url?.absoluteString, "https://api.github.com/gists", "Gist publishing uses the fixed GitHub endpoint")
    test.equal(publish.httpMethod, "POST", "Gist publishing uses POST")
    let body = try JSONSerialization.jsonObject(with: publish.httpBody!) as? [String: Any]
    test.equal(body?["public"] as? Bool, false, "Gist request preserves secret visibility")
    let files = body?["files"] as? [String: [String: String]]
    let content = files?["proxymirror.har"]?["content"] ?? ""
    test.expect(!content.contains("sample-secret"), "Gist request re-redacts credentials after preview edits")
    test.equal(tx.requestHeaders.value(of: "Authorization"), "Bearer sample-secret",
               "Publishing preview does not mutate captured request headers")
    test.rejects(try GistService.request(preview: edited, description: "fixture", isPublic: false, token: "bad\nvalue"),
                 with: GistService.GistError.self, "Gist rejects tokens containing newlines")
}
