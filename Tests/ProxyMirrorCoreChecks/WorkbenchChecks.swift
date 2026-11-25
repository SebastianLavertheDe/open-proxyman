import Foundation
@testable import ProxyMirrorCore

@MainActor
func checkWorkbench(_ test: CoreAssertions) throws {
    let request = BreakpointMessage(head: .request(HTTPRequestHead(method: "POST", target: "/example", version: "HTTP/1.1",
        headers: HTTPHeaders([("Host", "original.test"), ("Content-Length", "4"), ("Connection", "keep-alive")]))), body: Data("test".utf8))
    let saved = BreakpointMessage(head: .request(HTTPRequestHead(method: "POST", target: "/other", version: "HTTP/1.1",
        headers: HTTPHeaders([("Host", "other.test"), ("Content-Length", "2"), ("Connection", "close"), ("X-Template", "present")]))), body: Data("{}".utf8))
    let template = BreakpointTemplate.capture(name: "JSON request", phase: .request, message: saved)
    let applied = try request.applying(template.draft(for: request, phase: .request))
    test.equal(applied.head.firstLine, request.head.firstLine, "Breakpoint templates preserve the active request target")
    test.equal(applied.head.headers.value(of: "Host"), "original.test", "Breakpoint templates preserve the destination authority")
    test.equal(applied.head.headers.value(of: "Connection"), "keep-alive", "Breakpoint templates preserve connection framing")
    test.equal(applied.head.headers.value(of: "Content-Length"), "2", "Applying a body template recalculates Content-Length")
    test.equal(applied.head.headers.value(of: "X-Template"), "present", "Template headers reach the pending message")
    test.equal(applied.body, Data("{}".utf8), "Template body replaces editable request bytes")
    test.rejects(try template.draft(for: request, phase: .response), with: BreakpointMessage.InvalidEdit.self,
                 "A request template cannot apply to a response breakpoint")

    let streaming = BreakpointMessage(head: request.head, body: nil)
    let streamApplied = try streaming.applying(template.draft(for: streaming, phase: .request))
    test.expect(streamApplied.body == nil, "Templates preserve uncaptured streaming body bytes")
    test.equal(streamApplied.head.headers.value(of: "Content-Length"), "4", "Streaming templates preserve original Content-Length")
    let directory = try makeCheckDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BreakpointTemplateStore(directory: directory)
    try store.save(template)
    test.equal(BreakpointTemplateStore(directory: directory).templates, [template], "Template library survives a reload")
    try store.remove(template.id)
    test.expect(BreakpointTemplateStore(directory: directory).templates.isEmpty, "Template deletion persists")

    let tx = Transaction()
    tx.host = "session.test"
    tx.requestHeaders = HTTPHeaders([("Authorization", "private-token"), ("X-Visible", "public-value")])
    tx.responseHeaders = HTTPHeaders([("Set-Cookie", "session=private")])
    let session = SessionFile(transactions: [tx], pinnedDomains: [], selected: [tx.id])
    let redacted = try SessionFile.decode(session.exportData(redactSensitiveHeaders: true))
    test.equal(redacted.records.first?.requestHeaders.value(of: "Authorization"), "<redacted>", "Native exports honor sensitive-header redaction")
    test.equal(redacted.records.first?.responseHeaders.value(of: "Set-Cookie"), "<redacted>", "Native exports redact response cookies")
    test.equal(redacted.records.first?.requestHeaders.value(of: "X-Visible"), "public-value", "Redaction preserves unrelated headers")
    let original = try SessionFile.decode(session.exportData())
    test.equal(original.records.first?.requestHeaders.value(of: "Authorization"), "private-token", "Internal persistence retains the original captured request")
    let sessionFile = directory.appendingPathComponent("session.proxymirror")
    try session.write(to: sessionFile)
    test.equal((try FileManager.default.attributesOfItem(atPath: sessionFile.path)[.posixPermissions] as? NSNumber)?.intValue,
               0o600, "Persisted session files are private")

    var snapshot = RulesSnapshot()
    test.expect(snapshot.shouldSSLProxy(host: "example.test"), "An enabled empty SSL list retains the original default")
    snapshot.sslProxyingEnabled = false
    test.expect(!snapshot.shouldSSLProxy(host: "example.test"), "Disabling the SSL tool stops decryption even when the list is empty")

    let routing = AppState(launchServices: false)
    routing.openTool(.mapRemote, transaction: tx)
    test.expect(routing.activeTool == nil, "Opening a rule window does not block the main workspace with a sheet")
    test.equal(routing.requestedRuleWindow, "mapRemote\n" + tx.fullURL, "Rule window requests retain the selected URL")
    routing.requestedRuleWindow = nil
    routing.openTool(.sslProxyingList, transaction: tx)
    test.equal(routing.requestedRuleWindow, "sslProxyingList\nsession.test", "SSL rule windows match a host rather than an entire URL")
    routing.openTool(.customCertificates)
    test.equal(routing.requestedAuxiliaryWindow, "certificate-manager", "Certificate management uses its own window")
    routing.openTool(.compose, transaction: tx)
    test.equal(routing.activeTool, .compose, "Compose keeps its editable, cancellable sheet")
    test.expect(routing.toolTransaction === tx, "Compose receives the selected captured transaction")
    test.expect(!routing.hasResolvedEngine, "Opening tools does not start a listener or create certificate state")

}
