import Foundation
import NIOCore
import NIOEmbedded
@testable import ProxyMirrorCore

@MainActor
func checkHTTPMessages(_ test: CoreAssertions) throws {
    var request = RequestHeadParser()
    let firstHead = try request.feed(Data("POST /sample?q=1&q=2 HTTP/1.1\r\nHo".utf8))
    test.expect(firstHead == nil && !request.isComplete, "Partial request head waits for more bytes")
    let body = Data([0, 13, 10, 255])
    let rest = Data("st: example.test\r\nX-Sample: first\r\nx-sample: second\r\n\r\n".utf8) + body
    let head = try request.feed(rest)
    test.equal(head?.method, "POST", "Request method")
    test.equal(head?.target, "/sample?q=1&q=2", "Request query order")
    test.equal(head?.headers.value(of: "HOST"), "example.test", "Case-insensitive header")
    test.equal(head?.headers.values(of: "X-Sample"), ["first", "second"], "Repeated header order")
    test.equal(Data(request.trailing), body, "Request parser retains binary body bytes")

    var response = ResponseHeadParser()
    let firstResponse = try response.feed(Data("HTTP/1.1 404 Not Found\r\nSet-Cookie: a=1\r\n".utf8))
    test.expect(firstResponse == nil && !response.isComplete, "Partial response head waits for terminator")
    let responseHead = try response.feed(Data("set-cookie: a=2\r\n\r\nbody".utf8))
    test.equal(responseHead?.status, 404, "Response status")
    test.equal(responseHead?.reason, "Not Found", "Response reason phrase")
    test.equal(responseHead?.headers.values(of: "SET-COOKIE"), ["a=1", "a=2"], "Repeated response headers")
    test.equal(String(decoding: response.trailing, as: UTF8.self), "body", "Response parser retains trailing body")

    var oversized = RequestHeadParser()
    let overLimit = Data(repeating: 65, count: 128 * 1024 + 1)
    test.rejects(try oversized.feed(overLimit), with: HTTPParseError.self, "Request head length is bounded")
    test.rejects(try ResponseHeadParser.parse("HTTP/1.1 invalid"), with: HTTPParseError.self,
                 "Malformed response status fails")

    var chunked = ChunkedTracker()
    let first = try chunked.consume(Data("5;kind=sample\r\nhe".utf8))
    let second = try chunked.consume(Data("llo\r\n0\r\nX-End: first\r\n".utf8))
    test.expect(!chunked.finished, "Chunk parser waits for complete trailers")
    let suffix = "x-end: second\r\n\r\n"
    let last = try chunked.consume(Data((suffix + "next").utf8))
    test.equal(first.payload + second.payload + last.payload, Data("hello".utf8), "Chunked bytes across reads")
    test.equal(last.wireBytes, suffix.utf8.count, "Next message bytes remain unconsumed")
    test.equal(chunked.trailers.values(of: "X-End"), ["first", "second"], "Chunk trailer order")
    test.expect(chunked.finished, "Chunked parser reaches completion")
    var invalidChunk = ChunkedTracker()
    test.rejects(try invalidChunk.consume(Data("z\r\n".utf8)), with: HTTPParseError.self, "Invalid chunk size fails")

    let ipv6 = URLParser.parse(target: "https://[::1]:9443/a%2Fb?q=one&q=two")
    test.equal(ipv6?.host, "::1", "IPv6 host without brackets")
    test.equal(ipv6?.port, 9443, "Explicit HTTPS port")
    test.equal(ipv6?.path, "/a%2Fb?q=one&q=two", "Encoded path and repeated query parameters")
    test.equal(URLParser.authority(host: "::1", port: 9443, scheme: "https"), "[::1]:9443", "IPv6 authority")
    let requestHead = HTTPRequestHead(method: "GET", target: "https://example.test/sample", version: "HTTP/1.1",
        headers: HTTPHeaders([("Host", "example.test"), ("Proxy-Connection", "keep-alive"),
                              ("Connection", "Upgrade"), ("Upgrade", "websocket")]))
    let forwarded = String(decoding: try sanitizedRequestHead(head: requestHead, originFormTarget: "/sample", keepAlive: false),
                           as: UTF8.self)
    test.expect(forwarded.hasPrefix("GET /sample HTTP/1.1\r\n"), "Forwarded request uses origin form")
    test.expect(forwarded.contains("Connection: Upgrade\r\n"), "WebSocket upgrade connection is preserved")
    test.expect(!forwarded.contains("Proxy-Connection"), "Forwarded request drops proxy-specific header")

    try checkHTTPTransportPolicies(test)
    try checkRequestRoutePlans(test)
    try test.run("checkMetadataOwnership") { try checkMetadataOwnership(test) }
    try test.run("checkHTTP2EarlyResponseLifecycle") { try checkHTTP2EarlyResponseLifecycle(test) }
    try test.run("checkAsyncMailbox") { try checkAsyncMailbox(test) }

    checkWebSocketCapture(test)
    checkWebSocketCompression(test)
}

@MainActor
private func checkHTTPTransportPolicies(_ test: CoreAssertions) throws {
    for fields in ["Content-Length: 1\r\nContent-Length: 2", "Content-Length: 1, 2", "Content-Length: +1",
                   "Content-Length: -1", "Transfer-Encoding: chunked\r\nContent-Length: 0",
                   "Transfer-Encoding: chunked, gzip", "Transfer-Encoding: gzip", "Content-Length : 1"] {
        test.rejects(try RequestHeadParser.parse("POST / HTTP/1.1\r\nHost: fixture.test\r\n" + fields),
                     with: HTTPParseError.self, "Ingress rejects ambiguous HTTP framing: \(fields)")
        if fields != "Transfer-Encoding: gzip" {
            test.rejects(try ResponseHeadParser.parse("HTTP/1.1 200 OK\r\n" + fields),
                         with: HTTPParseError.self, "Origin response rejects ambiguous HTTP framing: \(fields)")
        }
    }
    let lengths = try RequestHeadParser.parse("POST / HTTP/1.1\r\nContent-Length: 05,5\r\nContent-Length: 5")
    test.equal(lengths.headers.values(of: "Content-Length"), ["5"], "Equal CL values have one canonical wire field")
    let absolute = try RequestHeadParser.parse("GET http://allowed.test:8080/x HTTP/1.1\r\nHost: other.test")
    test.equal(absolute.headers.value(of: "Host"), "allowed.test:8080", "Absolute target owns the routing and forwarded Host")
    let ipv6 = try RequestHeadParser.parse("GET https://[::1]:9443/x HTTP/1.1\r\nHost: other.test")
    test.equal(ipv6.headers.value(of: "Host"), "[::1]:9443", "IPv6 authority remains bracketed")
    for address in ["127.0.0.1", "::1", "::ffff:127.0.0.1", "192.0.2.7", "::ffff:192.0.2.7", "2001:db8::7"] {
        let guardHandler = ProxySelfConnectionGuard(port: 9090, addresses: ["192.0.2.7", "2001:db8:0:0::7"])
        let socket = try SocketAddress(ipAddress: address, port: 9090)
        test.expect(guardHandler.rejects(socket), "Resolved own-listener address is rejected: \(address)")
        test.expect(!guardHandler.rejects(try SocketAddress(ipAddress: address, port: 8080)), "Other local service ports remain accessible")
        let channel = EmbeddedChannel(handler: guardHandler)
        test.rejects(try channel.connect(to: socket).wait(), with: ProxySelfConnectionGuard.Rejected.self,
                     "NIO connect event enforces self-target rejection")
        _ = try? channel.finish()
    }
    var clock = HTTPTransferTimeoutPolicy(interval: 30, now: 0)
    clock.uploaded(at: 40)
    test.equal(clock.deadline(requestPending: true, responseStarted: false, eventStream: false), 70,
               "Continuous upload refreshes its timeout after thirty seconds")
    test.equal(clock.deadline(requestPending: false, responseStarted: false, eventStream: false), 70,
               "Waiting for the response starts after the final upload")
    clock.downloaded(at: 60)
    test.equal(clock.deadline(requestPending: false, responseStarted: true, eventStream: false), 90,
               "Response body timeout follows read progress")
    test.expect(clock.deadline(requestPending: false, responseStarted: true, eventStream: true) == nil,
                "Established event streams permit quiet intervals")
}

@MainActor
private func checkWebSocketCapture(_ test: CoreAssertions) {
    var parser = WSFrameParser()
    var admissions = 0
    let admit = {
        admissions += 1
        return true
    }
    let start = Data([0x01, 0x82, 1, 2, 3, 4, 0x69, 0x67])
    let end = Data([0x80, 0x83, 1, 2, 3, 4, 0x6D, 0x6E, 0x6C])
    let first = parser.feed(start, direction: .upstream, admit: admit)
    test.expect(first.isEmpty && admissions == 0, "WebSocket fragments reserve metadata only for a completed record")
    let frames = parser.feed(Data([0x89, 0x80, 1, 2, 3, 4]) + end, direction: .upstream, admit: admit)
    test.equal(frames.map(\.opcode), [0x9, 0x1], "WebSocket control frame precedes the reassembled message")
    test.equal(frames.last?.fullText, "hello", "WebSocket continuation payload is unmasked and reassembled")
    test.equal(admissions, 2, "WebSocket parser admits one slot per emitted record")

    let loop = EmbeddedEventLoop()
    let wire = Data([0x81, 0, 0x81, 0, 0x81, 0, 0x81, 0])
    let budget = CaptureBudget(limit: 3 * WSFrame.captureMetadataCost + 4 * wire.count)
    func flush(_ capture: TransactionCapture, into transaction: Transaction) {
        capture.append(wire, direction: .downstream, webSocket: true)
        capture.flush()
        let deadline = Date().addingTimeInterval(2)
        while transaction.responseBytes == 0 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }
    weak var closedFirst: Transaction?
    weak var closedSecond: Transaction?
    do {
        let first = Transaction(captureBudget: budget)
        closedFirst = first
        first.isWebSocket = true
        first.state = .completed
        let firstCapture = TransactionCapture(transaction: first, on: loop)
        flush(firstCapture, into: first)
        test.equal(first.websocketFrames.count, 3, "Empty WebSocket frames still consume metadata budget")

        let second = Transaction(captureBudget: budget)
        closedSecond = second
        second.isWebSocket = true
        second.state = .completed
        let secondCapture = TransactionCapture(transaction: second, on: loop)
        flush(secondCapture, into: second)
        withExtendedLifetime((firstCapture, secondCapture)) {
            test.equal(second.websocketFrames.count, 0, "Open WebSocket connections share the metadata budget")
            test.equal(first.websocketFrames.count, 3, "A completed handshake does not make an open WebSocket reclaimable")
            test.equal(second.responseBody, wire, "Exhausted frame slots preserve available wire body")
            test.equal(second.responseBytes, wire.count, "Exhausted frame slots preserve wire byte count")
        }
    }
    let deadline = Date().addingTimeInterval(2)
    while (closedFirst != nil || closedSecond != nil) && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
    let next = Transaction(captureBudget: budget)
    flush(TransactionCapture(transaction: next, on: loop), into: next)
    test.equal(next.websocketFrames.count, 3, "Releasing WebSocket captures returns the frame metadata budget")
}

@MainActor
private func checkWebSocketCompression(_ test: CoreAssertions) {
    let headers = HTTPHeaders([("Sec-WebSocket-Extensions",
        "permessage-deflate; client_no_context_takeover; client_max_window_bits=\"10\"")])
    // RFC 7692 §7.2.3.1 and §7.2.3.2, including the back-reference to the first message.
    let hello = Data([0xf2, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00])
    let repeated = Data([0xf2, 0x00, 0x11, 0x00, 0x00])
    let wire = Data([0x41, 3]) + hello.prefix(3) + Data([0x89, 0]) + Data([0x80, 4]) + hello.suffix(4)
        + Data([0x81, 1, 0x21]) + Data([0xc1, 5]) + repeated
    let tx = Transaction(captureBudget: CaptureBudget(limit: 4096))
    tx.isWebSocket = true
    let capture = TransactionCapture(transaction: tx, on: EmbeddedEventLoop())
    capture.upgradeToWebSocket(headers: headers)
    var masked = WSFrameCodec.encode(opcode: 1, fin: true, payload: hello, mask: true)
    masked[0] |= 0x40
    capture.append(wire.prefix(7), direction: .downstream, webSocket: true)
    capture.append(masked, direction: .upstream, webSocket: true)
    capture.flush()
    capture.append(wire.dropFirst(7), direction: .downstream, webSocket: true)
    capture.flush()
    let deadline = Date().addingTimeInterval(2)
    while tx.responseBytes < wire.count && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
    let received = tx.websocketFrames.filter { $0.direction == .downstream }
    test.equal(received.map(\.opcode), [9, 1, 1, 1], "Control frames stay separate from fragmented compressed messages")
    test.equal(received.map(\.fullText), ["", "Hello", "!", "Hello"], "Decodes fragmented messages and preserves the sliding window")
    test.equal(received.map(\.payload), [Data(), hello, Data("!".utf8), repeated], "Decoded previews retain original compressed payloads")
    test.equal(tx.websocketFrames.first?.opcodeName, "Ping", "Mixed WebSocket traffic preserves arrival order within a capture batch")
    test.equal(tx.websocketFrames.first(where: { $0.direction == .upstream })?.fullText, "Hello",
               "Masked client frames use their own decompression context")
    test.equal(tx.responseBody, wire, "Raw response keeps exact frame headers and compressed bytes")
    test.equal(tx.requestBody, masked, "Raw request keeps the mask and exact frame bytes")

    if let client = WebSocketDeflate.negotiated(in: headers, direction: .upstream) {
        let decoder = WebSocketDeflate.Decoder(client)
        let finalBlock = Data([0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, 0x00])
        test.equal(decoder.preview(finalBlock)?.data, Data("Hello".utf8), "Supports the RFC example with a final DEFLATE block")
        test.expect(decoder.preview(repeated) == nil, "No-context takeover rejects a reference to a prior message")
        test.equal(decoder.preview(hello)?.data, Data("Hello".utf8), "Independent frames can decode after a damaged message")
    } else {
        test.expect(false, "Parse per-direction WebSocket compression parameters")
    }

    if let server = WebSocketDeflate.negotiated(in: headers, direction: .downstream) {
        if let target = received.last {
            test.equal(server.fullMessage(target, in: tx.websocketFrames), Data("Hello".utf8),
                       "Copying a compressed message replays its sender's prior compression context")
        }
        let legacy = received.map { frame in
            var frame = frame
            frame.rsv1 = nil
            frame.decompressedPreview = nil
            return frame
        }
        let recovered = server.recoverPreviews(for: legacy, wire: tx.responseBody, direction: .downstream)
        test.equal(recovered.map(\.fullText), received.map(\.fullText), "Recovers old archive previews from the saved wire frames")
        test.equal(recovered.map(\.id), received.map(\.id), "Recovered previews keep saved frame identities")
    }
}
