import Foundation
import NIOCore
import NIOPosix
@testable import ProxyMirrorCore

/// Exercise the same AppState actions used by Settings, including a live socket surviving
/// an ordinary apply and being closed by an explicit restart at an unchanged endpoint.
@MainActor
func checkSettingsRuntime(_ test: CoreAssertions) throws {
    let directory = try makeCheckDirectory()
    let suite = "ProxyMirror.SettingsChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let settings = AppSettings(defaults: defaults)
    settings.autoStartProxy = false
    settings.autoTakeOverSystemProxy = false
    settings.autoStartRecording = false
    let previousSupport = ProcessInfo.processInfo.environment["PM_SUPPORT_DIR"]
    setenv("PM_SUPPORT_DIR", directory.path, 1)
    defer {
        if let previousSupport { setenv("PM_SUPPORT_DIR", previousSupport, 1) }
        else { unsetenv("PM_SUPPORT_DIR") }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    let shared = ProxyEngine.shared
    let sharedSink = shared.sink
    let sharedMITM = shared.mitmEnabled, sharedHTTP2 = shared.http2Enabled
    let sharedExcluded = shared.mitmExcludedHosts, sharedLimit = shared.captureLimit
    let sharedRecording = shared.recordingEnabled
    let passive = AppState(settings: settings, launchServices: false)
    test.expect(!passive.hasResolvedEngine, "A passive AppState does not allocate an engine or load a CA")
    test.equal(passive.listenerPort, settings.port, "Reading a passive endpoint does not resolve runtime dependencies")
    test.expect(!passive.hasResolvedEngine, "Reading passive preferences preserves lazy services")
    test.expect(shared.sink === sharedSink && shared.mitmEnabled == sharedMITM && shared.http2Enabled == sharedHTTP2
                && shared.mitmExcludedHosts == sharedExcluded && shared.captureLimit == sharedLimit
                && shared.recordingEnabled == sharedRecording, "Constructing a passive AppState leaves shared engine state untouched")

    let authority = CertificateAuthority(storageDirectory: directory.appendingPathComponent("isolated-ca"))
    let engine = ProxyEngine(certificateAuthority: authority)
    let state = AppState(settings: settings, engine: engine, certificateAuthority: authority, launchServices: false)
    test.expect(!state.hasResolvedEngine && engine.sink == nil,
                "Injecting an engine does not reconfigure it until an explicit runtime action")
    state.applyAndRestartIfNeeded()
    test.expect(state.engine === engine && state.engine.certificateAuthority === authority && engine.sink === state,
                "Runtime actions use the injected engine and its matching certificate authority")
    test.expect(!state.recordingEnabled && !engine.recordingEnabled,
                "启动录制偏好关闭时真实引擎和应用状态均从暂停开始")
    defer {
        state.stopProxy()
        try? engine.group.syncShutdownGracefully()
    }
    let initialHTTP2 = settings.http2Enabled
    let requestedHTTP2 = !sharedHTTP2
    _ = try AutomationControl.execute(["operation": "http_version", "http2": requestedHTTP2], app: state)
    test.expect(engine.http2Enabled == requestedHTTP2 && shared.http2Enabled == sharedHTTP2,
                "Automation changes the injected engine without reconfiguring the shared runtime")
    settings.http2Enabled = initialHTTP2
    engine.http2Enabled = initialHTTP2
    let context = state.runtimeContext
    let httpsRequest = ComposeService.ParsedRequest(method: "GET", url: "https://runtime-ca.example.test/", headers: [], body: nil)
    test.equal(try context.trustedCA(for: httpsRequest), authority.caCertPath,
               "Compose trust uses the same private CA as its selected proxy engine")
    engine.mitmExcludedHosts = ["runtime-ca.example.test"]
    test.equal(try context.trustedCA(for: httpsRequest), nil,
               "Compose consults its selected engine's MITM exclusions")
    engine.mitmExcludedHosts = []

    // The same Transaction can be inspected in two independent fixtures. Only
    // the state receiving its engine callback may refresh body-dependent views.
    let body = Transaction()
    body.host = "isolated-body.example.test"
    body.responseBody = Data("before".utf8)
    state.store.add(body)
    passive.store.add(body)
    state.toggleSplit()
    let bodyFilter = TrafficConditionGroup(conditions: [TrafficCondition(field: .responseBody, value: "after")])
    state.activeTab.filter.conditions = bodyFilter
    state.splitStore?.filter.conditions = bodyFilter
    passive.store.filter.conditions = bodyFilter
    test.expect(state.activeTab.visible.isEmpty && state.splitStore?.visible.isEmpty == true
                && passive.store.visible.isEmpty, "Independent body-filtered workspaces cache their initial unmatched rows")
    body.responseBody = Data("after".utf8)
    DispatchQueue.global().async { state.transactionBodyUpdated(body) }
    let bodyDeadline = Date().addingTimeInterval(2)
    while (state.activeTab.visible.isEmpty || state.splitStore?.visible.isEmpty == true) && Date() < bodyDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    test.expect(state.activeTab.visible.contains(where: { $0 === body })
                && state.splitStore?.visible.contains(where: { $0 === body }) == true,
                "An off-main body callback refreshes its owning state's active and split workspaces")
    test.expect(passive.store.visible.isEmpty && !passive.hasResolvedEngine,
                "Another AppState receives no body refresh and does not resolve runtime services")
    state.toggleSplit()

    state.setMITMExcludedHosts(" api.example.test \n\n*.private.test\r\n")
    test.equal(settings.mitmExcludedHosts, ["api.example.test", "*.private.test"],
               "SSL 排除框持久化清理后的主机列表")
    let connection = ConnState(engine: engine)
    test.expect(!connection.allowsMITM(host: "api.example.test")
                && !connection.allowsMITM(host: "service.private.test")
                && connection.allowsMITM(host: "public.example.test"),
                "SSL 排除编辑即时改变实际新连接的 MITM 决策")
    state.setMITMExcludedHosts("")
    test.expect(connection.allowsMITM(host: "api.example.test"), "清空排除框即时恢复解密")

    state.addWorkspace()
    let active = state.activeStore
    state.setFollowLatest(true)
    test.expect(settings.followLatest && active.followLatest && !state.store.followLatest,
                "自动滚动设置即时应用于当前工作区，不改变其他工作区")
    let latest = Transaction()
    latest.host = "latest.example.test"
    active.add(latest)
    test.equal(active.selectedID, latest.id, "启用自动滚动后真实新增流量自动选中")
    state.setFollowLatest(false)
    let later = Transaction()
    later.host = "later.example.test"
    active.add(later)
    test.equal(active.selectedID, latest.id, "关闭自动滚动后新增流量不再抢选中项")

    // Start on an OS-selected port without administrator authorization or system proxy changes.
    try engine.start(port: 0)
    settings.port = engine.port
    state.proxyRunning = true
    state.recordingEnabled = false
    for operation in ["status", "proxy_address"] {
        let data = try AutomationControl.execute(["operation": operation], app: state)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        test.equal(object?["port"] as? Int, Int(engine.port), "Automation \(operation) returns the injected listener's actual port")
    }
    let originalCopyProxy = settings.appendProxyToCommands
    settings.appendProxyToCommands = true
    let copied = Transaction(); copied.host = "runtime-copy.example.test"; copied.requestBodyComplete = true
    test.expect(ExportService.curlCommand(copied, runtime: state.runtimeContext).contains("127.0.0.1:\(engine.port)")
                && ExportService.httpieCommand(copied, runtime: state.runtimeContext).contains("127.0.0.1:\(engine.port)"),
                "Both command adapters use the selected runtime's live endpoint")
    settings.appendProxyToCommands = originalCopyProxy
    let client = try ClientBootstrap(group: engine.group).connect(host: "127.0.0.1", port: Int(engine.port)).wait()
    defer { try? client.close().wait() }
    let closed = LockedBox(false)
    client.closeFuture.whenComplete { _ in closed.set(true) }

    state.applyAndRestartIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    test.expect(!closed.value && client.isActive, "普通应用相同监听设置不会中断已有 TCP 连接")

    state.applyAndRestartProxy()
    let deadline = Date().addingTimeInterval(5)
    while (state.proxyRestarting || !closed.value) && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    test.expect(!state.proxyRestarting && closed.value, "端口和 LAN 不变时明确重启仍关闭旧 TCP 连接")
    test.expect(state.proxyRunning && engine.isRunning && engine.port == settings.port,
                "明确重启重新建立同一端点的监听")
    test.expect(!state.recordingEnabled && !engine.recordingEnabled,
                "明确重启保留暂停录制状态")
    settings.port = originalListenerPortForCheck(engine.port)
    test.equal(state.listenerPort, engine.port, "未应用端口偏好不会改变向客户端公开的实际监听端口")
    settings.port = engine.port
    let replacement = try ClientBootstrap(group: engine.group)
        .connect(host: "127.0.0.1", port: Int(engine.port)).wait()
    try replacement.close().wait()

    // Ordinary application must keep the active route pointing at its existing listener.
    let originalPort = engine.port
    settings.port = originalPort == 65535 ? originalPort - 1 : originalPort + 1
    state.systemProxyActive = true
    state.applyAndRestartIfNeeded()
    state.systemProxyActive = false
    test.expect(settings.port == originalPort && engine.port == originalPort && engine.isRunning,
                "普通应用不在系统代理仍接管时擅自更换监听端点")
    test.equal(state.systemProxyMessage, Strings.Errors.appStateRestoreTheSystemProxyBeforeChangingTheListen,
                "拒绝不安全的端点修改时给出明确反馈")

    let occupied = try ServerBootstrap(group: engine.group).bind(host: "127.0.0.1", port: 0).wait()
    defer { try? occupied.close().wait() }
    settings.port = UInt16(occupied.localAddress!.port!)
    state.applyAndRestartProxy()
    let recoveryDeadline = Date().addingTimeInterval(5)
    while state.proxyRestarting && Date() < recoveryDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    test.expect(!state.proxyRestarting && state.proxyRunning && engine.isRunning
                && engine.port == originalPort && settings.port == originalPort,
                "新端口已被占用时重启恢复原监听及设置")
    let restoredSuffix = Strings.Errors.appStateRestoredThePreviousListenerPort(Int(originalPort))
    test.expect(state.proxyStartError?.hasSuffix(restoredSuffix) == true
                && (state.proxyStartError?.count ?? 0) > restoredSuffix.count,
                "重绑失败并恢复后仍显示原始失败原因")
}

private func originalListenerPortForCheck(_ current: UInt16) -> UInt16 {
    current == 65535 ? current - 1 : current + 1
}
