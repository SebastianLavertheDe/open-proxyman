import Foundation
import NIOEmbedded
@testable import ProxyMirrorCore

@MainActor
func checkWSCompressedInterception(_ test: CoreAssertions) {
    // Fixed RFC 7692 examples: the second payload references the first message's dictionary.
    let hello = Data([0xf2, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00])
    let repeated = Data([0xf2, 0x00, 0x11, 0x00, 0x00])
    final class Results: @unchecked Sendable {
        var wire = Data()
        var messages: [Data] = []
        var issues: [String] = []
        var closed = false
        var dataIndex = 0
    }
    let configuration = WebSocketDeflate(windowBits: 15, noContextTakeover: false)
    let loop = EmbeddedEventLoop()
    let result = Results()
    let interceptor = WSRelayInterceptor(direction: .upstream, maskOutgoing: true, loop: loop,
        emit: { data, _ in result.wire.append(data) }, close: { result.closed = true }, deflate: configuration,
        issue: { result.issues.append($0) }, script: { frame, done in
            guard frame.opcode == 1 else { done(.pass); return }
            result.messages.append(frame.payload)
            result.dataIndex += 1
            switch result.dataIndex {
            case 1: done(.modify(payload: Data("modified".utf8), note: "test"))
            case 2: done(.drop)
            default: done(.pass)
            }
        })
    // Fragmented compressed data, an interleaved control frame, then an uncompressed message.
    let first = WSFrameCodec.encode(opcode: 1, fin: false, payload: Data(hello.prefix(3)), mask: true, compressed: true)
    let ping = WSFrameCodec.encode(opcode: 9, fin: true, payload: Data("p".utf8), mask: true)
    let continuation = WSFrameCodec.encode(opcode: 0, fin: true, payload: Data(hello.suffix(4)), mask: true)
    let compressed = WSFrameCodec.encode(opcode: 1, fin: true, payload: repeated, mask: true, compressed: true)
    interceptor.feed(first + ping + continuation + compressed)
    loop.run()
    interceptor.feed(WSFrameCodec.encode(opcode: 2, fin: true, payload: Data([1, 2]), mask: true) + compressed)
    loop.run()
    test.equal(result.messages, [Data("Hello".utf8), Data("Hello".utf8), Data("Hello".utf8)],
               "Scripts see decompressed, reassembled messages even after a preceding message was dropped")
    var parser = WSFrameParser()
    let forwarded = parser.feed(result.wire, direction: .upstream)
    test.equal(forwarded.map(\.opcode), [9, 1, 2, 1], "Compressed interception retains control and uncompressed binary frames")
    test.expect(forwarded.allSatisfy(\.masked), "Re-encoded upstream WebSocket frames remain masked")
    let decoder = WebSocketDeflate.Decoder(configuration)
    let decoded = forwarded.filter { $0.rsv1 == true }.compactMap { decoder.preview($0.payload)?.data }
    test.equal(decoded, [Data("modified".utf8), Data("Hello".utf8)],
               "Independent outbound compression stays valid after modifying and dropping dictionary-bearing messages")
    test.expect(result.issues.isEmpty && !result.closed, "Supported compression runs without a fallback or protocol failure")

    for bits: Int32 in [8, 10, 15] {
        let independent = WebSocketDeflate(windowBits: bits, noContextTakeover: true)
        let encoder = WebSocketDeflate.Encoder(independent)
        let receiver = WebSocketDeflate.Decoder(independent)
        let payloads = [Data(), Data(repeating: 65, count: 2048), Data("different".utf8)]
        for payload in payloads {
            let encoded = encoder.encode(payload)
            test.equal(encoded.flatMap { receiver.preview($0)?.data }, payload,
                       "No-context compressed messages round-trip at negotiated window \(bits)")
        }
    }
    let closeResult = Results()
    let closing = WSRelayInterceptor(direction: .downstream, maskOutgoing: false, loop: loop,
        emit: { data, _ in closeResult.wire.append(data) }, close: { closeResult.closed = true }, deflate: configuration,
        script: { _, done in done(.close) })
    closing.feed(WSFrameCodec.encode(opcode: 1, fin: true, payload: hello, mask: false, compressed: true))
    loop.run()
    test.expect(closeResult.closed && closeResult.wire.isEmpty, "A close action on compressed data closes without forwarding it")

    let invalidResult = Results()
    let invalid = WSRelayInterceptor(direction: .downstream, maskOutgoing: false, loop: loop,
        emit: { data, _ in invalidResult.wire.append(data) }, close: { invalidResult.closed = true }, deflate: configuration,
        issue: { invalidResult.issues.append($0) }, script: { _, done in done(.pass) })
    invalid.feed(WSFrameCodec.encode(opcode: 1, fin: true, payload: Data([0xff]), mask: false, compressed: true))
    loop.run()
    test.expect(invalidResult.closed && invalidResult.wire.isEmpty && !invalidResult.issues.isEmpty,
                "Malformed compressed data closes with a visible explanation instead of emitting a corrupt frame")

    test.expect(WebSocketDeflate.scriptingIssue(in: HTTPHeaders()) == nil, "Unextended WebSocket scripting remains supported")
    test.expect(WebSocketDeflate.scriptingIssue(in: HTTPHeaders([("Sec-WebSocket-Extensions",
        "permessage-deflate; client_no_context_takeover; server_max_window_bits=10")])) == nil,
                "Known permessage-deflate negotiation enables scripting")
    test.expect(WebSocketDeflate.scriptingIssue(in: HTTPHeaders([("Sec-WebSocket-Extensions", "unknown-extension")])) != nil,
                "Unknown negotiated extensions produce an explicit scripting explanation")
    test.expect(WebSocketDeflate.scriptingIssue(in: HTTPHeaders([("Sec-WebSocket-Extensions",
        "permessage-deflate; client_max_window_bits=16")])) != nil, "Invalid negotiated compression parameters are reported")
}
