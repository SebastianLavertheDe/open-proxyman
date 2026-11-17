import Foundation
import NIOCore
import NIOPosix
@testable import ProxyMirrorCore

@MainActor
func runReverseLoopbackTests(engine: ProxyEngine, upstream: UInt16, occupied: UInt16,
                             captured: () -> Transaction?) throws {
    let controller = ReverseProxyController.shared
    controller.start(engine: engine)
    let saved = controller.rules
    defer {
        try? controller.save(saved)
        controller.stop()
    }

    let reservation = try ServerBootstrap(group: engine.group).bind(host: "127.0.0.1", port: 0).wait()
    let port = UInt16(reservation.localAddress?.port ?? 0)
    try reservation.close().wait()
    let rule = ReverseProxyRule(listenPort: port, remoteHost: "127.0.0.1", remotePort: Int(upstream))
    try controller.save([rule])
    check(controller.listening.contains(port), "loopback: 反向代理开始监听")

    func curl(_ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-q", "-sS", "--noproxy", "*", "--max-time", "4",
                             "http://127.0.0.1:\(port)/reverse%2Fsample?key=1"] + arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        while process.isRunning { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    let response = try curl(["-H", "Host: other.invalid", "--data-binary", "reverse body"])
    eq(response.0, 0, "loopback: 反向代理可转发 POST")
    let body = try JSONSerialization.jsonObject(with: Data(response.1.utf8)) as? [String: Any]
    eq(body?["host"] as? String, "127.0.0.1:\(upstream)", "loopback: 反向代理使用上游 Host")
    eq(body?["path"] as? String, "/reverse%2Fsample?key=1", "loopback: 反向代理保留转义路径和查询")
    eq(captured()?.requestBody, Data("reverse body".utf8), "loopback: 反向代理流量记录正文")
    eq(captured()?.originalURL, "http://127.0.0.1:\(port)/reverse%2Fsample?key=1", "loopback: 反向代理记录本机入口")

    let nonOriginForm = try curl(["--request-target", "http://127.0.0.1:\(occupied)/", "-w", "%{http_code}"])
    eq(nonOriginForm.1, "400", "loopback: 反向代理只接受 origin-form")
    let conflict = ReverseProxyRule(listenPort: occupied, remoteHost: "127.0.0.1", remotePort: Int(upstream))
    do {
        try controller.save([rule, conflict])
        check(false, "loopback: 反向代理端口冲突应失败")
    } catch ReverseProxyError.bind {
        eq(controller.rules, [rule], "loopback: 绑定失败保留旧规则")
        let persisted: [ReverseProxyRule]? = RulesFileIO.load("reverse.json")
        eq(persisted, [rule], "loopback: 绑定失败保留已保存配置")
    }
    try controller.save([])
    let stopped = try curl([])
    check(stopped.0 != 0 && !controller.listening.contains(port), "loopback: 删除反向代理规则关闭端口")
}
