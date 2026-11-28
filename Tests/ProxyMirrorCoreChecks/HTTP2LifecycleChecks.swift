import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix
@testable import ProxyMirrorCore

/// Runs the production stream handler and pool over real HTTP/2 sockets. The
/// first response ends while the downstream POST request remains half-open.
@MainActor
func checkHTTP2EarlyResponseLifecycle(_ test: CoreAssertions) throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { try? group.syncShutdownGracefully() }
    let engine = ProxyEngine()
    engine.recordingEnabled = false
    defer { try? engine.group.syncShutdownGracefully() }
    let previous = InterceptionConfig.shared.h2cUpstream.value
    InterceptionConfig.shared.h2cUpstream.set(H2CUpstreamConfig(enabled: true, hosts: ["127.0.0.1"]))
    defer { InterceptionConfig.shared.h2cUpstream.set(previous) }

    let connections = LockedBox(0)
    let rejectedStreamClosed = NSBox<Void>()
    let origin = try waitForNativeCheck(ServerBootstrap(group: group).childChannelInitializer { parent in
        connections.set(connections.value + 1) // the fixture has one event loop
        return parent.configureHTTP2Pipeline(mode: .server, inboundStreamInitializer: { child in
            child.eventLoop.makeCompletedFuture {
                try child.pipeline.syncOperations.addHandlers([HTTP2FramePayloadToHTTP1ServerCodec(),
                    EarlyResponseOrigin(closed: rejectedStreamClosed)])
            }
        }).map { _ in () }
    }.bind(host: "127.0.0.1", port: 0))
    defer { try? waitForNativeCheck(origin.close()) }
    let host = "early.lifecycle.test"
    let rules = RulesSnapshot(mapRemote: [ProxyRule(pattern: "*", target: "http://127.0.0.1:\(origin.localAddress!.port!)")])
    let poolReady = NSBox<NativePoolReference>()
    let proxy = try nativeHTTP2Listener(group: group, engine: engine, host: host, rules: rules) { channel, pool in
        poolReady.store(NativePoolReference(channel: channel, pool: pool))
    }
    defer { try? waitForNativeCheck(proxy.close()) }
    let client = try NativeHTTP2Client(group: group, port: proxy.localAddress!.port!)
    defer { try? waitForNativeCheck(client.channel.close()) }
    let pool = try poolReady.wait()

    let rejected = NativeResponseCollector()
    let upload = try client.open(rejected)
    let post = NIOHTTP1.HTTPRequestHead(version: .http1_1, method: .POST, uri: "/reject",
        headers: NIOHTTP1.HTTPHeaders([("host", host)]))
    try waitForNativeCheck(upload.writeAndFlush(HTTPClientRequestPart.head(post)))
    try waitForNativeCheck(upload.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(string: "unfinished upload")))))
    test.equal(try rejected.response.wait().get().status.code, 413, "HTTP/2 early rejection reaches the client before upload end")
    try rejectedStreamClosed.wait(timeout: 5)
    test.equal(try waitForNativeCheck(pool.channel.eventLoop.submit { pool.pool.activeStreamCount }), 0,
               "HTTP/2 final response releases the upstream stream slot before downstream upload ends")

    // The request END_STREAM arrives after the final response. It must neither
    // reopen the old upstream half nor close its reusable parent connection.
    try waitForNativeCheck(upload.writeAndFlush(HTTPClientRequestPart.end(nil)))
    try waitForNativeCheck(upload.closeFuture)
    let next = NativeResponseCollector()
    let stream = try client.open(next)
    let get = NIOHTTP1.HTTPRequestHead(version: .http1_1, method: .GET, uri: "/next",
                                      headers: NIOHTTP1.HTTPHeaders([("host", host)]))
    try waitForNativeCheck(stream.writeAndFlush(HTTPClientRequestPart.head(get)))
    try waitForNativeCheck(stream.writeAndFlush(HTTPClientRequestPart.end(nil)))
    test.equal(try next.response.wait().get().status.code, 200, "HTTP/2 next stream succeeds after an early upload rejection")
    try waitForNativeCheck(stream.closeFuture)
    test.equal(connections.value, 1, "HTTP/2 early upload cancellation preserves the upstream parent for reuse")
    test.equal(try waitForNativeCheck(pool.channel.eventLoop.submit { pool.pool.activeStreamCount }), 0,
               "HTTP/2 normal completion also returns the acquired pool slot")
}

private struct NativePoolReference: @unchecked Sendable {
    let channel: Channel
    let pool: HTTP2UpstreamPool
}

private final class EarlyResponseOrigin: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let closed: NSBox<Void>

    init(closed: NSBox<Void>) { self.closed = closed }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .head(let request) = unwrapInboundIn(data) else { return }
        let reject = request.uri == "/reject"
        if reject { context.channel.closeFuture.whenComplete { _ in self.closed.store(()) } }
        let response = NIOHTTP1.HTTPResponseHead(version: .http1_1, status: reject ? .payloadTooLarge : .ok,
                                                headers: NIOHTTP1.HTTPHeaders([("content-length", "0")]))
        context.write(wrapOutboundOut(.head(response)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}
