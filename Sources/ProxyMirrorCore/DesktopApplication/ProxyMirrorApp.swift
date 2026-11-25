import SwiftUI

@MainActor
struct ProxyMirrorMainApp: App {
    @NSApplicationDelegateAdaptor(ProxyMirrorLifecycle.self) private var lifecycle
    @StateObject private var appState: AppState
    @AppStorage private var appearance: ProxyMirrorAppearance
    @AppStorage private var showMenuBarIcon: Bool
    @AppStorage("ui.proxymanCompatibleShortcuts") private var compatibleShortcuts = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.self) private var environment
    @FocusedValue(\.trafficCommandsActive) private var trafficCommandsActive

    init() {
        // 必须先完成版本重置，再初始化会读取设置、规则与 Saved 的单例。
        do {
            try LocalizationStorage.prepareForApplicationLaunch()
        } catch {
            let alert = NSAlert()
            alert.messageText = Strings.Menus.storageInitializationFailed
            alert.informativeText = LocalizedErrorPresentation.message(for: error)
            alert.addButton(withTitle: Strings.Menus.ok)
            alert.runModal()
            exit(EXIT_FAILURE)
        }
        // 语言上下文在首次访问时冻结；修改偏好只影响下次启动。
        if let issue = L10n.startupIssue {
            let alert = NSAlert()
            alert.messageText = Strings.Menus.languageResourcesUnavailable
            alert.informativeText = issue
            alert.addButton(withTitle: Strings.Menus.ok)
            alert.runModal()
            exit(EXIT_FAILURE)
        }
        _ = L10n.effectiveLanguage
        _appearance = AppStorage(wrappedValue: .system, ProxyMirrorAppearance.key)
        _showMenuBarIcon = AppStorage(wrappedValue: false, "ui.showMenuBarIcon")
        _appState = StateObject(wrappedValue: AppState.shared)
    }

    private var appLocale: Locale { L10n.locale }
    private var flowCommandsAvailable: Bool {
        trafficCommandsActive == true && NSApp.keyWindow?.attachedSheet == nil && NSApp.keyWindow?.sheetParent == nil
            && appState.activeTool == nil && (NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable != true
    }
    private var exportTargets: [Transaction] {
        let store = appState.activeStore
        return store.selectedIDs.isEmpty ? store.visible : store.selectedTransactions
    }

    private var appColorScheme: ColorScheme? {
        if ProcessInfo.processInfo.environment["PM_SETTINGS_SNAPSHOT"] != nil {
            switch ProcessInfo.processInfo.environment["PM_SETTINGS_APPEARANCE"] {
            case "dark": return .dark
            case "light": return .light
            default: break
            }
        }
        return appearance.colorScheme
    }

    var body: some Scene {
        WindowGroup("ProxyMirror") {
            MainWindow()
                .environmentObject(appState)
                .modifier(BreakpointOpening())
                .modifier(PreferencesSnapshotLauncher())
                .preferredColorScheme(appColorScheme)
                .environment(\.locale, appLocale)
                .onOpenURL { appState.openSession($0) }
                .frame(minWidth: 980, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands { proxyCommands }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .preferredColorScheme(appColorScheme)
                .environment(\.locale, appLocale)
        }

        Window(Strings.Menus.breakpoints, id: "breakpoints") {
            BreakpointWindow()
                .preferredColorScheme(appColorScheme)
                .environment(\.locale, appLocale)
        }
        .defaultSize(width: 920, height: 560)

        Window(Strings.Menus.scripting, id: "scripting") {
            ScriptingWindow()
                .preferredColorScheme(appColorScheme)
                .environment(\.locale, appLocale)
        }
        .defaultSize(width: 1020, height: 610)

        setupScenes
        toolScenes

        MenuBarExtra("ProxyMirror", systemImage: "network", isInserted: Binding(
            get: { showMenuBarIcon },
            set: { value in
                // MenuBarExtra may write its current value during scene updates.
                // Avoid notifying AppStorage again and rebuilding the same scene.
                guard showMenuBarIcon != value else { return }
                showMenuBarIcon = value
            })) {
            Button((appState.proxyRunning ? Strings.Menus.stopListening : Strings.Menus.startListening), action: appState.toggleProxy)
            Button((appState.recordingEnabled ? Strings.Menus.pauseRecording : Strings.Menus.resumeRecording), action: appState.toggleRecording)
            Divider()
            Text("127.0.0.1:\(appState.listenerPort)")
            Button(Strings.Menus.showProxymirror) { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
            Button(Strings.Menus.quit) { NSApp.terminate(nil) }
        }

        // 双击/独立详情窗口
        WindowGroup(Strings.Menus.requestDetail, id: "request-detail", for: String.self) { $id in
            DetachedDetailView(txID: id)
                .environmentObject(appState)
                .preferredColorScheme(appColorScheme)
                .environment(\.locale, appLocale)
        }
        .windowResizability(.contentMinSize)
    }

    @SceneBuilder
    private var setupScenes: some Scene {
        WindowGroup(Strings.Menus.rules, id: "rule-window", for: String.self) { $route in
            let parts = (route ?? ToolKind.mapLocal.rawValue).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            RuleListWindow(kind: ToolKind(rawValue: String(parts[0])) ?? .mapLocal,
                           initialPattern: parts.count > 1 ? String(parts[1]) : "")
                .environmentObject(appState)
                .preferredColorScheme(appColorScheme)
                .environment(\.locale, appLocale)
        }.defaultSize(width: 860, height: 560)

        WindowGroup(Strings.Menus.setup, id: "setup-guide", for: String.self) { $platform in
            SetupGuideWindow(platform: platform ?? "macOS")
                .environmentObject(appState)
                .preferredColorScheme(appColorScheme)
                .environment(\.locale, appLocale)
        }.defaultSize(width: 760, height: 680)

        Window(Strings.Menus.customCertificates, id: "certificate-manager") {
            CertificateManagerView().environmentObject(appState)
                .preferredColorScheme(appColorScheme).environment(\.locale, appLocale)
        }.defaultSize(width: 700, height: 498)

        Window(Strings.Menus.networkConditions, id: "network-conditions") {
            LatencyConditionsView().environmentObject(appState)
                .preferredColorScheme(appColorScheme).environment(\.locale, appLocale)
        }.defaultSize(width: 886, height: 640)

    }

    @SceneBuilder
    private var toolScenes: some Scene {
        Window(Strings.Menus.trafficComparison, id: "traffic-diff") {
            TrafficDiffWorkspaceView(appState: appState)
                .preferredColorScheme(appColorScheme)
                .environment(\.locale, appLocale)
        }.defaultSize(width: 1100, height: 680)

        Window(Strings.Menus.trafficSummary, id: "flow-summary") {
            FlowSummaryView(store: appState.activeStore)
                .preferredColorScheme(appColorScheme)
                .environment(\.locale, appLocale)
        }.defaultSize(width: 760, height: 650)

        Window(Strings.Menus.customPreviewers, id: "custom-previewers") {
            CustomPreviewerManagerView().preferredColorScheme(appColorScheme)
                .environment(\.locale, appLocale)
        }.defaultSize(width: 840, height: 540)

        Window("Protobuf", id: "protobuf") {
            ProtobufRulesView().preferredColorScheme(appColorScheme)
                .environment(\.locale, appLocale)
        }.defaultSize(width: 920, height: 600)

        Window(Strings.Menus.ruleFolders, id: "rule-folders") {
            RuleOrganizationView().preferredColorScheme(appColorScheme)
                .environment(\.locale, appLocale)
        }.defaultSize(width: 900, height: 580)

        Window(Strings.Menus.automation, id: "automation") {
            AutomationDashboardView().preferredColorScheme(appColorScheme)
                .environmentObject(appState)
                .environment(\.locale, appLocale)
        }.defaultSize(width: 820, height: 640)

        Window(Strings.Menus.softwareUpdates, id: "updates") {
            UpdateSettingsView().environment(\.locale, appLocale).preferredColorScheme(appColorScheme)
        }
            .defaultSize(width: 560, height: 360)

        Window(Strings.Menus.proxymirrorUserGuide, id: "help-guide") {
            HelpGuideView().environment(\.locale, appLocale).preferredColorScheme(appColorScheme)
        }
            .defaultSize(width: 780, height: 520)

    }

    private func showSettings(_ target: SettingsSearchTarget) {
        appState.settingsTarget = target
        if #available(macOS 14, *) { environment.openSettings() }
        else { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        NSApp.activate(ignoringOtherApps: true)
    }

    @CommandsBuilder
    private var proxyCommands: some Commands {
        CommandGroup(replacing: .appSettings) {
            if #available(macOS 14, *) {
                SettingsLink { Text(Strings.Menus.preferences) }.keyboardShortcut(",", modifiers: .command)
            } else {
                Button(Strings.Menus.preferences) {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }.keyboardShortcut(",", modifiers: .command)
            }
        }
        CommandGroup(replacing: .appTermination) {
            Button(Strings.Menus.quitProxymirror) { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        CommandGroup(after: .appInfo) { AppUpdateMenuItems() }
        CommandGroup(after: .newItem) {
            Button(Strings.Menus.openSessionOrHar) { appState.openSession() }.keyboardShortcut("o")
            Button(Strings.Menus.importCharlesSession) { appState.importCharlesSession() }
            Menu(Strings.Menus.openRecent) {
                ForEach(NSDocumentController.shared.recentDocumentURLs, id: \.self) { url in
                    Button(url.lastPathComponent) { appState.openSession(url) }
                }
                Divider()
                Button(Strings.Menus.clearMenu) { NSDocumentController.shared.clearRecentDocuments(nil) }
            }
            Button(Strings.Menus.saveSession) { appState.saveSession() }.keyboardShortcut("s")
            Button(Strings.Menus.saveSelectionAsSession) { appState.saveSession(onlySelection: true) }
                .disabled(appState.activeStore.selectedIDs.isEmpty)
            Button(Strings.Menus.rulesSettingsBackup) { appState.showRuleBackup = true }
        }
        // Edit 菜单追加（对齐 Proxyman Edit ▸ Copy as cURL ⇧⌘C）
        CommandGroup(after: .textEditing) {
            Button(Strings.Menus.editUrl) { appState.editSelected() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(appState.activeStore.selectedTransaction?.canReplay != true)
            Button(Strings.Menus.copyAsCurl) {
                appState.copyRequestsAsCurl(appState.activeStore.selectedTransactions)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(appState.activeStore.selectedIDs.isEmpty)
            Button(Strings.Menus.copyAsHttpie) {
                let runtime = appState.runtimeContext
                appState.copyText(appState.activeStore.selectedTransactions.map { ExportService.httpieCommand($0, runtime: runtime) }.joined(separator: "\n"))
            }
            .disabled(appState.activeStore.selectedIDs.isEmpty)
            Menu(Strings.Menus.copyAsCode) {
                ForEach(RequestCode.Format.allCases, id: \.self) { format in
                    Button(format.title) {
                        if let tx = appState.activeStore.selectedTransaction {
                            appState.copyText(RequestCode.generate(tx, format: format, runtime: appState.runtimeContext))
                        }
                    }.disabled(appState.activeStore.selectedTransaction.map { !RequestCode.supported(format, for: $0) } ?? true)
                }
            }
        }
        // View 菜单（对齐 Proxyman View）
        CommandGroup(after: .sidebar) {
            Button(Strings.Menus.filterDomainOrApp) {
                appState.showSidebar = true
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .focusSourceFilter, object: nil)
                }
            }
            .keyboardShortcut("f", modifiers: compatibleShortcuts ? [.command, .option] : [.command, .shift])
            Button(Strings.Menus.filterCurrentView) {
                NotificationCenter.default.post(name: .focusTrafficFilter, object: nil)
            }
            .keyboardShortcut("f", modifiers: compatibleShortcuts ? [.command, .shift] : .command)
            Button(Strings.Menus.findInBody) { NotificationCenter.default.post(name: .focusBodySearch, object: nil) }
                .keyboardShortcut(compatibleShortcuts ? KeyboardShortcut("f", modifiers: .command) : nil)
            Divider()
            Button(Strings.Menus.showCommandPalette) { appState.showCommandPalette = true }
                .keyboardShortcut("p", modifiers: .command)
            Divider()
            Toggle(Strings.Menus.autoSelectTheLatestRequest, isOn: Binding(
                get: { appState.activeStore.followLatest },
                set: { appState.activeStore.followLatest = $0 }))
                .keyboardShortcut("L", modifiers: [.command, .shift])
            Divider()
            Toggle(Strings.Menus.showSourceListPanel, isOn: Binding(
                get: { AppState.shared.showSidebar },
                set: { AppState.shared.showSidebar = $0 }))
                .keyboardShortcut("[", modifiers: [.control, .command])
            Button(Strings.Menus.newView) { appState.addWorkspace() }.keyboardShortcut("t", modifiers: .command)
            Button(Strings.Menus.toggleSplitView) { appState.toggleSplit() }
            Button(Strings.Menus.dockInspectorAtBottom) { appState.dockRight = false }
                .keyboardShortcut("]", modifiers: [.control, .command])
            Button(Strings.Menus.dockInspectorOnRight) { appState.dockRight = true }
                .keyboardShortcut("\\", modifiers: [.control, .command])
            Button(Strings.Menus.nextView) { appState.selectWorkspace((appState.activeTabIndex + 1) % max(1, appState.tabs.count)) }
                .keyboardShortcut("]", modifiers: [.shift, .command])
            Button(Strings.Menus.previousView) { appState.selectWorkspace((appState.activeTabIndex + appState.tabs.count - 1) % max(1, appState.tabs.count)) }
                .keyboardShortcut("[", modifiers: [.shift, .command])
            Button(Strings.Menus.showToolbar) { NSApp.keyWindow?.toggleToolbarShown(nil) }
                .keyboardShortcut("t", modifiers: [.option, .command])
            Button(Strings.Menus.keepWindowOnTop) {
                if let window = NSApp.keyWindow { window.level = window.level == .floating ? .normal : .floating }
            }
        }
        // Flow 菜单（对齐 Proxyman Flow）
        CommandMenu(Strings.Menus.traffic) {
            Button(Strings.Menus.repeat) { appState.repeatSelected() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!flowCommandsAvailable || !appState.activeStore.selectedTransactions.contains(where: \.canReplay))
            Button(Strings.Menus.saveSelectedRequests) { appState.activeStore.saveSelection() }
                .disabled(appState.activeStore.selectedIDs.isEmpty)
            Button(Strings.Menus.compareSelectedResponses) { appState.openComparison() }
                .disabled(appState.activeStore.selectedIDs.count != 2)
            Button(Strings.Menus.openComparisonPool(appState.diffPool.count)) { openWindow(id: "traffic-diff") }
                .keyboardShortcut("y", modifiers: [.option, .command])
            Button(Strings.Menus.addToComparisonPool) { appState.addToDiffPool(appState.activeStore.selectedTransactions) }
                .keyboardShortcut("y", modifiers: .command).disabled(appState.activeStore.selectedIDs.isEmpty)
            Button(Strings.Menus.clearComparisonPool) { appState.clearDiffPool() }.disabled(appState.diffPool.isEmpty)
            Button(Strings.Menus.editAndRepeat) { appState.editSelected(sendAndRepeat: true) }
                .keyboardShortcut(compatibleShortcuts ? KeyEquivalent.return : "r", modifiers: compatibleShortcuts ? [.option, .command] : [.command, .shift])
                .disabled(!flowCommandsAvailable || appState.activeStore.selectedTransaction?.canReplay != true)
            Button(Strings.Menus.enableSslProxyingForThisDomain) { appState.enableSSLProxyingForSelected() }
                .keyboardShortcut(.return, modifiers: .option)
                .disabled(appState.activeStore.selectedTransaction == nil)
            Divider()
            Button(Strings.Menus.exportSelectedRequestsAsHar) { ExportService.exportHAR(appState.activeStore.selectedTransactions) }
                .keyboardShortcut("S", modifiers: [.command, .shift])
                .disabled(appState.activeStore.selectedIDs.isEmpty)
            Menu(Strings.Menus.export) {
                Button(Strings.Menus.asHarHttpArchive) { ExportService.exportHAR(appState.activeStore.selectedTransactions) }
                    .disabled(appState.activeStore.selectedIDs.isEmpty)
                Button(Strings.Menus.asCsv) { ExportService.exportCSV(appState.activeStore.selectedTransactions) }
                    .disabled(appState.activeStore.selectedIDs.isEmpty)
                Button(Strings.Menus.exportOpenapi) { ExportService.exportOpenAPI(exportTargets) }
                    .disabled(exportTargets.isEmpty)
                Button(Strings.Menus.exportPostman) { ExportService.exportPostman(exportTargets) }
                    .disabled(exportTargets.isEmpty)
                Button(Strings.Menus.publishToGithubGist) { appState.showGistPublish = true }
            }
            Divider()
            Button(Strings.Menus.addComment) { appState.openComment() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(appState.activeStore.selectedIDs.isEmpty)
            Menu(Strings.Menus.highlight) {
                ForEach(Array(ProxymanTheme.highlightNames.enumerated()), id: \.element) { index, name in
                    Button(ProxymanTheme.localizedHighlightName(name)) { appState.highlightSelected(name) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
                Divider()
                Button(Strings.Menus.strikethrough) { appState.strikethroughSelected() }
                    .keyboardShortcut("/", modifiers: .command)
                Button(Strings.Menus.reset) { appState.highlightSelected(nil); appState.unstrikethroughSelected() }
                    .keyboardShortcut("0", modifiers: [.command, .shift])
            }
            Divider()
            Button(Strings.Menus.clearSession) { appState.clearTraffic() }
                .keyboardShortcut(compatibleShortcuts ? KeyEquivalent.delete : "k", modifiers: [.command, .option, .shift])
                .disabled(!flowCommandsAvailable)
            Divider()
            Button(Strings.Menus.delete) { appState.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!flowCommandsAvailable || appState.activeStore.selectedIDs.isEmpty)
            Button(Strings.Menus.deleteAll) { appState.clearTraffic() }
                .keyboardShortcut(.delete, modifiers: [.shift, .command])
                .disabled(!flowCommandsAvailable)
            Divider()
            Button(Strings.Menus.generateSampleTraffic) { appState.store.addSampleData() }
        }
        // Tools 菜单（对齐 Proxyman Tools 完整结构；未实现项灰态）
        CommandMenu(Strings.Menus.tools) {
            Button(Strings.Menus.toggleRecording) { appState.toggleRecording() }
                .keyboardShortcut("r", modifiers: .command)
            Button((appState.proxyRunning ? Strings.Menus.stopListening : Strings.Menus.startListening)) { appState.toggleProxy() }
            Button(appState.transparentProxyMenuTitle) { appState.toggleTransparentProxy() }
                .disabled(appState.transparentProxyState == .stopping)
            Divider()
            Button(Strings.Menus.sslProxyingList) { appState.openTool(.sslProxyingList) }
                .keyboardShortcut("p", modifiers: compatibleShortcuts ? [.command, .option] : [.command, .shift])
            Button(Strings.Menus.configureSslByApplication) { appState.openTool(.sslApplications) }
            Button(Strings.Menus.composeRequest) { appState.openTool(.compose) }
                .keyboardShortcut(compatibleShortcuts ? "c" : "n", modifiers: [.command, .option])
            Divider()
            BreakpointMenu()
            ScriptingMenu()
            Button(Strings.Menus.mapLocal) { appState.openTool(.mapLocal) }
                .keyboardShortcut("l", modifiers: [.option, .command])
            Button(Strings.Menus.mapRemote) { appState.openTool(.mapRemote) }
                .keyboardShortcut("r", modifiers: [.option, .command])
            Button(Strings.Menus.dnsMapping) { appState.openTool(.dnsMapping) }
            Button(Strings.Menus.reverseProxy) { appState.openTool(.reverseProxy) }
            Button(Strings.Menus.blockList) { appState.openTool(.blockList) }
                .keyboardShortcut("[", modifiers: [.option, .command])
            Button(Strings.Menus.allowList) { appState.openTool(.allowList) }
                .keyboardShortcut("]", modifiers: [.option, .command])
            Toggle(Strings.Menus.noCaching, isOn: Binding(
                get: { RulesStore.shared.noCaching },
                set: { RulesStore.shared.noCaching = $0 }))
                .keyboardShortcut(compatibleShortcuts ? KeyboardShortcut("n", modifiers: [.option, .command]) : nil)
            Divider()
            Button(Strings.Menus.networkConditions) { openWindow(id: "network-conditions") }
                .keyboardShortcut("j", modifiers: [.option, .command])
            Button((appState.tlsKeyLogURL == nil ? Strings.Menus.startTlsKeyLogging : Strings.Menus.stopTlsKeyLogging)) {
                appState.toggleTLSKeyLogging()
            }
            Divider()
            Button(Strings.Menus.pairInAppCapture) { appState.showOrStartBridgeCapture() }
            if appState.bridgePairingCode != nil {
                Button(Strings.Menus.stopInAppCapture) { appState.stopBridgeCapture() }
            }
            Button(Strings.Menus.customTrafficColumns) { appState.showColumnEditor = true }
            Button(Strings.Menus.customPreviewers2) { openWindow(id: "custom-previewers") }
            Button(Strings.Menus.protobufSchemasMappings) { openWindow(id: "protobuf") }
                .keyboardShortcut("u", modifiers: [.option, .command])
            Button(Strings.Menus.trafficSummary2) { openWindow(id: "flow-summary") }
            Button(Strings.Menus.automationDashboard) { openWindow(id: "automation") }
            Menu(Strings.Menus.proxySettings) {
                Button(appState.systemProxyActive ? Strings.Menus.restoreSystemProxy : Strings.Menus.overrideProxy) {
                    if appState.systemProxyActive { appState.stopSystemProxy() } else { appState.startSystemProxy() }
                }.keyboardShortcut("o", modifiers: [.option, .command]).disabled(appState.systemProxyBusy)
                Button(Strings.Menus.externalProxy) { showSettings(.upstreamProxy) }
                    .keyboardShortcut("e", modifiers: [.option, .command])
            }
            Divider()
            Button(Strings.Menus.importRulesFromCharles) { appState.showCharlesRules = true }
            ToolsEnableMenu()
            Button(Strings.Menus.manageRuleFolders) { openWindow(id: "rule-folders") }
            Button(Strings.Menus.customizeToolbar) {
                NSApp.windows.first { $0.isVisible && $0.toolbar?.allowsUserCustomization == true }?
                    .toolbar?.runCustomizationPalette(nil)
            }
        }
        CommandMenu(Strings.Menus.certificates) { CertificateMenuContent() }
        CommandMenu(Strings.Menus.setup) {
            ForEach(["macOS", "iOS", "iOS Simulator", "Android", "Android Emulator", "Java"], id: \.self) { platform in
                Button(platform) { openWindow(id: "setup-guide", value: platform) }
            }
            Divider()
            Button(Strings.Menus.automation) { openWindow(id: "automation") }
        }
        CommandGroup(replacing: .help) {
            Button(Strings.Menus.userGuide) {
                HelpGuideCoordinator.shared.show(.gettingStarted)
                openWindow(id: "help-guide")
            }
            TroubleshootingMenu()
            Button(Strings.Menus.installProxymirrorCliInPath) { LocalControl.installCLI() }
            Button(Strings.Menus.showMcpConfiguration) { LocalControl.showMCPConfiguration() }
            Button(Strings.Menus.softwareUpdateSettings) { openWindow(id: "updates") }
            Divider()
            Menu(Strings.Menus.advanced) {
                Button(Strings.Menus.copyDebugInformation) { appState.copyText(AppDiagnostics.debugInfo()) }
                Button(Strings.Menus.simulateMemoryWarning) {
                    appState.systemProxyMessage = MemoryPressureController.shared.simulateWarning().summary
                }
                Button(Strings.Menus.openUserDataFolder) { AppDiagnostics.openDataFolder() }
                Button(Strings.Menus.openBackupFolder) { AppDiagnostics.openDataFolder(backups: true) }
                Button(Strings.Menus.backUpRulesSettings) {
                    do { let url = try AppDiagnostics.backup(); NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    catch { appState.systemProxyMessage = LocalizedErrorPresentation.message(for: error) }
                }
                Toggle(Strings.Menus.debugMode, isOn: Binding(get: { UserDefaults.standard.bool(forKey: "diagnostics.debugMode") },
                    set: { UserDefaults.standard.set($0, forKey: "diagnostics.debugMode"); DiagnosticLog.record("debug mode enabled") }))
                Button(Strings.Menus.showDiagnosticLog) { NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLog.fileURL]) }
                Button(Strings.Menus.restoreSystemProxy) { appState.stopSystemProxy() }.disabled(!appState.systemProxyActive || appState.systemProxyBusy)
                Button(Strings.Menus.restoreDefaults) { appState.showFactoryReset = true }
            }
        }
    }
}

@MainActor
final class ProxyMirrorLifecycle: NSObject, NSApplicationDelegate {
    private var localControl: DispatchSourceRead?
    private var mcpConfigurationObserver: NSObjectProtocol?
    private var preferencesObserver: NSObjectProtocol?
    private var snapshotObserver: NSObjectProtocol?
    private var lastAppliedAppearance: String?
    private var lastAppliedMCPEnabled: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyPreferences()
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyPreferences() }
        }
        if ProcessInfo.processInfo.environment["PM_SETTINGS_SNAPSHOT"] != nil {
            MCPPreferencesController.shared.register(applyEnabled: { _ in
                MCPPreferencesController.shared.update(isRunning: false)
            }, configuration: { client, transport in
                guard transport == .stdio else { return nil }
                return MCPServer.clientConfiguration(client: client, transport: transport)
            })
            snapshotObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("ProxyMirror.settingsSnapshotFinished"), object: nil, queue: .main
            ) { _ in Task { @MainActor in NSApp.terminate(nil) } }
            return
        }
        AppUpdateController.shared.startIfConfigured()
        MemoryPressureController.shared.startMonitoring()
        TrafficCleanupController.shared.startMonitoring()
        mcpConfigurationObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("ProxyMirror.showMCPConfiguration"), object: nil, queue: .main
        ) { _ in
            Task { @MainActor in LocalControl.showMCPConfiguration() }
        }
        do {
            localControl = try LocalControl.start()
        } catch {
            NSLog("[ProxyMirror] 本机控制接口启动失败：%@", error.localizedDescription)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppUpdateController.shared.stop()
        MemoryPressureController.shared.stopMonitoring()
        TrafficCleanupController.shared.stopMonitoring()
        if let observer = mcpConfigurationObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = preferencesObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = snapshotObserver { NotificationCenter.default.removeObserver(observer) }
        mcpConfigurationObserver = nil
        preferencesObserver = nil
        snapshotObserver = nil
        localControl?.cancel()
        LocalControl.stopAutomation()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let state = AppState.shared
        guard !state.systemProxyBusy else { return .terminateCancel }
        if state.settings.warnBeforeQuit, ProcessInfo.processInfo.environment["PM_SETTINGS_SNAPSHOT"] == nil {
            let alert = NSAlert()
            alert.messageText = Strings.Menus.quitProxymirror2
            alert.informativeText = Strings.Menus.trafficCaptureWillStopAndTheSystemProxy
            alert.addButton(withTitle: Strings.Menus.quit)
            alert.addButton(withTitle: Strings.Menus.cancel)
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = Strings.Menus.doNotAskAgain
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            if alert.suppressionButton?.state == .on { state.settings.warnBeforeQuit = false }
        }
        guard flushRulesBeforeQuit() else { return .terminateCancel }
        if state.store.finishSaving({ success in
            guard success else {
                self.cancelTerminationAfterSaveFailure(sender)
                return
            }
            guard !state.systemProxyBusy else {
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            state.restoreCaptureOnExit { self.replyToTermination(sender, restored: $0) }
        }) { return .terminateLater }
        guard state.systemProxyActive || state.transparentProxyNeedsStop else { return .terminateNow }
        state.restoreCaptureOnExit { self.replyToTermination(sender, restored: $0) }
        return .terminateLater
    }

    private func flushRulesBeforeQuit() -> Bool {
        do {
            try RulesStore.shared.flushPendingSave()
            return true
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = Strings.Settings.saveFailed
            alert.informativeText = Strings.Settings.saveFailureReason(LocalizedErrorPresentation.message(for: error))
            alert.addButton(withTitle: Strings.Menus.cancel)
            alert.runModal()
            return false
        }
    }

    private func replyToTermination(_ sender: NSApplication, restored: Bool) {
        let state = AppState.shared
        guard restored, !state.systemProxyBusy else {
            sender.reply(toApplicationShouldTerminate: false)
            return
        }
        // Capture restoration can outlive the first Saved flush. Recheck the
        // latest snapshot after every asynchronous wait before the final reply.
        if state.store.finishSaving({ success in
            guard success else {
                self.cancelTerminationAfterSaveFailure(sender)
                return
            }
            self.replyToTermination(sender, restored: true)
        }) { return }
        sender.reply(toApplicationShouldTerminate: flushRulesBeforeQuit())
    }

    private func cancelTerminationAfterSaveFailure(_ sender: NSApplication) {
        let state = AppState.shared
        state.markSavedErrorPresented()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Strings.Settings.saveFailed
        alert.informativeText = state.store.savedError ?? Strings.Settings.saveFailed
        alert.addButton(withTitle: Strings.Menus.cancel)
        alert.runModal()
        sender.reply(toApplicationShouldTerminate: false)
    }

    private func applyPreferences() {
        let settings = AppSettings.shared
        let previewAppearance = ProcessInfo.processInfo.environment["PM_SETTINGS_SNAPSHOT"] == nil ? nil
            : ProcessInfo.processInfo.environment["PM_SETTINGS_APPEARANCE"]
        let selectedAppearance = previewAppearance == "dark" ? "dark" : previewAppearance == "light" ? "light" : settings.appearance
        if lastAppliedAppearance != selectedAppearance {
            lastAppliedAppearance = selectedAppearance
            switch selectedAppearance {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: NSApp.appearance = nil
            }
        }
        if lastAppliedMCPEnabled != settings.mcpEnabled {
            lastAppliedMCPEnabled = settings.mcpEnabled
            MCPPreferencesController.shared.refresh()
        }
        AppUpdateController.shared.updateNotificationPreference()
    }
}

private struct PreferencesSnapshotLauncher: ViewModifier {
    @Environment(\.self) private var environment
    @State private var launched = false

    func body(content: Content) -> some View {
        content.onAppear {
            guard !launched, ProcessInfo.processInfo.environment["PM_SETTINGS_SNAPSHOT"] != nil else { return }
            launched = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if #available(macOS 14, *) { environment.openSettings() }
                else { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
            }
        }
    }
}

/// 独立详情窗口
struct DetachedDetailView: View {
    let txID: String?
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let parts = txID?.split(separator: ":"), parts.count == 2,
           let workspace = UUID(uuidString: String(parts[0])),
           let id = UUID(uuidString: String(parts[1])),
           let tx = appState.detachedTransaction(workspace: workspace, id: id) {
            VStack(spacing: 0) {
                DetailContentView(tx: tx, store: appState.store, navigationEnabled: false)
            }
            .frame(minWidth: 720, minHeight: 480)
            .navigationTitle(tx.host)
        } else {
            Text(Strings.Menus.theRequestNoLongerExistsOrHasBeen)
                .foregroundColor(.secondary)
                .frame(minWidth: 400, minHeight: 300)
        }
    }
}
