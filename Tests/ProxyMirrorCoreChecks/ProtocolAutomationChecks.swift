import Foundation
import NIOCore
import NIOEmbedded
@testable import ProxyMirrorCore

@MainActor
func checkProtocolAutomation(_ test: CoreAssertions) throws {
    let certificate = URL(fileURLWithPath: "/tmp/CA ' quoted/$(not-a-command).pem")
    let environment = ProxyAutomation.environment(port: 9123, certificate: certificate)
    test.equal(environment["HTTPS_PROXY"], "http://127.0.0.1:9123", "Automation configures the active proxy endpoint")
    test.equal(environment["ALL_PROXY"], "socks5h://127.0.0.1:9123", "Automation SOCKS DNS is resolved by the proxy")
    test.equal(environment["NODE_EXTRA_CA_CERTS"], certificate.path, "Automation preserves literal certificate paths")
    let plan = try ProxyAutomation.plan(.terminal, port: 9123, certificate: certificate,
        support: URL(fileURLWithPath: "/tmp/ProxyMirror automation test"))
    test.equal(plan.executable.path, "/usr/bin/osascript", "Terminal launch uses an explicit executable")
    let script = String(decoding: plan.files[0].1, as: UTF8.self)
    test.expect(script.contains(ProxyAutomation.shellQuote(certificate.path)) && script.contains("exec /bin/zsh -il"),
                "Terminal script quotes paths and starts an interactive shell")
    test.equal(plan.files[0].2, 0o700, "Generated terminal script is private and executable")

    let engine = ProxyEngine.shared
    let conn = ConnState(engine: engine)
    let channel = EmbeddedChannel(handler: SOCKS5ProxyHandshake(conn: conn))
    defer { _ = try? channel.finish() }
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 54321)).wait()
    _ = try channel.writeInbound(ByteBuffer(bytes: [5]))
    test.expect(try channel.readOutbound(as: ByteBuffer.self) == nil, "A fragmented SOCKS greeting waits for all bytes")
    _ = try channel.writeInbound(ByteBuffer(bytes: [2, 2, 0]))
    let method = try channel.readOutbound(as: ByteBuffer.self)
    test.equal(method.map { Array($0.readableBytesView) }, [5, 0], "SOCKS chooses only no-auth authentication")
    let host = Array("example.test".utf8)
    let request: [UInt8] = [5, 1, 0, 3, UInt8(host.count)] + host + [1, 187]
    _ = try channel.writeInbound(ByteBuffer(bytes: request.prefix(8)))
    test.expect(try channel.readInbound(as: ByteBuffer.self) == nil, "Fragmented SOCKS target waits for the full domain")
    _ = try channel.writeInbound(ByteBuffer(bytes: request.dropFirst(8)))
    let translated = try channel.readInbound(as: ByteBuffer.self)
    test.expect(translated.map { String(decoding: $0.readableBytesView, as: UTF8.self) }
        == "CONNECT example.test:443 HTTP/1.1\r\nHost: example.test:443\r\n\r\n",
                "SOCKS target is routed through the real CONNECT pipeline")
    test.expect(conn.isSOCKS5, "CONNECT identifies a SOCKS source for HTTP detection")
    _ = try channel.writeOutbound(ByteBuffer(string: "HTTP/1.1 200 Connection Established\r\n\r\n"))
    channel.embeddedEventLoop.run()
    let accepted = try channel.readOutbound(as: ByteBuffer.self)
    test.equal(accepted.map { Array($0.readableBytesView) }, [5, 0, 0, 1, 0, 0, 0, 0, 0, 0],
               "HTTP tunnel acceptance becomes a SOCKS5 success reply")

    let denied = EmbeddedChannel(handler: SOCKS5ProxyHandshake(conn: ConnState(engine: engine)))
    defer { _ = try? denied.finish() }
    _ = try denied.writeInbound(ByteBuffer(bytes: [5, 1, 2]))
    let rejectedMethod = try denied.readOutbound(as: ByteBuffer.self)
    test.equal(rejectedMethod.map { Array($0.readableBytesView) }, [5, 255], "Unsupported SOCKS auth is rejected")

    let http = EmbeddedChannel(handler: SOCKS5ProxyHandshake(conn: ConnState(engine: engine)))
    defer { _ = try? http.finish() }
    let large = ByteBuffer(string: "POST / HTTP/1.1\r\n\r\n" + String(repeating: "x", count: 128 * 1024))
    _ = try http.writeInbound(large)
    test.equal(try http.readInbound(as: ByteBuffer.self), large, "HTTP detection forwards large first reads without SOCKS limits")
    try checkHTTP2WebSocketAdapter(test)
}
