import Foundation
import AppKit
import CoreGraphics
import Combine

/// 应用总控：代理启停、证书、系统代理、与 UI 的桥接
@MainActor
final class AppState: ObservableObject, TrafficSink {
    static let shared = AppState()

    let store = TrafficStore()
    let settings: AppSettings
    @Published private(set) var tabs: [TrafficStore] = []
    @Published private(set) var activeTabIndex = 0
    @Published private(set) var splitStore: TrafficStore?
    @Published private(set) var splitFocused = false
    var activeTab: TrafficStore { tabs[safe: activeTabIndex] ?? store }
    var activeStore: TrafficStore { splitFocused ? splitStore ?? activeTab : activeTab }

    @Published var proxyRunning = false
    @Published var recordingEnabled = true {
        didSet { ProxyEngine.shared.recordingEnabled = recordingEnabled }
    }
    @Published var proxyStartError: String?
    @Published var settingsTarget: SettingsSearchTarget?
    @Published private(set) var bridgePairingCode: String?
    @Published var showBridgePairing = false
    private var bridgeListener: BridgeListener?
    private var bridgeSessionID: UUID?
    @Published var systemProxyActive = false
    @Published private(set) var systemProxyServiceInstalled = SystemProxyController.shared.hasInstalledService
    @Published private(set) var systemProxyBusy = false
    @Published private(set) var proxyRestarting = false
    @Published var systemProxyMessage: String?
    private let transparentProxy = TransparentProxyController()
    private var transparentProxyChanges: AnyCancellable?
    @Published private(set) var transparentProxyState: TransparentProxyController.State = .idle
    var transparentProxyNeedsStop: Bool { transparentProxy.needsStop }
    var transparentProxyMenuTitle: String {
        guard TransparentProxyController.isAvailable else { return "透明抓包不可用…" }
        switch transparentProxyState {
        case .activating: return "取消透明抓包启动"
        case .awaitingApproval: return "取消透明抓包（等待系统批准）"
        case .connecting: return "取消透明抓包连接"
        case .running: return "停止透明抓包"
        case .stopping: return "正在停止透明抓包…"
        case .failed where transparentProxyNeedsStop: return "重试停止透明抓包"
        default: return "启动透明抓包…"
        }
    }

    @Published var caInstalled: Bool = false
    @Published private(set) var tlsKeyLogURL: URL?
    @Published var showCommentSheet = false
    @Published var caBannerDismissed = UserDefaults.standard.bool(forKey: "caBannerDismissed")
    @Published var activeTool: ToolKind?
    private(set) var toolTransaction: Transaction?
    private(set) var commentTargets: [Transaction] = []
    @Published var composeHistory: [ComposeService.ParsedRequest] = ComposeService.loadHistory()
    @Published var showCommandPalette = false
    @Published var showDiff = false
    @Published private(set) var diffPool: [Transaction] = []
    private(set) var diffTargets: [Transaction] = []
    @Published var showRuleBackup = false
    @Published var showCharlesRules = false
    @Published var showColumnEditor = false
    @Published var showLatencyEditor = false
    @Published var showFactoryReset = false
    @Published var showGistPublish = false
    private var storeChanges: AnyCancellable?
    @Published var dockRight = UserDefaults.standard.bool(forKey: "ui.dockRight") {
        didSet { UserDefaults.standard.set(dockRight, forKey: "ui.dockRight") }
    }
    @Published var certificateGuide: String?
    @Published var showResetCA = false
    @Published var showSidebar = true
    @Published var pinnedDomains: [String] = [] {
        didSet { UserDefaults.standard.set(pinnedDomains, forKey: "pinnedDomains") }
    }

    init(settings: AppSettings = .shared, launchServices: Bool = true) {
        self.settings = settings
        ProxyEngine.shared.sink = self
        tabs = [store]
        observeActiveWorkspace()
        store.maxTransactions = settings.maxTransactions
        store.followLatest = settings.followLatest
        ProxyEngine.shared.mitmEnabled = settings.mitmEnabled
        ProxyEngine.shared.http2Enabled = settings.http2Enabled
        ProxyEngine.shared.mitmExcludedHosts = settings.mitmExcludedHosts
        CertificateAuthority.shared.setCustomCertificateProvider { host in
            CustomCertificateStore.shared.chain(forHost: host)
        }
        ProxyEngine.shared.captureLimit = settings.maxBodyMB * 1024 * 1024
        transparentProxyChanges = transparentProxy.$state.dropFirst().sink { [weak self] state in
            guard let self else { return }
            self.transparentProxyState = state
            switch state {
            case .awaitingApproval:
                self.systemProxyMessage = "请在 macOS 系统设置中允许 ProxyMirror 网络扩展。"
            case .idle, .failed:
                if !self.transparentProxyNeedsStop { ProxyEngine.shared.stopTransparentIngress() }
                if case .failed(let message) = state { self.systemProxyMessage = message }
            default:
                break
            }
        }
        guard launchServices else { return }
        pinnedDomains = UserDefaults.standard.stringArray(forKey: "pinnedDomains") ?? []
        caInstalled = CertInstaller.isInstalled()
        let hasExtension = TransparentProxyController.isAvailable
        if settings.autoStartProxy {
            startProxy(automaticallyTakeOver: !hasExtension)
        }
        if hasExtension {
            Task { [weak self] in
                guard let self else { return }
                await self.transparentProxy.recover()
                if self.settings.autoStartProxy { self.takeOverSystemProxyIfConfigured() }
            }
        }
        ProcessAttribution.shared.startPolling()
        maybeSnapshotForDebug()
    }

    private func observeActiveWorkspace() {
        store.setWorkspaceVisible(store === activeTab)
        for tab in tabs { tab.setWorkspaceVisible(tab === activeTab) }
        storeChanges = activeStore.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    func addWorkspace() {
        let view = TrafficStore(sharing: store)
        view.followLatest = settings.followLatest
        tabs.append(view)
        selectWorkspace(tabs.count - 1)
    }

    func selectWorkspace(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabIndex = index
        focusSplit(false)
    }

    func closeWorkspace(_ index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        let current = activeTab
        tabs.remove(at: index)
        selectWorkspace(tabs.firstIndex(where: { $0 === current }) ?? min(index, tabs.count - 1))
    }

    func toggleSplit() {
        if splitStore != nil {
            splitStore = nil
            focusSplit(false)
        } else {
            let view = TrafficStore(sharing: store)
            view.followLatest = settings.followLatest
            splitStore = view
            focusSplit(true)
        }
    }

    func focusSplit(_ focused: Bool) {
        splitFocused = focused && splitStore != nil
        observeActiveWorkspace()
    }

    func detachedTransaction(workspace: UUID, id: UUID) -> Transaction? {
        let candidate = (tabs + [splitStore].compactMap { $0 }).first { $0.id == workspace }
        return (candidate ?? store).transaction(id: id)
    }

    /// 调试用：设置 PM_SNAPSHOT 环境变量后，延时截取主窗口保存 PNG 并退出（自窗口截图无需屏幕录制权限）
    private func maybeSnapshotForDebug() {
        guard let path = ProcessInfo.processInfo.environment["PM_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["PM_SNAPSHOT_DELAY"] ?? "6") ?? 6
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // 调试：自动选中第一条并切到指定 Tab，便于验证详情面板
            if ProcessInfo.processInfo.environment["PM_SNAPSHOT_SELECT"] == "1" {
                let store = self.store
                store.selectedID = store.visible.first?.id
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let win = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet }),
                      let content = win.contentView else { exit(1) }
                // 离屏渲染视图层级（不依赖窗口可见性）
                let pdf = content.dataWithPDF(inside: content.bounds)
                try? pdf.write(to: URL(fileURLWithPath: path))
                NSLog("[ProxyMirror] 快照已保存: \(path)")
                exit(0)
            }
        }
    }

    // MARK: 代理启停

    func startProxy(automaticallyTakeOver: Bool = true, duringRestart: Bool = false) {
        guard !proxyRunning, !proxyRestarting || duringRestart else { return }
        applyRuntimeSettings()
        do {
            try CertificateAuthority.shared.ensureCA()
            UpstreamTrust.prewarm()
            try ProxyEngine.shared.start(port: settings.port, lan: settings.lanAccess)
            ReverseProxyController.shared.start(engine: ProxyEngine.shared)
            proxyRunning = true
            DiagnosticLog.record("listener started port=\(settings.port) lan=\(settings.lanEnabled) http2=\(settings.http2Enabled) mitm=\(settings.mitmEnabled)")
            proxyStartError = nil
            if automaticallyTakeOver { takeOverSystemProxyIfConfigured() }
        } catch {
            proxyStartError = "启动失败：\(error.localizedDescription)\n请在设置中检查端口与局域网地址。"
        }
    }

    private func takeOverSystemProxyIfConfigured() {
        guard settings.autoTakeOverSystemProxy, proxyRunning, !systemProxyActive,
              !systemProxyBusy, !transparentProxyNeedsStop else { return }
        startSystemProxy()
    }

    func stopProxy() {
        guard !systemProxyBusy, !proxyRestarting else { return }
        if transparentProxyNeedsStop {
            Task {
                if await stopTransparentProxy() { stopProxy() }
            }
            return
        }
        if systemProxyActive {
            stopSystemProxy { [weak self] restored in
                if restored { self?.stopProxy() }
            }
            return
        }
        ReverseProxyController.shared.stop()
        ProxyEngine.shared.stop()
        stopBridgeCapture()
        proxyRunning = false
        DiagnosticLog.record("listener stopped")
    }

    func toggleTransparentProxy() {
        guard !proxyRestarting else { return }
        guard TransparentProxyController.isAvailable else {
            systemProxyMessage = "此版本没有透明代理扩展。请使用带网络扩展的签名版本。"
            return
        }
        if transparentProxyNeedsStop {
            Task { _ = await stopTransparentProxy() }
            return
        }
        guard !systemProxyActive, !systemProxyBusy else {
            systemProxyMessage = "请先恢复系统代理，再启动透明抓包。"
            return
        }
        Task {
            guard !transparentProxyNeedsStop, !systemProxyActive, !systemProxyBusy, !proxyRestarting else { return }
            if !proxyRunning { startProxy(automaticallyTakeOver: false) }
            guard proxyRunning else { return }
            _ = await startTransparentProxy()
        }
    }

    private func startTransparentProxy() async -> Bool {
        do {
            let ingress = try ProxyEngine.shared.startTransparentIngress()
            try await transparentProxy.start(port: ingress.port, token: ingress.token)
            return true
        } catch is CancellationError {
            if !transparentProxyNeedsStop { ProxyEngine.shared.stopTransparentIngress() }
        } catch {
            if !transparentProxyNeedsStop { ProxyEngine.shared.stopTransparentIngress() }
            systemProxyMessage = error.localizedDescription
        }
        return false
    }

    func stopTransparentProxy() async -> Bool {
        do {
            try await transparentProxy.stop()
            return true
        } catch {
            systemProxyMessage = error.localizedDescription
            return false
        }
    }

    func restoreCaptureOnExit(_ completion: @escaping (Bool) -> Void) {
        guard !systemProxyBusy, !proxyRestarting else { completion(false); return }
        if transparentProxyNeedsStop {
            Task {
                guard await stopTransparentProxy() else { completion(false); return }
                restoreCaptureOnExit(completion)
            }
        } else if systemProxyActive {
            stopSystemProxy(onComplete: completion)
        } else {
            completion(true)
        }
    }

    func toggleProxy() {
        guard !proxyRestarting else { return }
        if proxyRunning { stopProxy() } else { startProxy() }
    }

    func toggleRecording() {
        guard !proxyRestarting else { return }
        if proxyRunning {
            recordingEnabled.toggle()
        } else {
            recordingEnabled = true
            startProxy()
        }
    }

    func setMITMExcludedHosts(_ text: String) {
        let hosts = Self.mitmExcludedHosts(from: text)
        settings.mitmExcludedHosts = hosts
        ProxyEngine.shared.mitmExcludedHosts = hosts
    }

    static func mitmExcludedHosts(from text: String) -> [String] {
        text.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    func setFollowLatest(_ enabled: Bool) {
        settings.followLatest = enabled
        activeStore.followLatest = enabled
    }

    private func applyRuntimeSettings() {
        DiagnosticLog.record("applying runtime settings bodyLimitMB=\(settings.maxBodyMB) maxTransactions=\(settings.maxTransactions)")
        ProxyEngine.shared.mitmEnabled = settings.mitmEnabled
        ProxyEngine.shared.http2Enabled = settings.http2Enabled
        ProxyEngine.shared.mitmExcludedHosts = settings.mitmExcludedHosts
        CertificateAuthority.shared.setCustomCertificateProvider { host in
            CustomCertificateStore.shared.chain(forHost: host)
        }
        ProxyEngine.shared.captureLimit = settings.maxBodyMB * 1024 * 1024
        store.maxTransactions = settings.maxTransactions
        activeStore.followLatest = settings.followLatest
    }

    /// 普通应用只在监听端点变化时重绑，避免 SSL 开关等操作中断现有连接。
    func applyAndRestartIfNeeded() {
        applyRuntimeSettings()
        guard !systemProxyBusy, !proxyRestarting else { return }
        let engine = ProxyEngine.shared
        if proxyRunning, settings.port != engine.port || settings.lanAccess != engine.lanAccess {
            let oldPort = engine.port
            let oldLAN = engine.lanAccess
            guard !systemProxyActive, !transparentProxyNeedsStop else {
                settings.port = oldPort
                restoreLAN(oldLAN)
                systemProxyMessage = transparentProxyNeedsStop
                    ? "请先停止透明抓包，再调整监听地址或端口。"
                    : "请先恢复系统代理，再调整监听地址或端口。"
                return
            }
            restartListener(oldPort: oldPort, oldLAN: oldLAN)
        }
    }

    /// 用户明确要求重启：先恢复系统路由，再关闭全部旧连接，最后恢复之前的捕获模式。
    func applyAndRestartProxy() {
        guard !systemProxyBusy, !proxyRestarting else { return }
        applyRuntimeSettings()
        guard proxyRunning else {
            systemProxyMessage = "设置已应用，监听尚未启动。"
            return
        }
        let oldPort = ProxyEngine.shared.port
        let oldLAN = ProxyEngine.shared.lanAccess
        let resumeSystemProxy = systemProxyActive
        let resumeTransparentProxy = transparentProxyNeedsStop
        proxyRestarting = true
        systemProxyMessage = "正在应用并重启代理…"
        Task {
            defer { proxyRestarting = false }
            if resumeTransparentProxy, !(await stopTransparentProxy()) { return }
            if resumeSystemProxy {
                let restored = await withCheckedContinuation { continuation in
                    stopSystemProxy(duringRestart: true) { continuation.resume(returning: $0) }
                }
                guard restored else { return }
            }
            restartListener(oldPort: oldPort, oldLAN: oldLAN)
            // 重绑失败且旧端点也未能恢复时，不再把系统流量指向不存在的监听。
            guard proxyRunning else { return }
            if resumeTransparentProxy {
                _ = await startTransparentProxy()
            } else if resumeSystemProxy {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    startSystemProxy(duringRestart: true) { _, _ in continuation.resume() }
                }
            } else if proxyStartError == nil {
                systemProxyMessage = "设置已应用，代理已重启。"
            }
        }
    }

    private func restartListener(oldPort: UInt16, oldLAN: LANAccess?) {
        ReverseProxyController.shared.stop()
        ProxyEngine.shared.stop()
        stopBridgeCapture()
        proxyRunning = false
        startProxy(automaticallyTakeOver: false, duringRestart: true)
        if !proxyRunning {
            let error = proxyStartError
            settings.port = oldPort
            restoreLAN(oldLAN)
            startProxy(automaticallyTakeOver: false, duringRestart: true)
            if proxyRunning { proxyStartError = error.map { $0 + "\n已恢复原监听端口 \(oldPort)。" } }
        }
    }

    private func restoreLAN(_ access: LANAccess?) {
        settings.allowedPeerRanges = access?.allowedPeerRanges ?? []
        settings.lanEnabled = access != nil
        if let access {
            settings.lanAddress = access.address
            settings.deviceAddress = access.device
        }
    }

    func enablePinningPassthrough(bundleID: String, name: String) {
        let id = SSLApplicationRule.normalize(bundleID)
        guard SSLApplicationRule.isValid(id) else { return }
        let store = RulesStore.shared
        var backup = store.backup()
        let rule = SSLApplicationRule(bundleID: id, name: name, action: .passthrough)
        var applications = backup.sslApplications ?? []
        if let existing = applications.firstIndex(where: { $0.id == id }) {
            applications[existing] = rule
        } else {
            applications.append(rule)
        }
        backup.sslApplications = applications
        do {
            try store.install(backup)
            systemProxyMessage = "「\(name)」的新连接将使用透传。"
        } catch {
            systemProxyMessage = "保存透传规则失败：\(error.localizedDescription)"
        }
    }

    func showOrStartBridgeCapture() {
        if bridgeListener != nil {
            if bridgePairingCode != nil { showBridgePairing = true }
            return
        }
        guard proxyRunning, let lan = ProxyEngine.shared.lanAccess else {
            systemProxyMessage = "请先在「设置 → 常规」启用局域网代理，设置设备 IP / CIDR 白名单，再启动监听。"
            return
        }
        do {
            let sessionID = UUID()
            guard let policy = lan.peerPolicy else { throw ProxyError.invalidLANAccess }
            let receiver = try BridgeListener(address: lan.address, policy: policy) { [weak self] capture, address in
                guard let self, self.bridgeSessionID == sessionID, self.recordingEnabled,
                      let tx = Transaction(bridge: capture, deviceAddress: address,
                                           limit: ProxyEngine.shared.captureLimit, sink: self) else { return }
                self.store.ingestCaptured(tx)
            }
            bridgeListener = receiver
            bridgeSessionID = sessionID
            receiver.start { [weak self, weak receiver] state in
                Task { @MainActor in
                    guard let self, let receiver, self.bridgeListener === receiver else { return }
                    switch state {
                    case .ready:
                        self.bridgePairingCode = receiver.pairingCode
                        self.showBridgePairing = true
                    case .failed(let error), .waiting(let error):
                        self.stopBridgeCapture()
                        self.systemProxyMessage = "应用内捕获监听失败：\(error.localizedDescription)"
                    default: break
                    }
                }
            }
        } catch {
            systemProxyMessage = "应用内捕获监听失败：\(error.localizedDescription)"
        }
    }

    func stopBridgeCapture() {
        bridgeListener?.stop()
        bridgeListener = nil
        bridgeSessionID = nil
        bridgePairingCode = nil
        showBridgePairing = false
    }

    // MARK: TrafficSink（引擎 → UI）

    nonisolated func transactionCreated(_ tx: Transaction) {
        onMain { [store] in
            MainActor.assumeIsolated {
                if let address = tx.clientAddress, address != "127.0.0.1" {
                    tx.clientName = "设备 \(address)"
                }
                store.ingestCaptured(tx)
                if tx.clientAddress == nil || tx.clientAddress == "127.0.0.1",
                   tx.peerPort != 0, tx.clientName == nil {
                    ProcessAttribution.shared.attribute(peerPort: tx.peerPort) { info in
                        onMain {
                            MainActor.assumeIsolated {
                                tx.setClientApplication(info)
                                store.ingestUpdated(tx)
                            }
                        }
                    }
                }
            }
        }
    }

    nonisolated func transactionUpdated(_ tx: Transaction) {
        onMain { [store] in
            MainActor.assumeIsolated { store.ingestUpdated(tx) }
        }
    }

    nonisolated func transactionBodyUpdated(_ tx: Transaction) {
        onMain { [store] in
            MainActor.assumeIsolated {
                store.recordBodyBytes(tx)
                let app = AppState.shared
                app.activeTab.noteBodyCaptureUpdate(tx)
                app.splitStore?.noteBodyCaptureUpdate(tx)
            }
        }
    }

    // MARK: 动作

    func clearTraffic() {
        if !activeStore.isBrowsingSavedRequests && activeStore.filterMode != .archive {
            ProxyEngine.shared.clearBreakpointSession()
            BreakpointManager.shared.discardAll()
        }
        activeStore.clear()
    }

    func startSystemProxy(duringRestart: Bool = false, onComplete: ((Bool, String) -> Void)? = nil) {
        guard !proxyRestarting || duringRestart else {
            onComplete?(false, "请等待代理重启完成。")
            return
        }
        guard !transparentProxyNeedsStop else {
            let message = "请先停止透明抓包，再接管系统代理。"
            systemProxyMessage = message
            onComplete?(false, message)
            return
        }
        guard !systemProxyBusy, !systemProxyActive else {
            onComplete?(systemProxyActive, "")
            return
        }
        guard proxyRunning else {
            let message = "请先启动监听，再接管系统代理。"
            systemProxyMessage = message
            onComplete?(false, message)
            return
        }
        let port = ProxyEngine.shared.port
        systemProxyBusy = true
        systemProxyMessage = "正在接管系统代理…"
        SystemProxyController.shared.enable(port: port, onDisconnect: { [weak self] in
            guard let self, self.systemProxyActive else { return }
            self.systemProxyActive = false
            self.systemProxyMessage = "系统代理服务连接已断开，后台服务会尝试恢复原配置。"
        }) { [weak self] ok, msg in
            guard let self else { return }
            self.systemProxyBusy = false
            self.systemProxyActive = ok
            self.systemProxyServiceInstalled = SystemProxyController.shared.hasInstalledService
            self.systemProxyMessage = ok ? "系统代理已接管（127.0.0.1:\(port)）" : "系统代理未生效：\(msg)"
            onComplete?(ok, msg)
        }
    }

    func uninstallSystemProxyService() {
        guard !systemProxyBusy, !systemProxyActive, !proxyRestarting else { return }
        systemProxyBusy = true
        systemProxyMessage = "正在移除系统代理授权…"
        SystemProxyController.shared.uninstall { [weak self] ok, message in
            guard let self else { return }
            self.systemProxyBusy = false
            self.systemProxyServiceInstalled = SystemProxyController.shared.hasInstalledService
            if ok { self.settings.autoTakeOverSystemProxy = false }
            self.systemProxyMessage = ok ? "系统代理授权已移除。" : "移除系统代理授权失败：\(message)"
        }
    }

    func stopSystemProxy(duringRestart: Bool = false, onComplete: ((Bool) -> Void)? = nil) {
        guard !proxyRestarting || duringRestart else { onComplete?(false); return }
        guard !systemProxyBusy else { onComplete?(false); return }
        systemProxyBusy = true
        systemProxyMessage = "正在关闭系统代理…"
        SystemProxyController.shared.disable { [weak self] ok, msg in
            guard let self else { return }
            self.systemProxyBusy = false
            if ok { self.systemProxyActive = false }
            self.systemProxyMessage = ok ? "系统代理已还原" : "关闭系统代理失败：\(msg)"
            onComplete?(ok)
        }
    }

    func runSimulatorAutomation() {
        if !proxyRunning { startProxy(automaticallyTakeOver: false) }
        guard proxyRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try CertificateAuthority.shared.ensureCA()
                let ca = CertificateAuthority.shared.caCertPath.path
                let message = try DeviceAutomation.setupSimulators(certificatePath: ca)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.systemProxyActive {
                        self.systemProxyMessage = message
                    } else {
                        self.startSystemProxy(onComplete: { success, detail in
                            let next = success ? "系统代理已接管。" : "请手动接管系统代理。\(detail)"
                            self.systemProxyMessage = message + "\n" + next
                        })
                    }
                }
            } catch {
                DispatchQueue.main.async { self?.systemProxyMessage = "模拟器配置失败：\(error.localizedDescription)" }
            }
        }
    }

    func runAndroidEmulatorAutomation() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try CertificateAuthority.shared.ensureCA()
                let ca = CertificateAuthority.shared.caCertPath.path
                let message = try DeviceAutomation.setupAndroidEmulator(certificatePath: ca)
                DispatchQueue.main.async { self?.systemProxyMessage = message }
            } catch {
                DispatchQueue.main.async { self?.systemProxyMessage = "Android 模拟器配置失败：\(error.localizedDescription)" }
            }
        }
    }

    func prepareAndroidUserCertificate() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let data = try CertificateAuthority.shared.caDER()
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pm-android-\(UUID().uuidString).cer")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try data.write(to: temporary)
                let message = try DeviceAutomation.prepareAndroidUserCertificate(certificatePath: temporary.path)
                DispatchQueue.main.async { self?.systemProxyMessage = message }
            } catch {
                DispatchQueue.main.async { self?.systemProxyMessage = "复制证书失败：\(error.localizedDescription)" }
            }
        }
    }

    func installCACertificate() {
        CertInstaller.installSystemWide { [weak self] ok, msg in
            guard let self else { return }
            self.caInstalled = ok
            if ok {
                self.caBannerDismissed = true
                UserDefaults.standard.set(true, forKey: "caBannerDismissed")
            }
            self.systemProxyMessage = ok ? "CA 证书已安装并系统级信任（浏览器刷新即生效）"
                                         : "CA 安装失败：\(msg)"
        }
    }

    func toggleTLSKeyLogging() {
        if tlsKeyLogURL != nil {
            TLSKeyLog.shared.stop()
            tlsKeyLogURL = nil
            return
        }
        let panel = NSSavePanel()
        panel.title = "记录 ProxyMirror TLS 会话密钥"
        panel.message = "密钥可用于解读对应连接的网络数据。记录仅对代理终止的 TLS 握手生效。"
        panel.nameFieldStringValue = "proxymirror-tls.keys"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try TLSKeyLog.shared.start(at: url)
            tlsKeyLogURL = url
        } catch {
            systemProxyMessage = "TLS 密钥日志打开失败：\(error.localizedDescription)"
        }
    }

    var showCABanner: Bool {
        proxyRunning && !caInstalled && !caBannerDismissed
    }

    func dismissCABanner() {
        caBannerDismissed = true
        UserDefaults.standard.set(true, forKey: "caBannerDismissed")
    }

    func revealCAFile() {
        CertInstaller.revealCAFile()
    }

    // MARK: Flow 动作（对齐 Proxyman Flow 菜单交互）

    func copyText(_ text: String) {
        if !CopyPaste.copy(text) {
            systemProxyMessage = "复制失败，请重新选择请求后重试。"
        }
    }

    func copyRequestsAsCurl(_ transactions: [Transaction]) {
        copyText(transactions.map(ExportService.curlCommand).joined(separator: "\n"))
    }

    func copyRequestsUsingDefaultFormat(_ transactions: [Transaction]) {
        guard !transactions.isEmpty else { return }
        let format = settings.defaultCopyFormat
        guard transactions.allSatisfy({ RequestCode.supported(format, for: $0) || (format == .curl && $0.isTunnel) }) else {
            systemProxyMessage = "所选请求无法复制为 \(format.title)。请确认请求捕获完整，或在设置中选择其他默认复制格式。"
            return
        }
        copyText(transactions.map { RequestCode.generate($0, format: format) }.joined(separator: "\n\n"))
    }

    private func withSelected(_ f: @escaping (Transaction) -> Void) {
        guard let tx = activeStore.selectedTransaction else { return }
        f(tx)
        activeStore.update(tx)
    }

    func repeatSelected() {
        activeStore.selectedTransactions.forEach { repeatRequest($0) }
    }

    func repeatRequest(_ tx: Transaction, direct: Bool = false) {
        guard tx.canReplay else { return }
        if !direct && !proxyRunning { startProxy(automaticallyTakeOver: false) }
        if !direct && !proxyRunning { return }
        RepeatService.resend(tx, proxyPort: direct ? nil : ProxyEngine.shared.port) { [store] result in
            if direct || result.state == .failed { store.add(result) }
        }
    }

    func highlightSelected(_ name: String?) {
        let targets = activeStore.selectedTransactions
        for tx in targets { tx.highlightName = name }
        activeStore.update(targets)
    }

    func strikethroughSelected() {
        withSelected { $0.strikethrough.toggle() }
    }

    func unstrikethroughSelected() {
        withSelected { $0.strikethrough = false }
    }

    func deleteSelected() {
        activeStore.remove(activeStore.selectedIDs)
    }

    func openTool(_ kind: ToolKind, transaction: Transaction? = nil) {
        toolTransaction = transaction
        activeTool = kind
    }

    func dismissTool() {
        if activeTool == nil { toolTransaction = nil }
    }

    func openComment(_ targets: [Transaction]? = nil) {
        commentTargets = targets ?? activeStore.selectedTransactions
        showCommentSheet = !commentTargets.isEmpty
    }

    func dismissComments() {
        if !showCommentSheet { commentTargets.removeAll() }
    }

    func dismissComparison() {
        if !showDiff { diffTargets.removeAll() }
    }

    func toggleDiffCandidate(_ tx: Transaction) {
        if let index = diffPool.firstIndex(where: { $0 === tx }) {
            diffPool.remove(at: index)
        } else if diffPool.count >= 100 {
            systemProxyMessage = "对比池最多保留 100 条请求，请先移除部分记录。"
        } else {
            diffPool.append(tx)
        }
    }

    func clearDiffPool() { diffPool.removeAll() }
    func removeFromDiffPool(_ id: UUID) { diffPool.removeAll { $0.id == id } }
    func addToDiffPool(_ transactions: [Transaction]) {
        for tx in transactions where !diffPool.contains(where: { $0.id == tx.id }) {
            guard diffPool.count < 100 else {
                systemProxyMessage = "对比池最多保留 100 条请求，请先移除部分记录。"
                return
            }
            diffPool.append(tx)
        }
    }

    func openComparison(usePool: Bool = false) {
        let candidates = usePool ? diffPool : activeStore.selectedTransactions
        guard candidates.count == 2 else { return }
        diffTargets = candidates
        addToDiffPool(candidates)
        showDiff = true
    }

    private var sessionImports: [UUID: UUID] = [:]

    func saveSession(onlySelection: Bool = false) {
        let workspace = activeStore
        guard let url = SessionFile.selectSaveFile() else { return }
        let snapshot = workspace.session(onlySelection: onlySelection, pinned: pinnedDomains)
        let redact = settings.redactSensitiveHeaders
        SessionFile.fileQueue.async { [weak self] in
            do { try snapshot.write(to: url, redactSensitiveHeaders: redact) }
            catch { DispatchQueue.main.async { [weak self] in self?.systemProxyMessage = error.localizedDescription } }
        }
    }

    func importCharlesSession() {
        guard let url = SessionFile.selectFile(extensions: CharlesImport.sessionExtensions) else { return }
        openSession(url, charles: true)
    }

    func openSession(_ url: URL? = nil, charles: Bool = false) {
        guard let url = url ?? SessionFile.selectFile() else { return }
        let isCharles = charles || CharlesImport.sessionExtensions.contains(url.pathExtension.lowercased())
        let workspace = activeStore
        let workspaceID = workspace.id
        let importID = UUID()
        sessionImports[workspaceID] = importID
        SessionFile.fileQueue.async { [weak self, weak workspace] in
            let result = Result { () throws -> (records: [Transaction], pins: [String], selection: [UUID], skipped: Int) in
                if isCharles {
                    let session = try CharlesImport.readSession(url)
                    return (session.records, [], [], session.skipped)
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                if url.pathExtension.lowercased() == "har" {
                    return (try SessionFile.importHAR(data), [], [], 0)
                }
                let session = try SessionFile.decode(data)
                return (session.records.map { $0.transaction() }, session.pinnedDomains, session.selected, 0)
            }
            DispatchQueue.main.async { [weak self, weak workspace] in
                guard let self, self.sessionImports[workspaceID] == importID else { return }
                self.sessionImports[workspaceID] = nil
                guard let workspace else { return }
                switch result {
                case .success(let archive):
                    if isCharles {
                        let preview = NSAlert()
                        preview.messageText = "导入 Charles 会话"
                        preview.informativeText = "\(url.lastPathComponent)\n可导入 \(archive.records.count) 条事务 · 跳过 \(archive.skipped) 条"
                        if archive.records.isEmpty {
                            preview.addButton(withTitle: "好")
                            preview.runModal()
                            return
                        }
                        preview.addButton(withTitle: "导入")
                        preview.addButton(withTitle: "取消")
                        guard preview.runModal() == .alertFirstButtonReturn else { return }
                    }
                    workspace.loadArchive(archive.records, name: url.deletingPathExtension().lastPathComponent,
                                          pins: archive.pins, selection: archive.selection)
                    NSDocumentController.shared.noteNewRecentDocumentURL(url)
                case .failure(let error):
                    self.systemProxyMessage = "打开会话失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// Edit URL ⌘K / Edit and Repeat ⇧⌘R：打开预填的 Compose 编辑器
    func editSelected(sendAndRepeat: Bool = false) {
        guard let transaction = activeStore.selectedTransaction, transaction.canReplay else { return }
        openTool(.compose, transaction: transaction)
    }

    /// Enable SSL Proxying for This Domain：把选中请求的主机加入 SSL Proxying List
    func enableSSLProxyingForSelected() {
        guard let tx = activeStore.selectedTransaction else { return }
        enableSSLProxying(for: tx)
    }

    func enableSSLProxying(for tx: Transaction) {
        let pattern = RulesSnapshot.sslHostPattern(tx.host)
        let rules = RulesStore.shared
        var entries = rules.sslProxyingList
        if let index = entries.firstIndex(where: { RulesSnapshot.sslHostPattern($0.pattern) == pattern }) {
            entries[index].enabled = true
        } else {
            entries.append(ProxyRule(pattern: pattern))
        }
        var backup = rules.backup()
        backup.sslProxyingList = entries
        do { try rules.install(backup) }
        catch { systemProxyMessage = "SSL 规则未保存：\(error.localizedDescription)" }
    }
}

extension Notification.Name {
    static let focusTrafficFilter = Notification.Name("ProxyMirror.focusTrafficFilter")
    static let focusSourceFilter = Notification.Name("ProxyMirror.focusSourceFilter")
}
