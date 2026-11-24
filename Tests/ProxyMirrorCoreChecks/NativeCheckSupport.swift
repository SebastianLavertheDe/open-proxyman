import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix
@testable import ProxyMirrorCore

/// Socket-backed fixtures deliberately use SelectableEventLoop. EmbeddedEventLoop
/// cannot receive completions from MapLocal's file worker on another thread.
func waitForNativeCheck<T: Sendable>(_ future: EventLoopFuture<T>, timeout: TimeInterval = 5) throws -> T {
    precondition(!future.eventLoop.inEventLoop, "A native fixture must not block its NIO event loop")
    let reply = NSBox<Result<T, Error>>()
    future.whenComplete { reply.store($0) }
    return try reply.wait(timeout: timeout).get()
}

func nativeHTTP2Listener(group: EventLoopGroup, engine: ProxyEngine, host: String, port: Int = 443,
                         rules: RulesSnapshot,
                         poolReady: @escaping (Channel, HTTP2UpstreamPool) -> Void = { _, _ in }) throws -> Channel {
    try waitForNativeCheck(ServerBootstrap(group: group).childChannelInitializer { parent in
        let pool = HTTP2UpstreamPool(downstream: parent, listenerPort: 0)
        poolReady(parent, pool)
        return parent.configureHTTP2Pipeline(mode: .server, inboundStreamInitializer: { child in
            child.eventLoop.makeCompletedFuture {
                try child.pipeline.syncOperations.addHandlers([
                    HTTP2HeaderValidation(), HTTP2FramePayloadToHTTP1ServerCodec(),
                    HTTP2ProxyStream(engine: engine, pool: pool, authorityHost: host, authorityPort: port,
                        client: nil, clientApplication: nil, requestRules: { rules }),
                ])
            }
        }).map { _ in () }
    }.bind(host: "127.0.0.1", port: 0))
}

struct NativeHTTP2Client {
    let channel: Channel
    let multiplexer: HTTP2StreamMultiplexer.SendableView

    init(group: EventLoopGroup, port: Int) throws {
        let configured = NSBox<HTTP2StreamMultiplexer.SendableView>()
        channel = try waitForNativeCheck(ClientBootstrap(group: group).channelInitializer { channel in
            channel.configureHTTP2Pipeline(mode: .client, inboundStreamInitializer: {
                $0.eventLoop.makeSucceededVoidFuture()
            }).map { configured.store($0.sendableView) }
        }.connect(host: "127.0.0.1", port: port))
        multiplexer = try configured.wait()
    }

    func open(_ collector: NativeResponseCollector) throws -> Channel {
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: promise) { child in
            child.eventLoop.makeCompletedFuture {
                try child.pipeline.syncOperations.addHandlers([HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https), collector])
            }
        }
        return try waitForNativeCheck(promise.futureResult)
    }
}

final class NativeResponseCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    let response = NSBox<Result<NIOHTTP1.HTTPResponseHead, Error>>()
    private var head: NIOHTTP1.HTTPResponseHead?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head) where head.status.code >= 200: self.head = head
        case .end:
            if let head { response.store(.success(head)) }
        default: break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        response.store(.failure(error))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if head == nil { response.store(.failure(ChannelError.eof)) }
        context.fireChannelInactive()
    }
}
