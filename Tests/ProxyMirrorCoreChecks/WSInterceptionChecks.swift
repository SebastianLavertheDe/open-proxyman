import Foundation
import NIOEmbedded
@testable import ProxyMirrorCore

/// G6：WS 帧编解码 + 拦截管道 + 帧脚本（真实 ScriptWorker）
@MainActor
func checkWSInterception(_ test: CoreAssertions) {
    // 编解码回环（无掩码 / 掩码）
    let payload = Data("汉化 payload".utf8)
    let unmasked = WSFrameCodec.encode(opcode: 0x1, fin: true, payload: payload, mask: false)
    var parserA = WSFrameParser()
    test.equal(parserA.feed(unmasked, direction: .downstream).first?.payload, payload, "WS 编码→解析回环")
    let masked = WSFrameCodec.encode(opcode: 0x2, fin: true, payload: payload, mask: true)
    var parserB = WSFrameParser()
    test.equal(parserB.feed(masked, direction: .upstream).first?.payload, payload, "WS 掩码帧解析还原")
    // 长负载长度字段
    let big = WSFrameCodec.encode(opcode: 0x2, fin: true, payload: Data(repeating: 7, count: 70_000), mask: true)
    var parserC = WSFrameParser()
    test.equal(parserC.feed(big, direction: .upstream).first?.payload.count, 70_000, "WS 16 位长度字段")

    // 拦截器：无脚本保序直通
    final class DataSink: @unchecked Sendable {
        var items: [Data] = []
        func append(_ data: Data) { items.append(data) }
        func sink(_ data: Data, direction: WSFrame.Direction) { items.append(data) }
    }
    let loop = EmbeddedEventLoop()
    let emitted = DataSink()
    let passthrough = WSRelayInterceptor(direction: .downstream, maskOutgoing: false, loop: loop,
                                         emit: { emitted.sink($0, direction: $1) }, script: nil)
    let frameA = WSFrameCodec.encode(opcode: 0x1, fin: true, payload: Data("a".utf8), mask: false)
    let frameB = WSFrameCodec.encode(opcode: 0x1, fin: true, payload: Data("b".utf8), mask: false)
    passthrough.feed(frameA)
    passthrough.feed(frameB)
    test.equal(emitted.items, [frameA, frameB], "WS 拦截器无脚本保序直通")

    // 拦截器：改写 → 丢帧 → 放行，后续帧排队等待决策
    let decisions: [WSFrameAction] = [.modify(payload: Data("A-pm".utf8), note: "文本"), .drop, .pass]
    final class DecisionQueue: @unchecked Sendable {
        var pending: [WSFrameAction]
        init(_ actions: [WSFrameAction]) { pending = actions }
        func take() -> WSFrameAction { pending.removeFirst() }
    }
    let queue = DecisionQueue(decisions)
    let scriptedOut = DataSink()
    let scripted = WSRelayInterceptor(direction: .upstream, maskOutgoing: true, loop: loop,
                                      emit: { scriptedOut.sink($0, direction: $1) },
                                      script: { _, done in done(queue.take()) })
    let upA = WSFrameCodec.encode(opcode: 0x1, fin: true, payload: Data("a".utf8), mask: true)
    let upB = WSFrameCodec.encode(opcode: 0x1, fin: true, payload: Data("b".utf8), mask: true)
    let upC = WSFrameCodec.encode(opcode: 0x1, fin: true, payload: Data("c".utf8), mask: true)
    scripted.feed(upA)
    scripted.feed(upB + upC)
    loop.run()
    test.equal(scriptedOut.items.count, 2, "WS 拦截器：改写一帧 + 丢弃一帧")
    var parserD = WSFrameParser()
    test.equal(parserD.feed(scriptedOut.items[0], direction: .upstream).first?.payload, Data("A-pm".utf8),
               "WS 拦截器改写负载")
    var parserE = WSFrameParser()
    test.equal(parserE.feed(scriptedOut.items[1], direction: .upstream).first?.payload, Data("c".utf8),
               "WS 拦截器：丢弃帧后后续帧保序到达")

    // 控制帧可以丢弃，禁止修改负载或触发脚本关闭。
    let controlOut = DataSink()
    let control = WSRelayInterceptor(direction: .downstream, maskOutgoing: false, loop: loop,
                                     emit: { controlOut.sink($0, direction: $1) },
                                     script: { _, done in done(.modify(payload: Data([0]), note: "")) })
    let ping = WSFrameCodec.encode(opcode: 0x9, fin: true, payload: Data("p".utf8), mask: false)
    control.feed(ping)
    loop.run()
    test.equal(controlOut.items, [ping], "WS 控制帧拒绝改写")

    final class DelayedDecisions: @unchecked Sendable {
        var callbacks: [@Sendable (WSFrameAction) -> Void] = []
    }
    let deferred = DelayedDecisions()
    let lateOutput = DataSink()
    let delayed = WSRelayInterceptor(direction: .downstream, maskOutgoing: false, loop: loop,
                                     emit: { lateOutput.sink($0, direction: $1) },
                                     script: { _, done in deferred.callbacks.append(done) })
    delayed.feed(frameA)
    delayed.feed(frameB)
    test.equal(deferred.callbacks.count, 1, "WS 同时只等待一个帧决策")
    loop.advanceTime(by: .milliseconds(400))
    test.equal(lateOutput.items, [frameA], "WS 脚本超时放行原始帧")
    deferred.callbacks.first?(.drop)
    deferred.callbacks.last?(.pass)
    loop.run()
    test.equal(lateOutput.items, [frameA, frameB], "WS 忽略迟到结果并保持帧顺序")

    // 帧脚本（真实 ScriptWorker）：文本改写 / false 丢帧 / base64 二进制改写
    let previous = InterceptionConfig.shared.rewrite.value
    func runRule(_ source: String, frame: WSFrame) -> WSFrameAction {
        InterceptionConfig.shared.rewrite.set([RewriteRuleSet(rules: [
            RewriteRule(rule: URLRule(), actions: [.script(phase: .webSocket, source: source)]),
        ])])
        let target = ScriptingTarget(method: "GET", scheme: "ws", host: "fixture.test", path: "/ws", query: "",
                                     url: "ws://fixture.test/ws")
        let box = NSBox<WSFrameAction>()
        ScriptingService.rewriteFrame(target: target, graphqlName: nil, frame: frame) { box.store($0) }
        return box.wait()
    }
    defer { InterceptionConfig.shared.rewrite.set(previous) }

    let textFrame = WSFrame(direction: .downstream, opcode: 0x1, fin: true, masked: false, payload: Data("hi".utf8))
    let textScript = #"return message.body + "-pm";"#
    let firstAction = runRule(textScript, frame: textFrame)
    // Cold JavaScriptCore startup can use the production decision budget.
    let textAction = firstAction == .pass ? runRule(textScript, frame: textFrame) : firstAction
    let activityLog = ScriptingActivity.shared.entries.suffix(3).map(\.text).joined(separator: " | ")
    test.equal(textAction, .modify(payload: Data("hi-pm".utf8), note: "文本"),
               "WS 帧脚本：字符串返回改写文本（日志: \(activityLog.prefix(300))）")
    test.equal(runRule("return false;", frame: textFrame), .drop, "WS 帧脚本：false 丢帧")
    test.equal(runRule("return { body: message.body + '!' };", frame: textFrame),
               .modify(payload: Data("hi!".utf8), note: "文本"), "WS 帧脚本：body 字段改写")
    let binaryFrame = WSFrame(direction: .upstream, opcode: 0x2, fin: true, masked: true, payload: Data([9, 9]))
    test.equal(runRule(#"return { base64: "AQID" };"#, frame: binaryFrame),
               .modify(payload: Data([1, 2, 3]), note: "二进制"), "WS 帧脚本：base64 改写二进制")
    test.equal(runRule(#"return { action: "close" };"#, frame: textFrame), .close, "WS 帧脚本：显式关闭连接")
    test.equal(runRule("", frame: textFrame), .pass, "WS 帧脚本：无返回放行")
}
