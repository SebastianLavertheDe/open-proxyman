import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP2
@testable import ProxyMirrorCore

@MainActor
func checkHTTP2WebSocketAdapter(_ test: CoreAssertions) throws {
    func headers(authority: String = "example.test:443") -> HTTP2Frame.FramePayload.Headers {
        .init(headers: .init([
            (":method", "CONNECT"), (":protocol", "websocket"), (":scheme", "https"),
            (":authority", authority), (":path", "/chat?sample=1"), ("sec-websocket-version", "13"),
            ("sec-websocket-protocol", "chat"), ("cookie", "a=b"),
        ]))
    }
    let opening = headers()
    let request = try HTTP2WebSocketRequest.parse(opening, host: "example.test", port: 443)
    test.rejects(try HTTP2WebSocketRequest.parse(headers(authority: "other.test:443"), host: "example.test", port: 443),
                 with: ProxyHTTP2Error.self, "RFC8441 rejects a stream authority outside its CONNECT tunnel")
    let adapter = HTTP2WebSocketAdapter(request: request)
    let channel = EmbeddedChannel(handler: adapter)
    defer {
        _ = try? channel.pipeline.removeHandler(adapter).wait()
        _ = try? channel.finish()
    }
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 54321)).wait()
    _ = try channel.writeInbound(HTTP2Frame.FramePayload.headers(opening))
    let origin = try channel.readInbound(as: ByteBuffer.self)
    let wire = origin.map { String(decoding: $0.readableBytesView, as: UTF8.self) } ?? ""
    test.expect(wire.hasPrefix("GET https://example.test:443/chat?sample=1 HTTP/1.1\r\n") &&
                wire.contains("Sec-WebSocket-Key: \(request.key)\r\n") && wire.contains("cookie: a=b"),
                "RFC8441 creates a real RFC6455 origin handshake with independent challenge and user headers")
    let masked: [UInt8] = [0x81, 0x82, 1, 2, 3, 4, 0x69, 0x6b]
    _ = try channel.writeInbound(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(ByteBuffer(bytes: masked.prefix(3))))))
    _ = try channel.writeInbound(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(ByteBuffer(bytes: masked.dropFirst(3))))))
    test.expect(try channel.readInbound(as: ByteBuffer.self) == nil, "Early RFC8441 DATA waits for the upstream handshake")
    let response = "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nContent-Length: 0\r\nSec-WebSocket-Accept: \(request.expectedAccept)\r\nSec-WebSocket-Protocol: chat\r\n\r\n"
    _ = try channel.writeOutbound(ByteBuffer(string: String(response.prefix(18))))
    test.expect(try channel.readOutbound(as: HTTP2Frame.FramePayload.self) == nil, "Fragmented upstream handshake is not partially forwarded")
    _ = try channel.writeOutbound(ByteBuffer(string: String(response.dropFirst(18))))
    channel.embeddedEventLoop.run()
    if case .headers(let accepted)? = try channel.readOutbound(as: HTTP2Frame.FramePayload.self) {
        test.equal(accepted.headers.first(name: ":status"), "200", "RFC8441 maps origin 101 to HTTP/2 status 200")
        test.expect(!accepted.endStream && accepted.headers.first(name: "upgrade") == nil &&
                    accepted.headers.first(name: "connection") == nil && accepted.headers.first(name: "sec-websocket-accept") == nil &&
                    accepted.headers.first(name: "content-length") == nil &&
                    accepted.headers.first(name: "sec-websocket-protocol") == "chat",
                    "RFC8441 strips connection headers and keeps negotiated WebSocket subprotocol")
    } else { test.expect(false, "RFC8441 emits response HEADERS") }
    var replayed: [UInt8] = []
    while let pending = try channel.readInbound(as: ByteBuffer.self) { replayed += Array(pending.readableBytesView) }
    test.equal(replayed, masked, "DATA boundaries do not alter or unmask client WebSocket bytes")
    let reply = ByteBuffer(bytes: [0x81, 2, 104, 105])
    _ = try channel.writeOutbound(reply)
    if case .data(let frame)? = try channel.readOutbound(as: HTTP2Frame.FramePayload.self), case .byteBuffer(let body) = frame.data {
        test.equal(body, reply, "Origin WebSocket bytes become HTTP/2 DATA without framing changes")
        test.expect(!frame.endStream, "An ordinary WebSocket message leaves the HTTP/2 stream open")
    } else { test.expect(false, "RFC8441 emits response DATA") }
    try channel.close().wait()
    if case .data(let frame)? = try channel.readOutbound(as: HTTP2Frame.FramePayload.self) {
        test.expect(frame.endStream, "Orderly origin close produces END_STREAM rather than resetting sibling streams")
    } else { test.expect(false, "RFC8441 emits orderly END_STREAM") }

    let rejectedAdapter = HTTP2WebSocketAdapter(request: request)
    let rejected = EmbeddedChannel(handler: rejectedAdapter)
    defer {
        _ = try? rejected.pipeline.removeHandler(rejectedAdapter).wait()
        _ = try? rejected.finish()
    }
    _ = try rejected.writeInbound(HTTP2Frame.FramePayload.headers(opening))
    _ = try rejected.readInbound(as: ByteBuffer.self)
    _ = try rejected.writeOutbound(ByteBuffer(string:
        "HTTP/1.1 403 Forbidden\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n3\r\nno!\r\n0\r\nx-result: denied\r\n\r\n"))
    if case .headers(let response)? = try rejected.readOutbound(as: HTTP2Frame.FramePayload.self) {
        test.equal(response.headers.first(name: ":status"), "403", "Rejected WS handshakes keep their real HTTP status")
        test.expect(response.headers.first(name: "transfer-encoding") == nil, "Chunking is not advertised on HTTP/2")
    } else { test.expect(false, "Rejected WS handshake emits HEADERS") }
    if case .data(let response)? = try rejected.readOutbound(as: HTTP2Frame.FramePayload.self), case .byteBuffer(let body) = response.data {
        test.equal(String(decoding: body.readableBytesView, as: UTF8.self), "no!", "Rejected handshake body is dechunked")
    } else { test.expect(false, "Rejected WS handshake emits body") }
    if case .headers(let trailers)? = try rejected.readOutbound(as: HTTP2Frame.FramePayload.self) {
        test.expect(trailers.endStream && trailers.headers.first(name: "x-result") == "denied",
                    "Rejected handshake trailers end only their own HTTP/2 stream")
    } else { test.expect(false, "Rejected handshake preserves trailers") }
    for framing in ["Content-Length: 10", "Transfer-Encoding: chunked"] {
        let truncatedAdapter = HTTP2WebSocketAdapter(request: request)
        let truncated = EmbeddedChannel(handler: truncatedAdapter)
        defer {
            _ = try? truncated.pipeline.removeHandler(truncatedAdapter).wait()
            _ = try? truncated.finish()
        }
        try truncated.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 54322)).wait()
        _ = try truncated.writeInbound(HTTP2Frame.FramePayload.headers(opening))
        _ = try truncated.readInbound(as: ByteBuffer.self)
        let body = framing.hasPrefix("Content-Length") ? "cut" : "3\r\ncut\r\n"
        _ = try truncated.writeOutbound(ByteBuffer(string: "HTTP/1.1 403 Forbidden\r\n\(framing)\r\n\r\n\(body)"))
        while let _ = try truncated.readOutbound(as: HTTP2Frame.FramePayload.self) {}
        try truncated.close().wait()
        test.expect(!truncated.isActive, "A truncated rejected WS handshake resets its stream for \(framing)")
        test.expect(try truncated.readOutbound(as: HTTP2Frame.FramePayload.self) == nil,
                    "A truncated rejected handshake must not manufacture a normal END_STREAM")
    }

    final class DrainState: @unchecked Sendable {
        var decision: (@Sendable (WSFrameAction) -> Void)?
        var output: [Data] = []
        var drained = false
    }
    let loop = EmbeddedEventLoop()
    let state = DrainState()
    let interceptor = WSRelayInterceptor(direction: .upstream, maskOutgoing: true, loop: loop,
        emit: { data, _ in state.output.append(data) },
        script: { _, completion in state.decision = completion })
    interceptor.feed(WSFrameCodec.encode(opcode: 1, fin: true, payload: Data("before".utf8), mask: true))
    interceptor.finish { state.drained = true }
    test.expect(!state.drained && state.output.isEmpty, "END_STREAM waits for the outstanding frame script")
    state.decision?(.modify(payload: Data("after".utf8), note: "fixture"))
    loop.run()
    var frames = WSFrameParser()
    let changedFrame = state.output.first.flatMap { frames.feed($0, direction: .upstream).first }
    test.expect(state.drained && changedFrame?.fullText == "after",
                "The final scripted frame is emitted before the transport half-close")
    let cancelled = DrainState()
    let cancelledInterceptor = WSRelayInterceptor(direction: .upstream, maskOutgoing: true, loop: loop,
        emit: { data, _ in cancelled.output.append(data) },
        script: { _, completion in cancelled.decision = completion })
    cancelledInterceptor.feed(WSFrameCodec.encode(opcode: 1, fin: true, payload: Data("before".utf8), mask: true))
    cancelledInterceptor.finish { cancelled.drained = true }
    cancelledInterceptor.cancel()
    cancelled.decision?(.pass)
    loop.run()
    test.expect(cancelled.output.isEmpty && !cancelled.drained, "RST_STREAM cancels queued scripts and ignores late worker replies")

    // Script completion and transport completion are separate barriers: 1 kbps
    // takes over eight seconds for this frame, exceeding the script's 5s guard.
    final class SlowState: @unchecked Sendable {
        var chunks: [Data] = []
        var scriptDrained = false
        var halfClosed = false
        var failed = false
    }
    for direction in [WSFrame.Direction.upstream, .downstream] {
        let clock = EmbeddedEventLoop()
        let slow = SlowState()
        let pacer = BytePacingQueue(loop: clock, onFailure: { _ in slow.failed = true })
        let slowInterceptor = WSRelayInterceptor(direction: direction, maskOutgoing: direction == .upstream, loop: clock,
            emit: { data, _ in
                pacer.write(ByteBuffer(bytes: data), kilobitsPerSecond: 1) { bytes in
                    slow.chunks.append(Data(bytes.readableBytesView))
                    return clock.makeSucceededVoidFuture()
                }
            }, close: { slow.failed = true }, script: { _, completion in completion(.pass) })
        let payload = Data(repeating: 0x78, count: 1024)
        slowInterceptor.feed(WSFrameCodec.encode(opcode: 2, fin: true, payload: payload, mask: direction == .upstream))
        slowInterceptor.finish {
            slow.scriptDrained = true
            pacer.afterWrites { slow.halfClosed = true }
        }
        clock.run()
        test.expect(slow.scriptDrained && !slow.halfClosed, "WS scripts drain before the low-bandwidth queue for \(direction)")
        clock.advanceTime(by: .seconds(6))
        test.expect(!slow.halfClosed && !slow.failed, "Pacing beyond 5s does not trigger the completed script's timeout")
        clock.advanceTime(by: .seconds(6))
        var parser = WSFrameParser()
        let emitted = slow.chunks.reduce(into: Data()) { $0.append($1) }
        test.expect(slow.halfClosed && !pacer.hasPendingWrites && !slow.failed &&
                    parser.feed(emitted, direction: direction).first?.payload == payload,
                    "Half-close follows every paced byte in \(direction) direction")
        pacer.cancel()
    }

}
