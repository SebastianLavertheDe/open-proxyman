import Foundation
import NIOCore
import NIOPosix
@testable import ProxyMirrorCore

/// A separate suite because its real monotonic-clock regressions take 42 seconds.
func runHTTPTransportSafetyChecks() {
    guard let support = ProcessInfo.processInfo.environment["PM_SUPPORT_DIR"], support.hasPrefix("/"),
          !FileManager.default.fileExists(atPath: RulesStore.rulesPath.path) else {
        check(false, "transport: use an empty isolated PM_SUPPORT_DIR")
        return
    }
    let engine = ProxyEngine.shared
    engine.recordingEnabled = false
    let received = LockedBox(0)
    do {
        try engine.start(port: 0)
        defer { engine.stop() }
        let origin = try ServerBootstrap(group: engine.group).childChannelInitializer { channel in
            channel.pipeline.addHandler(HTTPTransportSafetyOrigin(received: received))
        }.bind(host: "127.0.0.1", port: 0).wait()
        defer { try? origin.close().wait() }
        let port = origin.localAddress!.port!
        func client(_ request: String) throws -> (Channel, LockedBox<Data?>) {
            let result = LockedBox<Data?>(nil)
            let channel = try ClientBootstrap(group: engine.group).channelInitializer { channel in
                channel.pipeline.addHandler(HTTPTransportSafetyReceiver(result: result))
            }.connect(host: "127.0.0.1", port: Int(engine.port)).wait()
            try channel.writeAndFlush(ByteBuffer(string: request)).wait()
            return (channel, result)
        }
        func wait(_ result: LockedBox<Data?>, seconds: TimeInterval = 5) -> String {
            let deadline = Date().addingTimeInterval(seconds)
            while result.value == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            return String(decoding: result.value ?? Data(), as: UTF8.self)
        }
        for host in ["127.0.0.1", "localhost", "[::ffff:127.0.0.1]"] {
            let (channel, result) = try client("GET http://\(host):\(engine.port)/self HTTP/1.1\r\nHost: \(host):\(engine.port)\r\nConnection: close\r\n\r\n")
            defer { try? channel.close().wait() }
            check(wait(result).hasPrefix("HTTP/1.1 502"), "transport: resolved self target \(host) is rejected promptly")
        }
        let originalDNS = InterceptionConfig.shared.dnsSpoof.value
        defer { InterceptionConfig.shared.dnsSpoof.set(originalDNS) }
        InterceptionConfig.shared.dnsSpoof.set(originalDNS + [DNSSpoofRule(hostPattern: "self.pm.test", ip: "127.0.0.1")])
        let (mappedClient, mappedResult) = try client("GET http://self.pm.test:\(engine.port)/self HTTP/1.1\r\nHost: self.pm.test\r\nConnection: close\r\n\r\n")
        check(wait(mappedResult).hasPrefix("HTTP/1.1 502"), "transport: DNS mapping cannot redirect into the proxy listener")
        try? mappedClient.close().wait()
        InterceptionConfig.shared.dnsSpoof.set(originalDNS)
        let (authorityClient, authorityResult) = try client("GET http://127.0.0.1:\(port)/echo HTTP/1.1\r\nHost: other.test\r\nConnection: close\r\n\r\n")
        defer { try? authorityClient.close().wait() }
        check(wait(authorityResult).contains("host=127.0.0.1:\(port)"), "transport: absolute authority is the origin's actual Host")
        let beforeInvalid = received.value
        for fields in ["Content-Length: 1\r\nContent-Length: 2", "Transfer-Encoding: chunked\r\nContent-Length: 0",
                       "Transfer-Encoding: gzip", "Transfer-Encoding: chunked, gzip"] {
            let (channel, result) = try client("POST http://127.0.0.1:\(port)/echo HTTP/1.1\r\nHost: fixture.test\r\n\(fields)\r\n\r\n")
            defer { try? channel.close().wait() }
            check(wait(result).hasPrefix("HTTP/1.1 400"), "transport: ambiguous request framing fails at ingress")
        }
        eq(received.value, beforeInvalid, "transport: rejected request heads never reach the origin")
        let (badClient, badResult) = try client("GET http://127.0.0.1:\(port)/bad-response HTTP/1.1\r\nHost: fixture.test\r\nConnection: close\r\n\r\n")
        defer { try? badClient.close().wait() }
        check(wait(badResult).hasPrefix("HTTP/1.1 502"), "transport: ambiguous origin framing becomes a clean 502")

        // Run both uploads and the quiet SSE simultaneously. A client sends one
        // byte every five seconds, while each origin waits for its whole body.
        var streams: [(Channel, LockedBox<Data?>, Bool)] = []
        for chunked in [false, true] {
            let framing = chunked ? "Transfer-Encoding: chunked" : "Content-Length: 8"
            let (channel, result) = try client("POST http://127.0.0.1:\(port)/slow-upload HTTP/1.1\r\nHost: fixture.test\r\nConnection: close\r\n\(framing)\r\n\r\n")
            streams.append((channel, result, chunked))
            for index in 1...8 {
                channel.eventLoop.scheduleTask(in: .seconds(Int64(index * 5))) {
                    channel.writeAndFlush(ByteBuffer(string: chunked ? "1\r\na\r\n" : "a"), promise: nil)
                    if chunked && index == 8 { channel.writeAndFlush(ByteBuffer(string: "0\r\n\r\n"), promise: nil) }
                }
            }
        }
        let (eventsClient, eventsResult) = try client("GET http://127.0.0.1:\(port)/quiet-events HTTP/1.1\r\nHost: fixture.test\r\nConnection: close\r\n\r\n")
        defer { try? eventsClient.close().wait() }
        for (channel, result, chunked) in streams {
            let response = wait(result, seconds: 46)
            check(response.hasPrefix("HTTP/1.1 200") && response.contains("bytes=8"), "transport: 40 second \(chunked ? "chunked" : "fixed") upload completes")
            try? channel.close().wait()
        }
        let events = wait(eventsResult)
        check(events.hasPrefix("HTTP/1.1 200") && events.contains("data: final"), "transport: an SSE response survives a 35 second quiet interval")
    } catch {
        check(false, "transport fixture: \(error)")
    }
}

private final class HTTPTransportSafetyReceiver: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let result: LockedBox<Data?>
    private var data = Data()
    init(result: LockedBox<Data?>) { self.result = result }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { self.data.append(contentsOf: unwrapInboundIn(data).readableBytesView) }
    func channelInactive(context: ChannelHandlerContext) { result.set(data); context.fireChannelInactive() }
}

private final class HTTPTransportSafetyOrigin: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let received: LockedBox<Int>
    private var parser = RequestHeadParser()
    private var head: HTTPRequestHead?
    private var chunks: ChunkedTracker?
    private var remaining = 0
    private var bytes = 0
    private var replied = false
    init(received: LockedBox<Int>) { self.received = received }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !replied else { return }
        var payload = Data(unwrapInboundIn(data).readableBytesView)
        do {
            if head == nil {
                guard let parsed = try parser.feed(payload) else { return }
                head = parsed
                received.set(received.value + 1)
                payload = Data(parser.trailing)
                if parsed.target == "/bad-response" {
                    replied = true
                    context.writeAndFlush(NIOAny(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"))).whenComplete { _ in context.close(promise: nil) }
                    return
                }
                if parsed.target == "/quiet-events" {
                    replied = true
                    context.writeAndFlush(NIOAny(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")), promise: nil)
                    let channel = context.channel
                    channel.eventLoop.scheduleTask(in: .seconds(35)) {
                        let event = "data: final\n\n"
                        channel.writeAndFlush(ByteBuffer(string: "\(String(event.utf8.count, radix: 16))\r\n\(event)\r\n0\r\n\r\n")).whenComplete { _ in channel.close(promise: nil) }
                    }
                    return
                }
                if parsed.headers.contains("Transfer-Encoding") { chunks = ChunkedTracker() }
                else { remaining = Int(parsed.headers.value(of: "Content-Length") ?? "0") ?? 0 }
            }
            if var tracker = chunks {
                let part = try tracker.consume(payload)
                bytes += part.payload.count
                chunks = tracker
                guard tracker.finished else { return }
            } else {
                bytes += payload.count
                remaining -= payload.count
                guard remaining == 0 else { return }
            }
            replied = true
            let text = "host=\(head!.headers.value(of: "Host") ?? "");bytes=\(bytes)"
            context.writeAndFlush(NIOAny(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: \(text.utf8.count)\r\nConnection: close\r\n\r\n\(text)"))).whenComplete { _ in context.close(promise: nil) }
        } catch { context.close(promise: nil) }
    }
}
