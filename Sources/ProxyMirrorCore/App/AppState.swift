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
    private let engineFactory: () -> ProxyEngine
    private let usesSharedRuntime: Bool
    private let ownsEngine: Bool
    private let temporaryCertificateDirectory: URL?
    private let customCertificateProvider: (@Sendable (String) -> CertificateAuthority.CustomChain?)?
    private var resolvedEngine: ProxyEngine?
    var hasResolvedEngine: Bool { resolvedEngine != nil }
    private var resolvedReverseProxy: ReverseProxyController?
    private var reverseProxy: ReverseProxyController {
        if let resolvedReverseProxy { return resolvedReverseProxy }
        let controller = usesSharedRuntime ? ReverseProxyController.shared : ReverseProxyController()
        resolvedReverseProxy = controller
        return controller
    }

    /// Creating a preview/test state does not resolve or reconfigure global services.
    var engine: ProxyEngine {
        if let resolvedEngine { return resolvedEngine }
        let created = engineFactory()
        resolvedEngine = created
        created.sink = self
        return created
    }
    var certificateAuthority: CertificateAuthority { engine.certificateAuthority }
    var runtimeContext: ProxyRuntimeContext { ProxyRuntimeContext(engine: engine, settings: settings) }
    /// A pending preference must never be advertised as an already bound endpoint.
    var listenerPort: UInt16 { resolvedEngine.flatMap { $0.isRunning ? $0.port : nil } ?? settings.port }
    @Published private(set) var tabs: [TrafficStore] = []
    @Published private(set) var activeTabIndex = 0
    @Published private(set) var splitStore: TrafficStore?
    @Published private(set) var splitFocused = false
    var activeTab: TrafficStore { tabs[safe: activeTabIndex] ?? store }
    var activeStore: TrafficStore { splitFocused ? splitStore ?? activeTab : activeTab }

    @Published var proxyRunning = false
    @Published var recordingEnabled = true {
        didSet { resolvedEngine?.recordingEnabled = recordingEnabled }
    }
    @Published var proxyStartError: String?
    @Published var settingsTarget: SettingsSearchTarget?
    @Published private(set) var bridgePairingCode: String?
    @Published var showBridgePairing = false
    private var bridgeListener: BridgeListener?
    private var bridgeSessionID: UUID?
    @Published var systemProxyActive = false
    @Published private(set) var systemProxyServiceInstalled = false
    @Published private(set) var systemProxyBusy = false
    @Published private(set) var proxyRestarting = false
    @Published var systemProxyMessage: String?
    private let transparentProxy = TransparentProxyController()
    private var transparentProxyChanges: AnyCancellable?
    @Published private(set) var transparentProxyState: TransparentProxyController.State = .idle
    var transparentProxyNeedsStop: Bool { transparentProxy.needsStop }
    var transparentProxyMenuTitle: String {
        guard TransparentProxyController.isAvailable else { return Strings.Errors.appStateTransparentCaptureUnavailable }
        switch transparentProxyState {
        case .activating: return Strings.Errors.appStateCancelTransparentCaptureActivation
        case .awaitingApproval: return Strings.Errors.appStateCancelTransparentCaptureAwaitingApproval
        case .connecting: return Strings.Errors.appStateCancelTransparentProxyConnection
        case .running: return Strings.Errors.appStateStopTransparentCapture
        case .stopping: return Strings.Errors.appStateStoppingTransparentCapture
        case .failed where transparentProxyNeedsStop: return Strings.Errors.appStateRetryStoppingTransparentCapture
        default: return Strings.Errors.appStateStartTransparentCapture
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
    private var settingsChanges: AnyCancellable?
    private var certificateChanges: AnyCancellable?
    private var certificateStatusTask: Task<Void, Never>?
    private var presentedSavedError: String?
    @Published var dockRight = UserDefaults.standard.bool(forKey: "ui.dockRight") {
        didSet { UserDefaults.standard.set(dockRight, forKey: "ui.dockRight") }
    }
    @Published var certificateGuide: String?
    @Published var showResetCA = false
    @Published var showSidebar = true
    @Published var pinnedDomains: [String] = [] {
        didSet { UserDefaults.standard.set(pinnedDomains, forKey: "pinnedDomains") }
    }

    init(settings: AppSettings = .shared, engine: ProxyEngine? = nil,
         certificateAuthority: CertificateAuthority? = nil,
         certificateProvider: (@Sendable (String) -> CertificateAuthority.CustomChain?)? = nil,
         launchServices: Bool = true) {
        self.settings = settings
        usesSharedRuntime = launchServices && engine == nil && certificateAuthority == nil
        ownsEngine = engine == nil && !usesSharedRuntime
        if let engine {
            temporaryCertificateDirectory = nil
            precondition(certificateAuthority == nil || engine.certificateAuthority === certificateAuthority,
                         "AppState and its proxy engine must use the same certificate authority")
            engineFactory = { engine }
        } else if usesSharedRuntime {
            temporaryCertificateDirectory = nil
            engineFactory = { ProxyEngine.shared }
        } else {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ProxyMirror-Isolated-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("CA", isDirectory: true)
            temporaryCertificateDirectory = certificateAuthority == nil ? directory.deletingLastPathComponent() : nil
            engineFactory = { ProxyEngine(certificateAuthority: certificateAuthority ?? CertificateAuthority(storageDirectory: directory)) }
        }
        if let certificateProvider {
            customCertificateProvider = certificateProvider
        } else if usesSharedRuntime {
            customCertificateProvider = { host in CustomCertificateStore.shared.chain(forHost: host) }
        } else {
            customCertificateProvider = nil
        }
        recordingEnabled = settings.autoStartRecording
        tabs = [store]
        observeActiveWorkspace()
        store.maxTransactions = settings.maxTransactions
        store.followLatest = settings.followLatest
        settingsChanges = settings.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            self?.objectWillChange.send()
        }
        transparentProxyChanges = transparentProxy.$state.dropFirst().sink { [weak self] state in
            guard let self else { return }
            self.transparentProxyState = state
            switch state {
            case .awaitingApproval:
                self.systemProxyMessage = Strings.Errors.appStateAllowTheProxymirrorNetworkExtensionInMacosSystem
            case .idle, .failed:
                if !self.transparentProxyNeedsStop { self.resolvedEngine?.stopTransparentIngress() }
                if case .failed(let message) = state { self.systemProxyMessage = message }
            default:
                break
            }
        }
        guard launchServices, ProcessInfo.processInfo.environment["PM_SETTINGS_SNAPSHOT"] == nil else { return }
        applyRuntimeSettings()
        systemProxyServiceInstalled = SystemProxyController.shared.hasInstalledService
        pinnedDomains = UserDefaults.standard.stringArray(forKey: "pinnedDomains") ?? []
        certificateChanges = NotificationCenter.default.publisher(for: .proxyMirrorCertificatesChanged)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshCertificateStatus() }
        refreshCertificateStatus()
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

    deinit {
        guard ownsEngine, let engine = resolvedEngine else { return }
        let controller = resolvedReverseProxy
        let directory = temporaryCertificateDirectory
        Task { @MainActor in
            controller?.stop()
            engine.stop()
            engine.group.shutdownGracefully { _ in
                if let directory { try? FileManager.default.removeItem(at: directory) }
            }
        }
    }

    private func observeActiveWorkspace() {
        store.setWorkspaceVisible(store === activeTab)
        for tab in tabs { tab.setWorkspaceVisible(tab === activeTab) }
        storeChanges = activeStore.objectWillChange.sink { [weak self] in
            guard let self else { return }
            if self.store.savedError == nil { self.presentedSavedError = nil }
            self.objectWillChange.send()
        }
    }

    func markSavedErrorPresented() {
        presentedSavedError = store.savedError
    }

    func shouldPresentSavedError(_ message: String?) -> Bool {
        guard let message else { presentedSavedError = nil; return false }
        // Every main window observes the same data. Keep the acknowledgement
        // until recovery so a second window cannot repeat the modal quit alert.
        if presentedSavedError == message { return false }
        return true
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
            try certificateAuthority.ensureCA()
            UpstreamTrust.prewarm()
            try engine.start(port: settings.port, lan: settings.lanAccess)
            reverseProxy.start(engine: engine)
            proxyRunning = true
            DiagnosticLog.record("listener started port=\(settings.port) lan=\(settings.lanEnabled) http2=\(settings.http2Enabled) mitm=\(settings.mitmEnabled)")
            proxyStartError = nil
            if automaticallyTakeOver { takeOverSystemProxyIfConfigured() }
        } catch {
            proxyStartError = Strings.Errors.appStateUnableToStartCheckThePortAndLan(LocalizedErrorPresentation.message(for: error))
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
        reverseProxy.stop()
        engine.stop()
        stopBridgeCapture()
        proxyRunning = false
        DiagnosticLog.record("listener stopped")
    }

    func toggleTransparentProxy() {
        guard !proxyRestarting else { return }
        guard TransparentProxyController.isAvailable else {
            systemProxyMessage = Strings.Errors.appStateThisBuildHasNoTransparentProxyExtensionUse
            return
        }
        if transparentProxyNeedsStop {
            Task { _ = await stopTransparentProxy() }
            return
        }
        guard !systemProxyBusy else { return }
        Task {
            guard !transparentProxyNeedsStop, !systemProxyBusy, !proxyRestarting else { return }
            if systemProxyActive {
                let restored = await withCheckedContinuation { continuation in
                    stopSystemProxy { continuation.resume(returning: $0) }
                }
                guard restored, !systemProxyActive else { return }
            }
            if !proxyRunning { startProxy(automaticallyTakeOver: false) }
            guard proxyRunning else { return }
            _ = await startTransparentProxy()
        }
    }

    private func startTransparentProxy() async -> Bool {
        do {
            let ingress = try engine.startTransparentIngress()
            try await transparentProxy.start(port: ingress.port, token: ingress.token)
            return true
        } catch is CancellationError {
            if !transparentProxyNeedsStop { engine.stopTransparentIngress() }
        } catch {
            if !transparentProxyNeedsStop { engine.stopTransparentIngress() }
            systemProxyMessage = LocalizedErrorPresentation.message(for: error)
        }
        return false
    }

    func stopTransparentProxy() async -> Bool {
        do {
            try await transparentProxy.stop()
            return true
        } catch {
            systemProxyMessage = LocalizedErrorPresentation.message(for: error)
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
            stopSystemProxy(restorePrevious: settings.restorePreviousSystemProxy, onComplete: completion)
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
        engine.mitmExcludedHosts = hosts
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
        engine.recordingEnabled = recordingEnabled
        engine.mitmEnabled = settings.mitmEnabled
        engine.http2Enabled = settings.http2Enabled
        engine.mitmExcludedHosts = settings.mitmExcludedHosts
        if let customCertificateProvider {
            certificateAuthority.setCustomCertificateProvider(customCertificateProvider)
        }
        engine.captureLimit = settings.maxBodyMB * 1024 * 1024
        store.maxTransactions = settings.maxTransactions
        activeStore.followLatest = settings.followLatest
    }

    /// 普通应用只在监听端点变化时重绑，避免 SSL 开关等操作中断现有连接。
    func applyAndRestartIfNeeded() {
        applyRuntimeSettings()
        guard !systemProxyBusy, !proxyRestarting else { return }
        let engine = self.engine
        if proxyRunning, settings.port != engine.port || settings.lanAccess != engine.lanAccess {
            let oldPort = engine.port
            let oldLAN = engine.lanAccess
            guard !systemProxyActive, !transparentProxyNeedsStop else {
                settings.port = oldPort
                restoreLAN(oldLAN)
                systemProxyMessage = transparentProxyNeedsStop
                    ? Strings.Errors.appStateStopTransparentCaptureBeforeChangingTheListenAddress
                    : Strings.Errors.appStateRestoreTheSystemProxyBeforeChangingTheListen
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
            systemProxyMessage = Strings.Errors.appStateSettingsAppliedTheListenerIsNotRunning
            return
        }
        let oldPort = engine.port
        let oldLAN = engine.lanAccess
        let resumeSystemProxy = systemProxyActive
        let resumeTransparentProxy = transparentProxyNeedsStop
        proxyRestarting = true
        systemProxyMessage = Strings.Errors.appStateApplyingSettingsAndRestartingTheProxy
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
                systemProxyMessage = Strings.Errors.appStateSettingsAppliedTheProxyHasRestarted
            }
        }
    }

    private func restartListener(oldPort: UInt16, oldLAN: LANAccess?) {
        reverseProxy.stop()
        engine.stop()
        stopBridgeCapture()
        proxyRunning = false
        startProxy(automaticallyTakeOver: false, duringRestart: true)
        if !proxyRunning {
            let error = proxyStartError
            settings.port = oldPort
            restoreLAN(oldLAN)
            startProxy(automaticallyTakeOver: false, duringRestart: true)
            if proxyRunning { proxyStartError = error.map { $0 + Strings.Errors.appStateRestoredThePreviousListenerPort(Int(oldPort)) } }
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
            systemProxyMessage = Strings.Errors.appStateNewConnectionsFromWillUsePassthrough(String(name))
        } catch {
            systemProxyMessage = Strings.Errors.appStateUnableToSaveThePassthroughRule(LocalizedErrorPresentation.message(for: error))
        }
    }

    func showOrStartBridgeCapture() {
        if bridgeListener != nil {
            if bridgePairingCode != nil { showBridgePairing = true }
            return
        }
        guard proxyRunning, let lan = engine.lanAccess else {
            systemProxyMessage = Strings.Errors.appStateEnableLanAccessInSettingsGeneralConfigureThe
            return
        }
        do {
            let sessionID = UUID()
            guard let policy = lan.peerPolicy else { throw ProxyError.invalidLANAccess }
            let receiver = try BridgeListener(address: lan.address, policy: policy) { [weak self] capture, address in
                guard let self, self.bridgeSessionID == sessionID, self.recordingEnabled,
                      let tx = Transaction(bridge: capture, deviceAddress: address,
                                           limit: engine.captureLimit, sink: self) else { return }
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
                        self.systemProxyMessage = Strings.Errors.appStateUnableToStartTheInAppCaptureListener(LocalizedErrorPresentation.message(for: error))
                    default: break
                    }
                }
            }
        } catch {
            systemProxyMessage = Strings.Errors.appStateUnableToStartTheInAppCaptureListener(LocalizedErrorPresentation.message(for: error))
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
                    tx.clientName = Strings.Errors.appStateDevice(String(address))
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
        onMain { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.store.recordBodyBytes(tx)
                self.activeTab.noteBodyCaptureUpdate(tx)
                self.splitStore?.noteBodyCaptureUpdate(tx)
            }
        }
    }

    // MARK: 动作

    func clearTraffic() {
        if !activeStore.isBrowsingSavedRequests && activeStore.filterMode != .archive {
            engine.clearBreakpointSession()
            BreakpointManager.shared.discardAll()
        }
        activeStore.clear()
    }

    func startSystemProxy(duringRestart: Bool = false, onComplete: ((Bool, String) -> Void)? = nil) {
        guard !proxyRestarting || duringRestart else {
            onComplete?(false, Strings.Errors.appStateWaitForTheProxyRestartToFinish)
            return
        }
        guard !transparentProxyNeedsStop else {
            let message = Strings.Errors.appStateStopTransparentCaptureBeforeEnablingTheSystemProxy
            systemProxyMessage = message
            onComplete?(false, message)
            return
        }
        guard !systemProxyBusy, !systemProxyActive else {
            onComplete?(systemProxyActive, "")
            return
        }
        guard proxyRunning else {
            let message = Strings.Errors.appStateStartListeningBeforeEnablingTheSystemProxy
            systemProxyMessage = message
            onComplete?(false, message)
            return
        }
        let port = engine.port
        systemProxyBusy = true
        systemProxyMessage = Strings.Errors.appStateEnablingTheSystemProxy
        SystemProxyController.shared.enable(port: port, onDisconnect: { [weak self] in
            guard let self, self.systemProxyActive else { return }
            self.systemProxyActive = false
            self.systemProxyMessage = Strings.Errors.appStateTheSystemProxyServiceDisconnectedTheBackgroundService
        }) { [weak self] ok, msg in
            guard let self else { return }
            self.systemProxyBusy = false
            self.systemProxyActive = ok
            self.systemProxyServiceInstalled = SystemProxyController.shared.hasInstalledService
            self.systemProxyMessage = ok ? Strings.Errors.appStateSystemProxyEnabled127001(Int(port)) : Strings.Errors.appStateUnableToEnableTheSystemProxy(String(msg))
            onComplete?(ok, msg)
        }
    }

    func uninstallSystemProxyService() {
        guard !systemProxyBusy, !systemProxyActive, !proxyRestarting else { return }
        systemProxyBusy = true
        systemProxyMessage = Strings.Errors.appStateRemovingSystemProxyAuthorization
        SystemProxyController.shared.uninstall { [weak self] ok, message in
            guard let self else { return }
            self.systemProxyBusy = false
            self.systemProxyServiceInstalled = SystemProxyController.shared.hasInstalledService
            if ok { self.settings.autoTakeOverSystemProxy = false }
            self.systemProxyMessage = ok ? Strings.Errors.appStateSystemProxyAuthorizationRemoved : Strings.Errors.appStateUnableToRemoveSystemProxyAuthorization(String(message))
        }
    }

    func stopSystemProxy(duringRestart: Bool = false, restorePrevious: Bool = true,
                         onComplete: ((Bool) -> Void)? = nil) {
        guard !proxyRestarting || duringRestart else { onComplete?(false); return }
        guard !systemProxyBusy else { onComplete?(false); return }
        systemProxyBusy = true
        systemProxyMessage = Strings.Errors.appStateDisablingTheSystemProxy
        SystemProxyController.shared.disable(restorePrevious: restorePrevious) { [weak self] ok, msg in
            guard let self else { return }
            self.systemProxyBusy = false
            if ok { self.systemProxyActive = false }
            self.systemProxyMessage = ok ? Strings.Errors.appStateSystemProxyRestored : Strings.Errors.appStateUnableToDisableTheSystemProxy(String(msg))
            onComplete?(ok)
        }
    }

    func runSimulatorAutomation() {
        if !proxyRunning { startProxy(automaticallyTakeOver: false) }
        guard proxyRunning else { return }
        let authority = certificateAuthority
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try authority.ensureCA()
                let ca = authority.caCertPath.path
                let message = try DeviceAutomation.setupSimulators(certificatePath: ca)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.systemProxyActive {
                        self.systemProxyMessage = message
                    } else {
                        self.startSystemProxy(onComplete: { success, detail in
                            let next = success ? Strings.Errors.appStateSystemProxyEnabled : Strings.Errors.appStateEnableTheSystemProxyManually(String(detail))
                            self.systemProxyMessage = message + "\n" + next
                        })
                    }
                }
            } catch {
                DispatchQueue.main.async { self?.systemProxyMessage = Strings.Errors.appStateSimulatorSetupFailed(LocalizedErrorPresentation.message(for: error)) }
            }
        }
    }

    func runAndroidEmulatorAutomation() {
        let authority = certificateAuthority
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try authority.ensureCA()
                let ca = authority.caCertPath.path
                let message = try DeviceAutomation.setupAndroidEmulator(certificatePath: ca)
                DispatchQueue.main.async { self?.systemProxyMessage = message }
            } catch {
                DispatchQueue.main.async { self?.systemProxyMessage = Strings.Errors.appStateAndroidEmulatorSetupFailed(LocalizedErrorPresentation.message(for: error)) }
            }
        }
    }

    func prepareAndroidUserCertificate() {
        let authority = certificateAuthority
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let data = try authority.caDER()
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pm-android-\(UUID().uuidString).cer")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try data.write(to: temporary)
                let message = try DeviceAutomation.prepareAndroidUserCertificate(certificatePath: temporary.path)
                DispatchQueue.main.async { self?.systemProxyMessage = message }
            } catch {
                DispatchQueue.main.async { self?.systemProxyMessage = Strings.Errors.appStateUnableToCopyTheCertificate(LocalizedErrorPresentation.message(for: error)) }
            }
        }
    }

    func installCACertificate() {
        CertInstaller.installSystemWide(authority: certificateAuthority) { [weak self] ok, msg in
            guard let self else { return }
            guard ok else {
                self.systemProxyMessage = Strings.Errors.appStateCaInstallationFailed(String(msg))
                self.refreshCertificateStatus()
                return
            }
            self.refreshCertificateStatus { [weak self] trusted in
                guard let self else { return }
                self.caBannerDismissed = trusted
                UserDefaults.standard.set(trusted, forKey: "caBannerDismissed")
                self.systemProxyMessage = trusted ? Strings.Errors.appStateTheCaIsInstalledAndTrustedSystemWide
                    : Strings.Errors.appStateTheCertificateWasImportedButTheCurrentCa
            }
        }
    }

    func refreshCertificateStatus(completion: ((Bool) -> Void)? = nil) {
        certificateStatusTask?.cancel()
        let authority = certificateAuthority
        certificateStatusTask = Task { [weak self] in
            let status = await Task.detached(priority: .utility) { CertInstaller.certificateStatus(authority: authority) }.value
            guard !Task.isCancelled, let self else { return }
            self.caInstalled = status.trusted
            completion?(status.trusted)
        }
    }

    func toggleTLSKeyLogging() {
        if tlsKeyLogURL != nil {
            TLSKeyLog.shared.stop()
            tlsKeyLogURL = nil
            return
        }
        let panel = NSSavePanel()
        panel.title = Strings.Errors.appStateRecordProxymirrorTlsSessionKeys
        panel.message = Strings.Errors.appStateTheKeysCanDecryptNetworkDataForCorresponding
        panel.nameFieldStringValue = "proxymirror-tls.keys"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try TLSKeyLog.shared.start(at: url)
            tlsKeyLogURL = url
        } catch {
            systemProxyMessage = Strings.Errors.appStateUnableToOpenTheTlsKeyLog(LocalizedErrorPresentation.message(for: error))
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
        CertInstaller.revealCAFile(authority: certificateAuthority)
    }

    // MARK: Flow 动作（对齐 Proxyman Flow 菜单交互）

    func copyText(_ text: String) {
        if !CopyPaste.copy(text) {
            systemProxyMessage = Strings.Errors.appStateUnableToCopySelectTheRequestsAgainAnd
        }
    }

    func copyRequestsAsCurl(_ transactions: [Transaction]) {
        let runtime = runtimeContext
        copyText(transactions.map { ExportService.curlCommand($0, runtime: runtime) }.joined(separator: "\n"))
    }

    func copyRequestsUsingDefaultFormat(_ transactions: [Transaction]) {
        guard !transactions.isEmpty else { return }
        let format = settings.defaultCopyFormat
        guard transactions.allSatisfy({ RequestCode.supported(format, for: $0) || (format == .curl && $0.isTunnel) }) else {
            systemProxyMessage = Strings.Errors.appStateTheSelectedRequestsCannotBeCopiedAsCheck(String(format.title))
            return
        }
        let runtime = runtimeContext
        copyText(transactions.map { RequestCode.generate($0, format: format, runtime: runtime) }.joined(separator: "\n\n"))
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
        RepeatService.resend(tx, runtime: runtimeContext, proxyPort: direct ? nil : engine.port) { [store] result in
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
            systemProxyMessage = Strings.Errors.appStateTheComparisonPoolHoldsUpTo100Requests
        } else {
            diffPool.append(tx)
        }
    }

    func clearDiffPool() { diffPool.removeAll() }
    func removeFromDiffPool(_ id: UUID) { diffPool.removeAll { $0.id == id } }
    func addToDiffPool(_ transactions: [Transaction]) {
        for tx in transactions where !diffPool.contains(where: { $0.id == tx.id }) {
            guard diffPool.count < 100 else {
                systemProxyMessage = Strings.Errors.appStateTheComparisonPoolHoldsUpTo100Requests
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
            catch { DispatchQueue.main.async { [weak self] in self?.systemProxyMessage = LocalizedErrorPresentation.message(for: error) } }
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
                        preview.messageText = Strings.Errors.appStateImportCharlesSession
                        preview.informativeText = Strings.Errors.appStateTransactionsCanBeImportedSkipped(String(url.lastPathComponent), Int(archive.records.count), Int(archive.skipped))
                        if archive.records.isEmpty {
                            preview.addButton(withTitle: Strings.Errors.appStateOk)
                            preview.runModal()
                            return
                        }
                        preview.addButton(withTitle: Strings.Errors.appStateImport)
                        preview.addButton(withTitle: Strings.Errors.appStateCancel)
                        guard preview.runModal() == .alertFirstButtonReturn else { return }
                    }
                    workspace.loadArchive(archive.records, name: url.deletingPathExtension().lastPathComponent,
                                          pins: archive.pins, selection: archive.selection)
                    NSDocumentController.shared.noteNewRecentDocumentURL(url)
                case .failure(let error):
                    self.systemProxyMessage = Strings.Errors.appStateUnableToOpenTheSession(LocalizedErrorPresentation.message(for: error))
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
        catch { systemProxyMessage = Strings.Errors.appStateTheSslRuleWasNotSaved(LocalizedErrorPresentation.message(for: error)) }
    }
}

extension Notification.Name {
    static let focusTrafficFilter = Notification.Name("ProxyMirror.focusTrafficFilter")
    static let focusSourceFilter = Notification.Name("ProxyMirror.focusSourceFilter")
}
