import Foundation
@testable import ProxyMirrorCore

@MainActor
func runScriptingLoopback(engine: ProxyEngine, source: String, records: () -> [Transaction]) throws {
    let config = InterceptionConfig.shared
    let previous = config.rewrite.value
    defer { config.rewrite.set(previous) }

    func send(_ path: String, body: String? = nil, arguments: [String] = []) throws -> String {
        let curl = Process()
        let output = Pipe()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = [
            "-q", "--silent", "--show-error", "--include", "--noproxy", "", "--proxy",
            "http://\(engine.listenAddress)", "--max-time", "5",
        ] + (body.map { ["--data-binary", $0] } ?? []) + arguments + [source + path]
        curl.standardOutput = output
        curl.standardError = output
        try curl.run()
        while curl.isRunning { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func rule(_ name: String, path: String, phase: ScriptingPhase, operation: String = "", js: String) -> RewriteRule {
        let matcher = URLRule(name: name, host: "127.0.0.1", path: path,
                              includeSubpaths: false, graphqlQueryName: operation)
        return RewriteRule(rule: matcher, actions: [.script(phase: phase, source: js)])
    }

    let first = rule("第一条", path: "/scripting", phase: .request, js: """
        if (typeof fetch !== "undefined" || typeof require !== "undefined" || typeof process !== "undefined") {
            throw new Error("host interface available");
        }
        message.body += "|one";
        console.log("first request script");
        """)
    let broken = rule("异常条目", path: "/scripting", phase: .request,
                      js: #"throw new Error("local script exception");"#)
    let next = rule("第二条", path: "/scripting", phase: .request, js: #"message.body += "|two";"#)
    let response = rule("响应脚本", path: "/scripting", phase: .response, js: """
        const echo = JSON.parse(message.body);
        message.status = 202;
        message.headers.push({name: "X-PM-Scripting", value: "ran"});
        message.body = JSON.stringify({ sent: echo.body });
        """)
    config.rewrite.set([RewriteRuleSet(name: "先执行", rules: [first, broken]),
                        RewriteRuleSet(name: "后执行", rules: [next, response])])

    let transformed = try send("/scripting", body: "before")
    check(transformed.contains("HTTP/1.1 202") && transformed.contains("X-PM-Scripting: ran")
          && transformed.hasSuffix(#"{"sent":"before|one|two"}"#), "loopback: 脚本按分组顺序修改请求和响应")
    let audit = records().last?.scriptingLogs ?? []
    let successful = audit.filter { $0.hasSuffix("已执行") }
    check(successful.count == 3 && successful[0].contains("第一条") && successful[1].contains("第二条")
          && successful[2].contains("响应脚本"), "loopback: 流量记录保留实际脚本执行顺序")
    check(audit.contains { $0.contains("local script exception") }
          && audit.contains { $0.contains("first request script") }, "loopback: 脚本日志与异常均可追踪")

    let named = rule("FindUser", path: "/scripting-graphql", phase: .response, operation: "FindUser", js: """
        message.status = 202;
        message.body = JSON.stringify({ operation: message.graphqlOperationName });
        """)
    config.rewrite.set([RewriteRuleSet(rules: [named])])
    let graph = try send("/scripting-graphql", body: #"{"query":"query FindUser { user }","operationName":"FindUser"}"#,
                         arguments: ["-H", "Content-Type: application/graphql+json"])
    check(graph.contains("HTTP/1.1 202") && graph.hasSuffix(#"{"operation":"FindUser"}"#),
          "loopback: 响应脚本按 GraphQL 请求操作名匹配")
    let other = try send("/scripting-graphql", body: #"{"query":"query Other { user }","operationName":"Other"}"#,
                          arguments: ["-H", "Content-Type: application/json"])
    check(other.contains("HTTP/1.1 200") && records().last?.scriptingLogs.isEmpty == true,
          "loopback: 同地址的其他 GraphQL 操作保持原报文")

    let timer = rule("无限循环", path: "/scripting-timeout", phase: .request, js: "while (true) {}")
    config.rewrite.set([RewriteRuleSet(rules: [timer])])
    let original = try send("/scripting-timeout")
    check(original.contains("HTTP/1.1 200") &&
          records().last?.scriptingLogs.contains(where: { $0.contains("超过 400 ms") }) == true,
          "loopback: 脚本超时后原请求继续")
    let independent = try send("/scripting-after-timeout")
    check(independent.contains("HTTP/1.1 200") && records().last?.scriptingLogs.isEmpty == true,
          "loopback: 超时脚本不阻塞其他请求")

    let ws = rule("读取帧", path: "/ws", phase: .webSocket,
                  js: #"console.log("fixture-frame", message.direction, message.body);"#)
    config.rewrite.set([RewriteRuleSet(rules: [ws])])
    let upgrade = try send("/ws", arguments: [
        "--http1.1", "-H", "Connection: Upgrade", "-H", "Upgrade: websocket",
        "-H", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==", "-H", "Sec-WebSocket-Version: 13",
    ])
    let limit = Date().addingTimeInterval(2)
    let expected = "fixture-frame recv hi"
    while !ScriptingActivity.shared.entries.contains(where: { $0.text.contains(expected) }) && Date() < limit {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    check(upgrade.contains("101 Switching Protocols") &&
          ScriptingActivity.shared.entries.contains(where: { $0.text.contains(expected) }),
          "loopback: WebSocket 脚本读取接收帧并写入日志")

    let modify = rule("改写帧", path: "/ws", phase: .webSocket,
                      js: #"if (message.direction === "recv" && message.opcode === 1) return message.body + "-pm";"#)
    config.rewrite.set([RewriteRuleSet(rules: [modify])])
    let modifiedUpgrade = try send("/ws", arguments: [
        "--http1.1", "-H", "Connection: Upgrade", "-H", "Upgrade: websocket",
        "-H", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==", "-H", "Sec-WebSocket-Version: 13",
    ])
    let modifyLimit = Date().addingTimeInterval(3)
    func modifiedDownstreamSeen() -> Bool {
        records().last?.websocketFrames.contains {
            $0.direction == .downstream && $0.fullText?.hasSuffix("-pm") == true
        } ?? false
    }
    while !modifiedDownstreamSeen() && Date() < modifyLimit {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    let dbgFrames = records().last?.websocketFrames.map { "\($0.direction.rawValue):\($0.fullText ?? "<\($0.payload.count)B op\($0.opcode)>")" } ?? []
    check(modifiedUpgrade.contains("101 Switching Protocols") && modifiedDownstreamSeen(),
          "loopback: WebSocket 脚本改写下行文本帧")
}
