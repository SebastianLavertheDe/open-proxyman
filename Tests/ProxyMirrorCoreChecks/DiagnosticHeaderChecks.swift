import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
@testable import ProxyMirrorCore

@MainActor
func checkDiagnosticHeaders(_ test: CoreAssertions) throws {
    let id = UUID()
    let original = ProxyMirrorCore.HTTPHeaders([("Content-Type", "application/json"), ("X-Custom", "one"), ("X-Custom", "two")])
    var disabled = DiagnosticHeaders(requestID: id, enabled: false, version: "test")
    disabled.record(.mapLocal)
    test.equal(disabled.appending(to: original).rawBytes, original.rawBytes,
               "Disabling diagnostics preserves the complete original header sequence")
    var diagnostics = DiagnosticHeaders(requestID: id, enabled: true, version: "test")
    test.equal(diagnostics.appending(to: original).rawBytes, original.rawBytes,
               "Unmodified traffic does not advertise a rule that never ran")
    diagnostics.record(.scripting)
    diagnostics.record(.mapRemote)
    diagnostics.record(.scripting)
    let request = diagnostics.appending(to: original)
    test.equal(request.value(of: "X-ProxyMirror-Rule"), "Scripting, Map Remote",
               "Diagnostics report actual processing order without duplicate script entries")
    test.equal(request.value(of: "X-ProxyMirror-Request-ID"), id.uuidString,
               "Processed requests carry their existing traffic identity")
    let response = diagnostics.appending(to: ProxyMirrorCore.HTTPHeaders([("Content-Length", "2")]))
    test.equal(response.value(of: "X-ProxyMirror-Request-ID"), request.value(of: "X-ProxyMirror-Request-ID"),
               "Both halves of a processed exchange use the same diagnostic identity")
    test.equal(response.value(of: "X-ProxyMirror-Rule"), request.value(of: "X-ProxyMirror-Rule"),
               "Map Remote and scripts label the response as well as the request")
    let userFields = ProxyMirrorCore.HTTPHeaders([("x-proxymirror", "user"), ("x-proxymirror-rule", "origin-rule"),
        ("x-proxymirror-request-id", "origin-id"), ("x-proxymirror-version", "origin-version"),
        ("X-Custom", "one"), ("X-Custom", "two")])
    test.equal(diagnostics.appending(to: userFields).rawBytes, userFields.rawBytes,
               "Diagnostics never overwrite or duplicate application-provided fields, regardless of casing")
    let replayed = diagnostics.appending(to: request)
    test.equal(replayed.rawBytes, request.rawBytes, "Applying diagnostics twice preserves the wire headers")
    var invalidVersion = DiagnosticHeaders(requestID: id, enabled: true, version: "test\r\nInjected: value")
    invalidVersion.record(.mapLocal)
    test.equal(invalidVersion.appending(to: ProxyMirrorCore.HTTPHeaders()).value(of: "X-ProxyMirror-Version"), "development",
               "Diagnostic version metadata cannot introduce a second wire header")

    // Exercise the production adapters with isolated snapshots; these cases must
    // not alter the user's rules or dial a remote origin.
    let key = "proxy.appendDiagnosticHeaders"
    let defaults = UserDefaults.standard
    let previousPreference = defaults.object(forKey: key)
    let engine = ProxyEngine.shared
    let previousRecording = engine.recordingEnabled
    engine.recordingEnabled = false
    defer {
        engine.recordingEnabled = previousRecording
        if let previousPreference { defaults.set(previousPreference, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
    let directory = try makeCheckDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let localFile = directory.appendingPathComponent("response.json")
    try Data("{\"local\":true}".utf8).write(to: localFile)
    let host = "diagnostic-\(UUID().uuidString.lowercased()).example.test"
    let local = RulesSnapshot(mapLocal: [ProxyRule(pattern: "*", target: localFile.path)])
    let block = RulesSnapshot(blockList: [ProxyRule(pattern: "*")])
    for enabled in [false, true] {
        defaults.set(enabled, forKey: key)
        for (rules, expectedSource, expectedStatus) in [(local, "Map Local", 200), (block, "Block / Allow", 403)] {
            let http1 = try diagnosticHTTP1Response(engine: engine, host: host, rules: rules)
            let http2 = try diagnosticHTTP2Response(engine: engine, host: host, rules: rules)
            test.equal(http1.status, expectedStatus, "HTTP/1 diagnostic fixture keeps the rule's real status")
            test.equal(Int(http2.status.code), expectedStatus, "HTTP/2 diagnostic fixture keeps the rule's real status")
            test.equal(http1.headers.value(of: "X-ProxyMirror-Rule"), enabled ? expectedSource : nil,
                       "HTTP/1 local \(expectedSource) honors the diagnostics preference")
            test.equal(http2.headers.first(name: "x-proxymirror-rule"), enabled ? expectedSource : nil,
                       "HTTP/2 local \(expectedSource) honors the same diagnostics preference")
            test.equal(http1.headers.contains("X-ProxyMirror"), enabled,
                       "HTTP/1 no longer injects an unconditional local Rule header")
            test.equal(http2.headers.contains(name: "x-proxymirror"), enabled,
                       "HTTP/2 local responses follow the same rule-marking policy")
            test.expect(!enabled || http2.headers.allSatisfy { $0.name == $0.name.lowercased() },
                        "HTTP/2 diagnostics retain valid lowercase wire field names")
        }
    }
    defaults.set(true, forKey: key)
    let customLocal = RulesSnapshot(mapLocal: [ProxyRule(pattern: "*", target: localFile.path,
        responseHeaders: ProxyMirrorCore.HTTPHeaders([("X-ProxyMirror-Rule", "application-rule"),
            ("X-ProxyMirror-Request-ID", "application-id")]))])
    let customHTTP1 = try diagnosticHTTP1Response(engine: engine, host: host, rules: customLocal)
    let customHTTP2 = try diagnosticHTTP2Response(engine: engine, host: host, rules: customLocal)
    test.equal(customHTTP1.headers.value(of: "X-ProxyMirror-Rule"), "application-rule",
               "HTTP/1 preserves the Map Local rule's own diagnostic fields")
    test.equal(customHTTP2.headers.first(name: "x-proxymirror-request-id"), "application-id",
               "HTTP/2 preserves the Map Local rule's own correlation identity")
}

private func diagnosticHTTP1Response(engine: ProxyEngine, host: String, rules: RulesSnapshot) throws -> ProxyMirrorCore.HTTPResponseHead {
    let channel = EmbeddedChannel(handler: ProxyConnectionHandler(conn: ConnState(engine: engine), requestRules: { rules }))
    defer { _ = try? channel.finish() }
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 54323)).wait()
    _ = try channel.writeInbound(ByteBuffer(string:
        "GET http://\(host)/fixture HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"))
    let deadline = Date().addingTimeInterval(3)
    var parser = ResponseHeadParser()
    while Date() < deadline {
        channel.embeddedEventLoop.run()
        while let bytes = try channel.readOutbound(as: ByteBuffer.self) {
            if let response = try parser.feed(Data(bytes.readableBytesView)) { return response }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.002))
    }
    throw NSError(domain: "DiagnosticHeaderChecks", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "HTTP/1 local diagnostic fixture did not produce a response"])
}

private func diagnosticHTTP2Response(engine: ProxyEngine, host: String, rules: RulesSnapshot) throws -> NIOHTTP1.HTTPResponseHead {
    let channel = EmbeddedChannel()
    let pool = HTTP2UpstreamPool(downstream: channel, listenerPort: 0)
    let handler = HTTP2ProxyStream(engine: engine, pool: pool, authorityHost: host, authorityPort: 443,
        client: nil, clientApplication: nil, requestRules: { rules })
    try channel.pipeline.addHandler(handler).wait()
    defer { _ = try? channel.finish() }
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 54324)).wait()
    let request = NIOHTTP1.HTTPRequestHead(version: .init(major: 2, minor: 0), method: .GET,
        uri: "/fixture", headers: NIOHTTP1.HTTPHeaders([("host", host)]))
    _ = try channel.writeInbound(HTTPServerRequestPart.head(request))
    _ = try channel.writeInbound(HTTPServerRequestPart.end(nil))
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        channel.embeddedEventLoop.run()
        while let part = try channel.readOutbound(as: HTTPServerResponsePart.self) {
            if case .head(let response) = part { return response }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.002))
    }
    throw NSError(domain: "DiagnosticHeaderChecks", code: 2,
                  userInfo: [NSLocalizedDescriptionKey: "HTTP/2 local diagnostic fixture did not produce a response"])
}
