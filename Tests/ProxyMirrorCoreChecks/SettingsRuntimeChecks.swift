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
    let previousSupport = ProcessInfo.processInfo.environment["PM_SUPPORT_DIR"]
    setenv("PM_SUPPORT_DIR", directory.path, 1)
    defer {
        if let previousSupport { setenv("PM_SUPPORT_DIR", previousSupport, 1) }
        else { unsetenv("PM_SUPPORT_DIR") }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    let engine = ProxyEngine.shared
    guard !engine.isRunning else {
        test.expect(false, "设置运行时回归需独占测试代理引擎")
        return
    }
    let previousSink = engine.sink
    let previousMITM = engine.mitmEnabled
    let previousHTTP2 = engine.http2Enabled
    let previousExcluded = engine.mitmExcludedHosts
    let previousLimit = engine.captureLimit
    let previousRecording = engine.recordingEnabled
    let state = AppState(settings: settings, launchServices: false)
    defer {
        state.stopProxy()
        engine.sink = previousSink
        engine.mitmEnabled = previousMITM
        engine.http2Enabled = previousHTTP2
        engine.mitmExcludedHosts = previousExcluded
        engine.captureLimit = previousLimit
        engine.recordingEnabled = previousRecording
    }

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
    test.expect(state.systemProxyMessage?.contains("先恢复系统代理") == true,
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
    test.expect(state.proxyStartError?.contains("已恢复原监听端口") == true,
                "重绑失败并恢复后仍显示原始失败原因")
}
