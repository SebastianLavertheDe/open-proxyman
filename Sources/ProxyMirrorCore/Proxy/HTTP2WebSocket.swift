import CryptoKit
import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2

/// RFC 8441 request metadata remains HTTP/2 in capture. Only the origin-facing
/// handshake is translated to RFC 6455; frame bytes are passed through unchanged.
struct HTTP2WebSocketRequest {
    let scheme: String
    let authority: String
    let path: String
    let headers: HTTPHeaders
    let key: String

    var expectedAccept: String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }

    static func parse(_ frame: HTTP2Frame.FramePayload.Headers, host: String, port: Int) throws -> Self {
        let headers = frame.headers
        guard headers.first(name: ":method") == "CONNECT", headers.first(name: ":protocol") == "websocket",
              let scheme = headers.first(name: ":scheme"), ["http", "https"].contains(scheme),
              let authority = headers.first(name: ":authority"),
              let path = headers.first(name: ":path"), path.hasPrefix("/"), !path.contains("#"),
              HTTP2HeaderValidation.validValue(path, pseudo: true),
              let parts = URLComponents(string: "\(scheme)://\(authority)"), let target = parts.host,
              parts.user == nil, parts.password == nil, parts.path.isEmpty, parts.query == nil, parts.fragment == nil,
              URLParser.bareHost(target).caseInsensitiveCompare(host) == .orderedSame,
              (parts.port ?? (scheme == "https" ? 443 : 80)) == port else { throw ProxyHTTP2Error.invalidAuthority }
        let forbidden = Set(["connection", "upgrade", "keep-alive", "proxy-connection", "transfer-encoding", "host"])
        guard !headers.contains(where: { forbidden.contains($0.name.lowercased()) }),
              headers.first(name: "sec-websocket-version") == "13",
              headers.first(name: "content-length") == nil else { throw ProxyHTTP2Error.invalidHeaders }
        let captured = HTTPHeaders(headers.compactMap { field in
            field.name.hasPrefix(":") || field.name == "sec-websocket-key" ? nil : (field.name, field.value)
        } + [("Host", authority)])
        let random = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        return Self(scheme: scheme, authority: authority, path: path, headers: captured, key: Data(random).base64EncodedString())
    }

    var originRequest: ByteBuffer {
        var fields = headers
        fields.set(name: "Connection", value: "Upgrade")
        fields.set(name: "Upgrade", value: "websocket")
        fields.set(name: "Sec-WebSocket-Key", value: key)
        var bytes = Data("GET \(scheme)://\(authority)\(path) HTTP/1.1\r\n".utf8)
        bytes.append(fields.rawBytes)
        bytes.append(Data("\r\n".utf8))
        return ByteBuffer(bytes: bytes)
    }

    func captureHeaders(_ headers: HTTPHeaders, response: Bool = false, webSocket: Bool = false) -> HTTPHeaders {
        let nominated = (headers.value(of: "Connection") ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let removed = Set(["connection", "upgrade", "keep-alive", "proxy-connection", "transfer-encoding",
                           "sec-websocket-key", "sec-websocket-accept"] + nominated + (webSocket ? ["content-length"] : []))
        return HTTPHeaders(headers.pairs.compactMap { field in
            let name = field.name.lowercased()
            return removed.contains(name) || (response && name == "host") ? nil : (name, field.value)
        })
    }

    func accepts(_ response: HTTPResponseHead) -> Bool {
        let connection = (response.headers.value(of: "Connection") ?? "").lowercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return response.status == 101 && response.headers.value(of: "Upgrade")?.lowercased() == "websocket"
            && connection.contains("upgrade") && response.headers.value(of: "Sec-WebSocket-Accept") == expectedAccept
    }
}

/// Select the raw extended-CONNECT path before the ordinary HTTP/2-to-HTTP/1
/// message codec discards pseudo-headers. Each stream chooses independently.
final class HTTP2ProxyStreamRouter: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias InboundOut = HTTP2Frame.FramePayload
    private let engine: ProxyEngine
    private let pool: HTTP2UpstreamPool
    private let host: String
    private let port: Int
    private let client: SocketAddress?
    private let application: ProcessAppInfo?
    private let transparent: TransparentProxyFlow?
    private var routed = false

    init(engine: ProxyEngine, pool: HTTP2UpstreamPool, host: String, port: Int, client: SocketAddress?,
         application: ProcessAppInfo?, transparent: TransparentProxyFlow?) {
        self.engine = engine; self.pool = pool; self.host = host; self.port = port
        self.client = client; self.application = application; self.transparent = transparent
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !routed, case .headers(let frame) = unwrapInboundIn(data) else {
            context.close(promise: nil); return
        }
        routed = true
        do {
            let handlers: [ChannelHandler]
            if frame.headers.first(name: ":protocol") != nil {
                let request = try HTTP2WebSocketRequest.parse(frame, host: host, port: port)
                let conn = ConnState(engine: engine)
                conn.http2WebSocket = request
                conn.clientApplication = application
                conn.transparentFlow = transparent
                let proxy = ProxyConnectionHandler(conn: conn)
                conn.proxyHandler = proxy
                handlers = [HTTP2WebSocketAdapter(request: request), proxy]
            } else {
                handlers = [HTTP2FramePayloadToHTTP1ServerCodec(),
                            HTTP2ProxyStream(engine: engine, pool: pool, authorityHost: host, authorityPort: port,
                                client: client, clientApplication: application, transparentFlow: transparent)]
            }
            try context.pipeline.syncOperations.addHandlers(handlers, position: .after(self))
            context.fireChannelActive()
            context.fireChannelRead(data)
            context.pipeline.removeHandler(self, promise: nil)
        } catch {
            let text = ByteBuffer(string: "ProxyMirror: unsupported or invalid extended CONNECT")
            let status: String
            if let failure = error as? ProxyHTTP2Error, case .invalidAuthority = failure { status = "421" }
            else { status = "400" }
            context.write(NIOAny(HTTP2Frame.FramePayload.headers(.init(headers: .init([
                (":status", status), ("content-type", "text/plain"), ("content-length", String(text.readableBytes)),
            ])))), promise: nil)
            context.writeAndFlush(NIOAny(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(text), endStream: true))), promise: nil)
            // A peer may leave its half open after a rejected handshake.
            context.eventLoop.scheduleTask(in: .seconds(5)) { context.close(promise: nil) }
        }
    }
}

/// RFC 8441 DATA is an ordered octet stream, not one-WebSocket-frame-per-DATA.
/// NIO's stream channel supplies window accounting and per-stream writability;
/// ProxyConnectionHandler supplies bounded buffering and upstream backpressure.
final class HTTP2WebSocketAdapter: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = HTTP2Frame.FramePayload

    private let request: HTTP2WebSocketRequest
    private var receivedHeaders = false
    private var inputEnded = false
    private var inputNotified = false
    private var responseStarted = false
    private var webSocketOpen = false
    private var outputEnded = false
    private var responseParser = ResponseHeadParser()
    private var headPromises: [EventLoopPromise<Void>] = []
    private var earlyFrames: [ByteBuffer] = []
    private var earlyBytes = 0
    private var chunks: ChunkedTracker?
    private var remaining: Int?
    private var closeTimer: Scheduled<Void>?
    private var lastWrite: EventLoopFuture<Void>?

    init(request: HTTP2WebSocketRequest) { self.request = request }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .headers(let frame):
            guard !receivedHeaders else { abort(context); return }
            receivedHeaders = true
            context.fireChannelRead(wrapInboundOut(request.originRequest))
            if frame.endStream { endInput(context) }
        case .data(let frame):
            guard receivedHeaders, !inputEnded, case .byteBuffer(let bytes) = frame.data else { abort(context); return }
            if webSocketOpen {
                if bytes.readableBytes > 0 { context.fireChannelRead(wrapInboundOut(bytes)) }
            } else if !responseStarted {
                guard bytes.readableBytes <= 1_048_576 - earlyBytes, earlyFrames.count < 1024 else { abort(context); return }
                earlyBytes += bytes.readableBytes
                if bytes.readableBytes > 0 { earlyFrames.append(bytes) }
            }
            if frame.endStream { endInput(context) }
        case .rstStream:
            abort(context)
        case .priority, .windowUpdate:
            break
        default:
            abort(context)
        }
    }

    private func endInput(_ context: ChannelHandlerContext) {
        inputEnded = true
        if webSocketOpen || earlyFrames.isEmpty { notifyInputClosed(context) }
    }

    private func notifyInputClosed(_ context: ChannelHandlerContext) {
        guard !inputNotified else { return }
        inputNotified = true
        context.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
    }

    private func track(_ written: EventLoopFuture<Void>, context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        if let pending = lastWrite {
            let ordered = EventLoopFuture.andAllSucceed([pending, written], on: context.eventLoop)
            lastWrite = ordered
            return ordered
        }
        lastWrite = written
        return written
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let bytes = unwrapOutboundIn(data)
        guard !outputEnded else {
            if bytes.readableBytes == 0 {
                if let pending = lastWrite, let promise { pending.cascade(to: promise) }
                else { promise?.succeed(Void()) }
            }
            else { promise?.fail(ChannelError.outputClosed) }
            return
        }
        var promiseBuffered = false
        do {
            if !responseStarted {
                if let promise { headPromises.append(promise); promiseBuffered = true }
                guard let head = try responseParser.feed(Data(bytes.readableBytesView)) else { return }
                let trailing = ByteBuffer(bytes: responseParser.trailing)
                responseParser = ResponseHeadParser()
                let informational = head.status >= 100 && head.status < 200 && head.status != 101
                if !informational {
                    responseStarted = true
                    webSocketOpen = head.status == 101
                    if !webSocketOpen {
                        if head.headers.value(of: "Transfer-Encoding")?.lowercased().contains("chunked") == true {
                            chunks = ChunkedTracker()
                        } else if let text = head.headers.value(of: "Content-Length"), let length = Int(text), length >= 0 {
                            remaining = length
                        }
                    }
                }
                let noBody = !informational && !webSocketOpen && (remaining == 0 || BreakpointMessage.noBodyStatus(head.status))
                let status = head.status == 101 ? 200 : head.status
                let fields = request.captureHeaders(head.headers, response: true, webSocket: head.status == 101)
                let written = context.write(wrapOutboundOut(.headers(.init(headers: .init(
                    [(":status", String(status))] + fields.pairs.map { ($0.name, $0.value) }), endStream: noBody))) )
                outputEnded = noBody
                var writes = [written]
                if trailing.readableBytes > 0 { writes.append(try writeBody(trailing, context: context)) }
                let waiting = headPromises
                headPromises.removeAll()
                track(EventLoopFuture.andAllSucceed(writes, on: context.eventLoop), context: context).whenComplete { result in
                    for promise in waiting { promise.completeWith(result) }
                }
                if webSocketOpen {
                    context.eventLoop.execute {
                        for frame in self.earlyFrames { context.fireChannelRead(self.wrapInboundOut(frame)) }
                        self.earlyFrames.removeAll(); self.earlyBytes = 0
                        if self.inputEnded { self.notifyInputClosed(context) }
                        context.fireChannelReadComplete()
                    }
                } else if responseStarted {
                    earlyFrames.removeAll(); earlyBytes = 0
                }
            } else {
                let written = track(try writeBody(bytes, context: context), context: context)
                if let promise { written.cascade(to: promise) }
            }
        } catch {
            if !promiseBuffered { promise?.fail(error) }
            for pending in headPromises { pending.fail(error) }
            headPromises.removeAll()
            abort(context)
        }
    }

    private func writeBody(_ bytes: ByteBuffer, context: ChannelHandlerContext) throws -> EventLoopFuture<Void> {
        guard !outputEnded else { return context.eventLoop.makeSucceededVoidFuture() }
        if webSocketOpen {
            return context.write(wrapOutboundOut(.data(.init(data: .byteBuffer(bytes)))))
        }
        if var tracker = chunks {
            let decoded = try tracker.consume(Data(bytes.readableBytesView))
            chunks = tracker
            var writes: [EventLoopFuture<Void>] = []
            if !decoded.payload.isEmpty {
                writes.append(context.write(wrapOutboundOut(.data(.init(data: .byteBuffer(ByteBuffer(bytes: decoded.payload)))))))
            }
            if tracker.finished {
                outputEnded = true
                let trailers = request.captureHeaders(tracker.trailers, response: true)
                if trailers.count > 0 {
                    writes.append(context.write(wrapOutboundOut(.headers(.init(headers: .init(
                        trailers.pairs.map { ($0.name, $0.value) }), endStream: true)))))
                } else { writes.append(writeEnd(context)) }
            }
            return .andAllSucceed(writes, on: context.eventLoop)
        }
        if let length = remaining {
            guard bytes.readableBytes <= length else { throw ProxyHTTP2Error.invalidMessage }
            remaining = length - bytes.readableBytes
            outputEnded = remaining == 0
        }
        return context.write(wrapOutboundOut(.data(.init(data: .byteBuffer(bytes), endStream: outputEnded))))
    }

    private func writeEnd(_ context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        context.write(wrapOutboundOut(.data(.init(data: .byteBuffer(ByteBuffer()), endStream: true))))
    }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        guard responseStarted else { context.close(mode: mode, promise: promise); return }
        if !webSocketOpen, (remaining ?? 0) > 0 || chunks.map({ !$0.finished }) == true {
            // Removing Transfer-Encoding on the HTTP/2 side must not turn an
            // incomplete rejected handshake into an apparently complete body.
            context.close(mode: .all, promise: promise)
            return
        }
        if !outputEnded {
            outputEnded = true
            let written = track(writeEnd(context), context: context)
            if let promise { written.cascade(to: promise) }
            context.flush()
        } else if let pending = lastWrite, let promise { pending.cascade(to: promise) }
        else { promise?.succeed(Void()) }
        // Finish the HTTP/2 output half without RST_STREAM. Continue consuming a
        // peer's remaining DATA until its END_STREAM, then NIO closes the stream.
        context.channel.setOption(ChannelOptions.autoRead, value: true).whenSuccess { context.read() }
        if !inputEnded, closeTimer == nil {
            closeTimer = context.eventLoop.scheduleTask(in: .seconds(5)) { context.close(promise: nil) }
        }
    }

    private func abort(_ context: ChannelHandlerContext) {
        closeTimer?.cancel()
        context.close(promise: nil)
    }

    func handlerRemoved(context: ChannelHandlerContext) { closeTimer?.cancel() }

    func channelInactive(context: ChannelHandlerContext) {
        closeTimer?.cancel()
        for promise in headPromises { promise.fail(ChannelError.ioOnClosedChannel) }
        headPromises.removeAll(); earlyFrames.removeAll(); earlyBytes = 0
        context.fireChannelInactive()
    }
}
