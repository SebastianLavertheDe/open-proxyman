import Foundation
import NIOCore
import NIOPosix
@testable import ProxyMirrorCore

/// Exercises the real asynchronous HTTP/1 endpoint over sockets, without DNS or system trust changes.
@MainActor
func checkCertificateDownload(_ test: CoreAssertions) throws {
    let directory = try makeCheckDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let authority = CertificateAuthority(storageDirectory: directory.appendingPathComponent("CA"))
    let expected = try authority.caDER()
    let engine = ProxyEngine(certificateAuthority: authority)
    engine.recordingEnabled = false
    defer { try? engine.group.syncShutdownGracefully() }
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { try? group.syncShutdownGracefully() }
    let deny = RulesSnapshot(blockList: [ProxyRule(pattern: "*")])
    let server = try waitForNativeCheck(ServerBootstrap(group: group).childChannelInitializer { channel in
        channel.pipeline.addHandler(ProxyConnectionHandler(conn: ConnState(engine: engine), requestRules: { deny }))
    }.bind(host: "127.0.0.1", port: 0))
    defer { try? waitForNativeCheck(server.close()) }
    let port = server.localAddress!.port!

    func request(_ text: String) throws -> Data {
        let collector = CertificateDownloadCollector()
        let client = try waitForNativeCheck(ClientBootstrap(group: group).channelInitializer { channel in
            channel.pipeline.addHandler(collector)
        }.connect(host: "127.0.0.1", port: port))
        defer { try? waitForNativeCheck(client.close()) }
        try waitForNativeCheck(client.writeAndFlush(ByteBuffer(string: text)))
        return try collector.result.wait(timeout: 5).get()
    }
    let response = try request("GET http://proxy.mirror/ssl HTTP/1.1\r\nHost: proxy.mirror\r\nConnection: close\r\n\r\n")
    guard let split = response.range(of: Data("\r\n\r\n".utf8)) else {
        test.expect(false, "CA download returns an HTTP response header")
        return
    }
    let headers = String(decoding: response[..<split.lowerBound], as: UTF8.self).lowercased()
    test.expect(headers.hasPrefix("http/1.1 200"), "The reserved CA endpoint is served before user routing rules")
    test.expect(headers.contains("content-type: application/x-x509-ca-cert"), "CA download declares the device certificate MIME type")
    test.expect(headers.contains("content-disposition: attachment; filename=\"proxymirror-ca.cer\""), "CA download uses an attachment filename")
    test.expect(headers.contains("cache-control: no-store"), "CA download cannot leave a stale certificate in a cache")
    test.equal(Data(response[split.upperBound...]), expected, "CA download contains exactly the public DER certificate")

    for target in ["http://proxy.mirror/private-key", "http://proxy.mirror/ssl?private=1", "http://proxy.mirror.evil/ssl"] {
        let other = try request("GET \(target) HTTP/1.1\r\nHost: proxy.mirror\r\nConnection: close\r\n\r\n")
        test.expect(String(decoding: other.prefix(32), as: UTF8.self).hasPrefix("HTTP/1.1 403"), "Only the exact reserved CA address bypasses routing rules")
    }
    let ambiguous = try request("GET http://proxy.mirror/ssl HTTP/1.1\r\nHost: proxy.mirror\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
    test.expect(String(decoding: ambiguous.prefix(32), as: UTF8.self).hasPrefix("HTTP/1.1 400"), "CA download still rejects ambiguous HTTP request framing")
}

private final class CertificateDownloadCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let result = NSBox<Result<Data, Error>>()
    private var bytes = Data()
    private var completed = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        bytes.append(contentsOf: unwrapInboundIn(data).readableBytesView)
    }
    func channelInactive(context: ChannelHandlerContext) {
        guard !completed else { return }
        completed = true
        result.store(.success(bytes))
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !completed else { return }
        completed = true
        result.store(.failure(error))
        context.close(promise: nil)
    }
}
