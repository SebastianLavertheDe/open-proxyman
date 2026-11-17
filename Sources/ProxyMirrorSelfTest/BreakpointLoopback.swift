import Foundation
@testable import ProxyMirrorCore

@MainActor
func runBreakpointLoopback(engine: ProxyEngine, source: String, records: () -> [Transaction]) throws {
    let manager = BreakpointManager.shared
    let config = InterceptionConfig.shared
    let originalRules = config.breakpoints.value
    let originalEnabled = manager.enabled
    let originalTimeout = engine.breakpointTimeout
    manager.enabled = true
    defer {
        manager.discardAll()
        manager.enabled = originalEnabled
        engine.breakpointTimeout = originalTimeout
        config.breakpoints.set(originalRules)
    }

    func start(_ path: String, body: String? = nil, arguments: [String] = []) throws -> (Process, Pipe) {
        let curl = Process()
        let output = Pipe()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = [
            "--silent", "--show-error", "--include", "--noproxy", "", "--proxy",
            "http://\(engine.listenAddress)", "--max-time", "8",
        ] + (body.map { ["--data-binary", $0] } ?? []) + arguments + [source + path]
        curl.standardOutput = output
        curl.standardError = output
        try curl.run()
        return (curl, output)
    }

    func wait(_ seconds: TimeInterval = 4, until ready: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !ready() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.015))
        }
        guard ready() else { throw BreakpointLoopbackError.timeout }
    }

    func read(_ run: (Process, Pipe)) throws -> String {
        try wait { !run.0.isRunning }
        return String(decoding: run.1.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    let requestRule = URLRule(name: "测试请求", scheme: "http", host: "127.0.0.1", path: "/breakpoint-request*")
    config.breakpoints.set([BreakpointRule(rule: requestRule, phase: .request)])
    let first = try start("/breakpoint-request-one", body: "hello")
    let second = try start("/breakpoint-request-two")
    try wait { manager.held.count == 2 }
    guard let one = manager.held.first(where: { $0.summary.hasSuffix("-one") }),
          let two = manager.held.first(where: { $0.summary.hasSuffix("-two") }) else {
        throw BreakpointLoopbackError.missingItems
    }
    check(first.0.isRunning && second.0.isRunning, "loopback: 两条请求各自停在断点")
    check(one.message.body == Data("hello".utf8), "loopback: 断点捕获完整 UTF-8 请求正文")
    do {
        let invalid = one.message.text.replacingOccurrences(of: "Host: ", with: "Host: changed-")
        try manager.applyAndExecute(one, draft: invalid)
        check(false, "loopback: 拒绝改写连接相关的头")
    } catch {
        check(manager.held.contains { $0.id == one.id }, "loopback: 无效编辑后继续等待")
    }

    let replacement = one.message.text.replacingOccurrences(of: "\n\nhello", with: "\nX-Breakpoint: edited\n\nupdated text")
    try manager.applyAndExecute(one, draft: replacement)
    let firstResponse = try read(first)
    check(firstResponse.contains("updated text"), "loopback: 已编辑请求正文送达上游")
    check(manager.held.map(\.id) == [two.id] && second.0.isRunning, "loopback: 放行一条保留另一条等待")
    manager.drop(two)
    let droppedResponse = try read(second)
    check(droppedResponse.contains("502 Bad Gateway") && droppedResponse.contains("已取消断点"),
          "loopback: 取消后向客户端返回明确错误")
    try wait { records().contains { $0.id == two.txID && $0.state == .failed } }
    let canceled = records().first { $0.id == two.txID }
    check(canceled?.tConnected == nil && canceled?.breakpointRules == ["测试请求"],
          "loopback: 取消的请求未连接上游，流量保留规则命中")

    let responseRule = URLRule(name: "测试响应", scheme: "http", host: "127.0.0.1", path: "/breakpoint-response")
    config.breakpoints.set([BreakpointRule(rule: responseRule, phase: .response)])
    let response = try start("/breakpoint-response")
    try wait { manager.held.first?.phase == .response }
    guard let pending = manager.held.first else { throw BreakpointLoopbackError.missingItems }
    let edited = "HTTP/1.1 202 Accepted\n" + pending.message.text
        .components(separatedBy: "\n\n")[0]
        .components(separatedBy: "\n").dropFirst().joined(separator: "\n")
        + "\nX-Breakpoint: response\n\nresponse replaced"
    try manager.applyAndExecute(pending, draft: edited)
    let responseOutput = try read(response)
    check(responseOutput.contains("202 Accepted") && responseOutput.contains("X-Breakpoint: response")
          && responseOutput.hasSuffix("response replaced"), "loopback: 响应断点改写状态、头和正文")
    try wait { records().contains { $0.id == pending.txID && $0.statusCode == 202 && $0.state == .completed } }
    let updated = records().first { $0.id == pending.txID }
    check(updated?.responseBody == Data("response replaced".utf8), "loopback: 捕获记录反映已改写响应")

    config.breakpoints.set([BreakpointRule(rule: requestRule, phase: .request)])
    let streaming = try start("/breakpoint-request-stream", body: "stream text",
                              arguments: ["-H", "Transfer-Encoding: chunked"])
    try wait { manager.held.count == 1 }
    guard let pendingStream = manager.held.first else { throw BreakpointLoopbackError.missingItems }
    check(pendingStream.message.body == nil, "loopback: 分块请求可暂停头部并保留原始正文")
    manager.continueOriginal(pendingStream)
    let streamedResponse = try read(streaming)
    check(streamedResponse.contains("stream text"), "loopback: 原样继续透传分块正文")

    engine.breakpointTimeout = .milliseconds(250)
    let timed = try start("/breakpoint-request-timeout")
    let timeoutOutput = try read(timed)
    check(timeoutOutput.contains("504 Gateway Timeout") && timeoutOutput.contains("断点等待超时"),
          "loopback: 断点超时返回 504")
    check(manager.held.isEmpty, "loopback: 超时移除等待项")

    engine.breakpointTimeout = originalTimeout
    let cleared = try start("/breakpoint-request-clear")
    try wait { manager.held.count == 1 }
    let clearedID = manager.held.first?.txID
    engine.clearBreakpointSession()
    manager.discardAll()
    let clearOutput = try read(cleared)
    check(clearOutput.contains("会话已清空") && manager.held.isEmpty
          && !records().contains { $0.id == clearedID }, "loopback: 清空会话释放队列且不重新插入流量")
}

private enum BreakpointLoopbackError: Error {
    case timeout
    case missingItems
}
