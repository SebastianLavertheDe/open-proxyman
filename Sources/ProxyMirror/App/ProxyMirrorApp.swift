import SwiftUI
@testable import ProxyMirrorCore

struct ProxyMirrorMainApp: App {
    @NSApplicationDelegateAdaptor(ProxyMirrorLifecycle.self) private var lifecycle
    @StateObject private var appState = AppState.shared
    @AppStorage(ProxyMirrorAppearance.key) private var appearance = ProxyMirrorAppearance.system
    @AppStorage("ui.showMenuBarIcon") private var showMenuBarIcon = false
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("ProxyMirror") {
            MainWindow()
                .environmentObject(appState)
                .modifier(BreakpointOpening())
                .preferredColorScheme(appearance.colorScheme)
                .onOpenURL { appState.openSession($0) }
                .frame(minWidth: 980, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands { proxyCommands }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .preferredColorScheme(appearance.colorScheme)
        }

        Window("断点", id: "breakpoints") {
            BreakpointWindow()
                .preferredColorScheme(appearance.colorScheme)
        }
        .defaultSize(width: 920, height: 560)

        Window("脚本", id: "scripting") {
            ScriptingWindow()
                .preferredColorScheme(appearance.colorScheme)
        }
        .defaultSize(width: 1020, height: 610)

        toolScenes

        MenuBarExtra("ProxyMirror", systemImage: "network", isInserted: $showMenuBarIcon) {
            Button(appState.proxyRunning ? "停止监听" : "启动监听", action: appState.toggleProxy)
            Button(appState.recordingEnabled ? "暂停录制" : "恢复录制", action: appState.toggleRecording)
            Divider()
            Text("127.0.0.1:\(appState.settings.port)")
            Button("显示 ProxyMirror") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
            Button("退出") { NSApp.terminate(nil) }
        }

        // 双击/独立详情窗口
        WindowGroup("Request Detail", id: "request-detail", for: String.self) { $id in
            DetachedDetailView(txID: id)
                .environmentObject(appState)
                .preferredColorScheme(appearance.colorScheme)
        }
        .windowResizability(.contentMinSize)
    }

    @SceneBuilder
    private var toolScenes: some Scene {
        Window("流量对比", id: "traffic-diff") {
            TrafficDiffWorkspaceView(appState: appState)
                .preferredColorScheme(appearance.colorScheme)
        }.defaultSize(width: 1100, height: 680)

        Window("流量汇总", id: "flow-summary") {
            FlowSummaryView(store: appState.activeStore)
                .preferredColorScheme(appearance.colorScheme)
        }.defaultSize(width: 700, height: 500)

        Window("自定义预览器", id: "custom-previewers") {
            CustomPreviewerManagerView().preferredColorScheme(appearance.colorScheme)
        }.defaultSize(width: 840, height: 540)

        Window("Protobuf", id: "protobuf") {
            ProtobufRulesView().preferredColorScheme(appearance.colorScheme)
        }.defaultSize(width: 920, height: 600)

        Window("规则文件夹", id: "rule-folders") {
            RuleOrganizationView().preferredColorScheme(appearance.colorScheme)
        }.defaultSize(width: 900, height: 580)

        Window("自动化", id: "automation") {
            AutomationDashboardView().preferredColorScheme(appearance.colorScheme)
        }.defaultSize(width: 820, height: 580)

        Window("软件更新", id: "updates") { UpdateSettingsView() }
            .defaultSize(width: 560, height: 360)

        Window("ProxyMirror 使用指南", id: "help-guide") { HelpGuideView() }
            .defaultSize(width: 780, height: 520)

    }

    @CommandsBuilder
    private var proxyCommands: some Commands {
        CommandGroup(after: .appInfo) { AppUpdateMenuItems() }
        CommandGroup(after: .newItem) {
            Button("打开会话或 HAR…") { appState.openSession() }.keyboardShortcut("o")
            Button("导入 Charles 会话…") { appState.importCharlesSession() }
            Menu("最近打开") {
                ForEach(NSDocumentController.shared.recentDocumentURLs, id: \.self) { url in
                    Button(url.lastPathComponent) { appState.openSession(url) }
                }
                Divider()
                Button("清除菜单") { NSDocumentController.shared.clearRecentDocuments(nil) }
            }
            Button("保存会话…") { appState.saveSession() }.keyboardShortcut("s")
            Button("保存所选为会话…") { appState.saveSession(onlySelection: true) }
                .disabled(appState.activeStore.selectedIDs.isEmpty)
            Button("规则与设置备份…") { appState.showRuleBackup = true }
        }
        // Edit 菜单追加（对齐 Proxyman Edit ▸ Copy as cURL ⇧⌘C）
        CommandGroup(after: .textEditing) {
            Button("Edit URL") { appState.editSelected() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(appState.activeStore.selectedTransaction?.canReplay != true)
            Button("Copy as cURL") {
                appState.copyRequestsAsCurl(appState.activeStore.selectedTransactions)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(appState.activeStore.selectedIDs.isEmpty)
            Button("复制为 HTTPie") {
                appState.copyText(appState.activeStore.selectedTransactions.map(ExportService.httpieCommand).joined(separator: "\n"))
            }
            .disabled(appState.activeStore.selectedIDs.isEmpty)
            Menu("复制为代码") {
                ForEach(RequestCode.Format.allCases, id: \.self) { format in
                    Button(format.title) {
                        if let tx = appState.activeStore.selectedTransaction { appState.copyText(RequestCode.generate(tx, format: format)) }
                    }.disabled(appState.activeStore.selectedTransaction.map { !RequestCode.supported(format, for: $0) } ?? true)
                }
            }
        }
        // View 菜单（对齐 Proxyman View）
        CommandGroup(after: .sidebar) {
            Button("Filter Domain or App") {
                appState.showSidebar = true
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .focusSourceFilter, object: nil)
                }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Filter Current View") {
                NotificationCenter.default.post(name: .focusTrafficFilter, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
            Divider()
            Button("Show Command Palette") { appState.showCommandPalette = true }
                .keyboardShortcut("p", modifiers: .command)
            Divider()
            Toggle("Auto Select the Latest Request", isOn: Binding(
                get: { appState.activeStore.followLatest },
                set: { appState.activeStore.followLatest = $0 }))
                .keyboardShortcut("L", modifiers: [.command, .shift])
            Divider()
            Toggle("Show Source List Panel", isOn: Binding(
                get: { AppState.shared.showSidebar },
                set: { AppState.shared.showSidebar = $0 }))
            Button("新建视图") { appState.addWorkspace() }.keyboardShortcut("t", modifiers: .command)
            Button("切换分屏") { appState.toggleSplit() }
            Button("详情停靠在底部") { appState.dockRight = false }
            Button("详情停靠在右侧") { appState.dockRight = true }
            Button("窗口始终置顶") {
                if let window = NSApp.keyWindow { window.level = window.level == .floating ? .normal : .floating }
            }
        }
        // Flow 菜单（对齐 Proxyman Flow）
        CommandMenu("数据流") {
            Button("Repeat") { appState.repeatSelected() }
                .disabled(!appState.activeStore.selectedTransactions.contains(where: \.canReplay))
            Button("保存所选请求") { appState.activeStore.saveSelection() }
                .disabled(appState.activeStore.selectedIDs.isEmpty)
            Button("对比所选响应…") { appState.openComparison() }
                .disabled(appState.activeStore.selectedIDs.count != 2)
            Button("打开对比池（\(appState.diffPool.count)）…") { openWindow(id: "traffic-diff") }
            Button("加入对比池") { appState.addToDiffPool(appState.activeStore.selectedTransactions) }
                .keyboardShortcut("y", modifiers: .command).disabled(appState.activeStore.selectedIDs.isEmpty)
            Button("清空对比池") { appState.clearDiffPool() }.disabled(appState.diffPool.isEmpty)
            Button("Edit and Repeat…") { appState.editSelected(sendAndRepeat: true) }
                .keyboardShortcut("R", modifiers: [.command, .shift])
                .disabled(appState.activeStore.selectedTransaction?.canReplay != true)
            Button("Enable SSL Proxying for This Domain") { appState.enableSSLProxyingForSelected() }
                .disabled(appState.activeStore.selectedTransaction == nil)
            Divider()
            Button("导出所选请求为 HAR…") { ExportService.exportHAR(appState.activeStore.selectedTransactions) }
                .keyboardShortcut("S", modifiers: [.command, .shift])
                .disabled(appState.activeStore.selectedIDs.isEmpty)
            Menu("Export") {
                Button("as HAR (HTTP Archive)") { ExportService.exportHAR(appState.activeStore.selectedTransactions) }
                    .disabled(appState.activeStore.selectedIDs.isEmpty)
                Button("as CSV") { ExportService.exportCSV(appState.activeStore.selectedTransactions) }
                    .disabled(appState.activeStore.selectedIDs.isEmpty)
                Button("发布到 GitHub Gist…") { appState.showGistPublish = true }
            }
            .disabled(appState.activeStore.selectedIDs.isEmpty)
            Divider()
            Button("Add Comment…") { appState.openComment() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(appState.activeStore.selectedIDs.isEmpty)
            Menu("Highlight") {
                ForEach(ProxymanTheme.highlightNames, id: \.self) { name in
                    Button(name) { appState.highlightSelected(name) }
                }
                Divider()
                Button("Strikethrough") { appState.strikethroughSelected() }
                    .keyboardShortcut("/", modifiers: .command)
                Button("Reset") { appState.highlightSelected(nil); appState.unstrikethroughSelected() }
                    .keyboardShortcut("0", modifiers: .command)
            }
            Divider()
            Button("Clear Session") { appState.clearTraffic() }
                .keyboardShortcut("k", modifiers: [.command, .option, .shift])
            Divider()
            Button("Delete") { appState.deleteSelected() }
                .disabled(appState.activeStore.selectedIDs.isEmpty)
            Button("Delete All") { appState.clearTraffic() }
            Divider()
            Button("生成示例流量") { appState.store.addSampleData() }
        }
        // Tools 菜单（对齐 Proxyman Tools 完整结构；未实现项灰态）
        CommandMenu("工具") {
            Button("从 Charles 导入规则…") { appState.showCharlesRules = true }
            Button("切换录制") { appState.toggleRecording() }
                .keyboardShortcut("r", modifiers: .command)
            Button(appState.proxyRunning ? "停止监听" : "启动监听") { appState.toggleProxy() }
            Button(appState.transparentProxyMenuTitle) { appState.toggleTransparentProxy() }
                .disabled(appState.transparentProxyState == .stopping)
            Divider()
            Button("SSL Proxying List…") { appState.openTool(.sslProxyingList) }
                .keyboardShortcut("P", modifiers: [.command, .shift])
            Button("按应用配置 SSL…") { appState.openTool(.sslApplications) }
            Button("Compose Request…") { appState.openTool(.compose) }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            BreakpointMenu()
            ScriptingMenu()
            Button("Map Local…") { appState.openTool(.mapLocal) }
                .keyboardShortcut("l", modifiers: [.option, .command])
            Button("Map Remote…") { appState.openTool(.mapRemote) }
                .keyboardShortcut("r", modifiers: [.option, .command])
            Button("DNS 映射…") { appState.openTool(.dnsMapping) }
            Button("反向代理…") { appState.openTool(.reverseProxy) }
            Button("Block List…") { appState.openTool(.blockList) }
                .keyboardShortcut("[", modifiers: [.option, .command])
            Button("Allow List…") { appState.openTool(.allowList) }
                .keyboardShortcut("]", modifiers: [.option, .command])
            Toggle("No Caching", isOn: Binding(
                get: { RulesStore.shared.noCaching },
                set: { RulesStore.shared.noCaching = $0 }))
            Divider()
            Button("弱网模拟…") { appState.showLatencyEditor = true }
                .keyboardShortcut("j", modifiers: [.option, .command])
            Button(appState.tlsKeyLogURL == nil ? "开始记录 TLS 密钥…" : "停止记录 TLS 密钥") {
                appState.toggleTLSKeyLogging()
            }
            Divider()
            Button("应用内捕获配对…") { appState.showOrStartBridgeCapture() }
            if appState.bridgePairingCode != nil {
                Button("停止应用内捕获") { appState.stopBridgeCapture() }
            }
            Button("自定义流量列…") { appState.showColumnEditor = true }
            Button("自定义预览器…") { openWindow(id: "custom-previewers") }
            Button("Protobuf Schema 与映射…") { openWindow(id: "protobuf") }
            Button("流量汇总…") { openWindow(id: "flow-summary") }
            Button("自动化 Dashboard…") { openWindow(id: "automation") }
            ToolsEnableMenu()
            Button("管理规则文件夹…") { openWindow(id: "rule-folders") }
            Button("自定义工具栏…") {
                NSApp.windows.first { $0.isVisible && $0.toolbar?.allowsUserCustomization == true }?
                    .toolbar?.runCustomizationPalette(nil)
            }
        }
        CommandMenu("证书") { CertificateMenuContent() }
        CommandGroup(replacing: .help) {
            Button("入门、故障排查与数据恢复…") { openWindow(id: "help-guide") }
            Button("安装 proxymirror-cli 到 PATH…") { LocalControl.installCLI() }
            Button("查看 MCP 连接配置") { LocalControl.showMCPConfiguration() }
            Button("软件更新设置…") { openWindow(id: "updates") }
            Divider()
            Button("复制调试信息") { appState.copyText(AppDiagnostics.debugInfo()) }
            Button("打开用户数据文件夹") { AppDiagnostics.openDataFolder() }
            Button("打开备份文件夹") { AppDiagnostics.openDataFolder(backups: true) }
            Button("备份规则与设置") {
                do { let url = try AppDiagnostics.backup(); NSWorkspace.shared.activateFileViewerSelecting([url]) }
                catch { appState.systemProxyMessage = error.localizedDescription }
            }
            Toggle("调试模式", isOn: Binding(get: { UserDefaults.standard.bool(forKey: "diagnostics.debugMode") },
                set: { UserDefaults.standard.set($0, forKey: "diagnostics.debugMode"); DiagnosticLog.record("debug mode enabled") }))
            Button("显示诊断日志") { NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLog.fileURL]) }
            Button("恢复系统代理") { appState.stopSystemProxy() }.disabled(!appState.systemProxyActive || appState.systemProxyBusy)
            Button("恢复默认设置…") { appState.showFactoryReset = true }
        }
    }
}

@MainActor
final class ProxyMirrorLifecycle: NSObject, NSApplicationDelegate {
    private var localControl: DispatchSourceRead?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppUpdateController.shared.startIfConfigured()
        do {
            localControl = try LocalControl.start()
        } catch {
            NSLog("[ProxyMirror] 本机控制接口启动失败：%@", error.localizedDescription)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        localControl?.cancel()
        LocalControl.stopAutomation()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let state = AppState.shared
        guard !state.systemProxyBusy else { return .terminateCancel }
        if state.store.finishSaving({ success in
            guard success, !state.systemProxyBusy else {
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            state.restoreCaptureOnExit { sender.reply(toApplicationShouldTerminate: $0) }
        }) { return .terminateLater }
        guard state.systemProxyActive || state.transparentProxyNeedsStop else { return .terminateNow }
        state.restoreCaptureOnExit { sender.reply(toApplicationShouldTerminate: $0) }
        return .terminateLater
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
            Text("请求不存在或已被清理")
                .foregroundColor(.secondary)
                .frame(minWidth: 400, minHeight: 300)
        }
    }
}
