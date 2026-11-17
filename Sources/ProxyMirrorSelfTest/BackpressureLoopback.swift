import Foundation
import NIOCore
import NIOPosix
@testable import ProxyMirrorCore

func runBackpressureLoopbackTests(engine: ProxyEngine) throws {
    let wasRecording = engine.recordingEnabled
    engine.recordingEnabled = false
    defer { engine.recordingEnabled = wasRecording }

    let body = Data(repeating: 0x5A, count: 8 * 1024 * 1024)
    let source = try ServerBootstrap(group: engine.group).childChannelInitializer { channel in
        channel.pipeline.addHandler(BackpressureOrigin(body: body))
    }.bind(host: "127.0.0.1", port: 0).wait()
    defer { try? source.close().wait() }
    guard let port = source.localAddress?.port else { return }

    let rules = RulesStore.shared
    let originalMaps = rules.mapLocal
    let file = CertificateAuthority.applicationSupport.appendingPathComponent("slow-local.bin")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try body.write(to: file)
    rules.mapLocal.append(ProxyRule(pattern: "http://127.0.0.1:\(port)/map-local", target: file.path,
                                    responseHeaders: HTTPHeaders([("X-Fixture", "map-local")])))
    defer {
        rules.mapLocal = originalMaps
        try? FileManager.default.removeItem(at: file)
    }

    for framing in ["fixed", "chunked", "eof", "map-local", "map-local-pipeline"] {
        let received = LockedBox<Result<Data, Error>?>(nil)
        let client = try ClientBootstrap(group: engine.group)
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelOption(ChannelOptions.socketOption(.so_rcvbuf), value: 32 * 1024)
            .channelInitializer { channel in channel.pipeline.addHandler(BackpressureReceiver(received: received)) }
            .connect(host: "127.0.0.1", port: Int(engine.port)).wait()
        defer { try? client.close().wait() }

        let origin = "http://127.0.0.1:\(port)"
        let host = "Host: 127.0.0.1:\(port)\r\n"
        let pipelined = framing == "map-local-pipeline"
        let request = pipelined
            ? "GET \(origin)/map-local HTTP/1.1\r\n\(host)\r\n"
                + "GET \(origin)/fixed HTTP/1.1\r\n\(host)Connection: close\r\n\r\n"
            : "GET \(origin)/\(framing) HTTP/1.1\r\n\(host)Connection: close\r\n\r\n"
        try client.writeAndFlush(ByteBuffer(string: request)).wait()
        let resume = client.eventLoop.scheduleTask(in: .milliseconds(600)) {
            try client.syncOptions?.setOption(ChannelOptions.autoRead, value: true)
        }
        defer { resume.cancel() }
        let deadline = Date().addingTimeInterval(6)
        while received.value == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard let result = received.value, let raw = try? result.get(),
              let separator = raw.range(of: Data("\r\n\r\n".utf8)) else {
            check(false, "loopback: 慢读 \(framing) 大响应结束")
            continue
        }
        let payload = raw[separator.upperBound...]
        let expected = framing == "chunked" ? BackpressureOrigin.chunked(body) : body
        if pipelined {
            let remaining = payload.dropFirst(body.count)
            let secondSeparator = remaining.range(of: Data("\r\n\r\n".utf8))
            check(payload.prefix(body.count) == body && secondSeparator.map { remaining[$0.upperBound...] == body } == true,
                  "loopback: Map Local 流式响应后按顺序发送下一条流水线响应")
        } else {
            check(payload == expected, "loopback: 慢读 \(framing) 大响应完整")
        }
        if framing.hasPrefix("map-local") {
            let head = String(decoding: raw[..<separator.lowerBound], as: UTF8.self)
            check(head.contains("X-Fixture: map-local"), "loopback: 慢读命中 Map Local")
        }
    }
}

private final class BackpressureOrigin: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let body: Data
    private var request = Data()

    init(body: Data) { self.body = body }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        request.append(contentsOf: unwrapInboundIn(data).readableBytesView)
        guard request.range(of: Data("\r\n\r\n".utf8)) != nil else { return }
        let line = String(decoding: request.prefix(256), as: UTF8.self)
        let fields: String
        let payload: Data
        if line.hasPrefix("GET /chunked ") {
            fields = "Transfer-Encoding: chunked\r\nTrailer: X-End\r\n"
            payload = Self.chunked(body)
        } else if line.hasPrefix("GET /eof ") {
            fields = ""
            payload = body
        } else {
            fields = "Content-Length: \(body.count)\r\n"
            payload = body
        }
        let channel = context.channel
        channel.write(ByteBuffer(string: "HTTP/1.1 200 OK\r\nConnection: close\r\n\(fields)\r\n"), promise: nil)
        channel.writeAndFlush(ByteBuffer(bytes: payload)).whenComplete { _ in channel.close(promise: nil) }
    }

    static func chunked(_ body: Data) -> Data {
        var payload = Data("\(String(body.count, radix: 16))\r\n".utf8)
        payload.append(body)
        payload.append(contentsOf: "\r\n0\r\nX-End: fixture\r\n\r\n".utf8)
        return payload
    }
}

private final class BackpressureReceiver: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let received: LockedBox<Result<Data, Error>?>
    private var response = Data()

    init(received: LockedBox<Result<Data, Error>?>) { self.received = received }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        response.append(contentsOf: unwrapInboundIn(data).readableBytesView)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if received.value == nil { received.set(.success(response)) }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        received.set(.failure(error))
        context.close(promise: nil)
    }
}
