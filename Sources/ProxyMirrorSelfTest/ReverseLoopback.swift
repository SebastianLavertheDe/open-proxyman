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
    let savedOrganization = RuleOrganizationStore.shared.snapshot()
    defer {
        try? controller.save(saved, organization: savedOrganization)
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
    var folderDraft = RuleFolderEditingDraft(savedOrganization)
    let folder = try folderDraft.createFolder(tool: "reverse", name: "Reverse loopback fixture", parentID: nil)
    folderDraft.assign(ruleID: rule.id.uuidString, tool: "reverse", folderID: folder.id)
    folderDraft.organization.folders[folderDraft.organization.folders.firstIndex(where: { $0.id == folder.id })!].enabled = false
    var organization = try folderDraft.merging(into: savedOrganization, tool: "reverse", keeping: [rule.id.uuidString])
    try controller.save([rule], organization: organization)
    check(!controller.listening.contains(port), "loopback: 停用所属文件夹关闭反向代理真实监听端口")
    check(try curl([]).0 != 0, "loopback: 文件夹停用后客户端无法连接反向代理端口")
    organization.folders[organization.folders.firstIndex(where: { $0.id == folder.id })!].enabled = true
    try controller.save([rule], organization: organization)
    check(controller.listening.contains(port), "loopback: 启用所属文件夹重新绑定反向代理监听端口")
    check(try curl([]).0 == 0, "loopback: 文件夹启用后反向代理恢复真实转发")
    let previousOrganization = RuleOrganizationStore.shared.snapshot()
    var attemptedOrganization = previousOrganization
    attemptedOrganization.folders.append(RuleFolder(tool: "reverse", name: "Uncommitted bind failure", parentID: nil, enabled: true))
    let conflict = ReverseProxyRule(listenPort: occupied, remoteHost: "127.0.0.1", remotePort: Int(upstream))
    do {
        try controller.save([rule, conflict], organization: attemptedOrganization)
        check(false, "loopback: 反向代理端口冲突应失败")
    } catch ReverseProxyError.bind {
        eq(controller.rules, [rule], "loopback: 绑定失败保留旧规则")
        let persisted: RuleBackup? = RulesFileIO.load("rules.json")
        eq(persisted?.reverse, [rule], "loopback: 绑定失败保留已保存配置")
        eq(RuleOrganizationStore.shared.snapshot(), previousOrganization, "loopback: 绑定失败保留旧文件夹和规则归属")
        eq(persisted?.organization, previousOrganization, "loopback: 绑定失败不持久化待提交的文件夹")
    }
    try controller.save([])
    let stopped = try curl([])
    check(stopped.0 != 0 && !controller.listening.contains(port), "loopback: 删除反向代理规则关闭端口")
}
