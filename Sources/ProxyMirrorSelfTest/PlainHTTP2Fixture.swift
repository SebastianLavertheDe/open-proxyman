import NIOCore
import NIOPosix
import NIOHTTP1
import NIOHTTP2

func startPlainHTTP2Fixture(group: EventLoopGroup) throws -> Channel {
    try ServerBootstrap(group: group)
        .childChannelInitializer { channel in
            let peer = channel.remoteAddress?.port.map(String.init) ?? ""
            return channel.configureHTTP2Pipeline(mode: .server, inboundStreamInitializer: { stream in
                stream.eventLoop.makeCompletedFuture {
                    try stream.pipeline.syncOperations.addHandlers([
                        HTTP2FramePayloadToHTTP1ServerCodec(), PlainHTTP2Fixture(peer: peer),
                    ])
                }
            }).map { _ in () }
        }
        .bind(host: "127.0.0.1", port: 0).wait()
}

private final class PlainHTTP2Fixture: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let peer: String
    private var path = ""

    init(peer: String) { self.peer = peer }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let request):
            path = request.uri
        case .body:
            break
        case .end:
            let body = ByteBuffer(string: path)
            let headers = HTTPHeaders([("x-fixture-protocol", "HTTP/2.0"), ("content-type", "text/plain"),
                                       ("x-fixture-connection", peer)])
            let head = HTTPResponseHead(version: .init(major: 2, minor: 0), status: .ok, headers: headers)
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(HTTPHeaders([("x-fixture-trailer", "h2c")]))), promise: nil)
        }
    }
}
