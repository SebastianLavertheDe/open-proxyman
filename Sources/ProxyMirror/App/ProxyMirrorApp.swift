import SwiftUI
@testable import ProxyMirrorCore

struct ProxyMirrorMainApp: App {
    @NSApplicationDelegateAdaptor(ProxyMirrorLifecycle.self) private var lifecycle
    @StateObject private var appState = AppState.shared
    @AppStorage(ProxyMirrorAppearance.key) private var appearance = ProxyMirrorAppearance.system

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
        }
        .defaultSize(width: 920, height: 560)

        Window("脚本", id: "scripting") {
            ScriptingWindow()
        }
        .defaultSize(width: 1020, height: 610)

        // 双击/独立详情窗口
        WindowGroup("Request Detail", id: "request-detail", for: String.self) { $id in
            DetachedDetailView(txID: id)
                .environmentObject(appState)
                .preferredColorScheme(appearance.colorScheme)
        }
        .windowResizability(.contentMinSize)
    }

    @CommandsBuilder
    private var proxyCommands: some Commands {
        CommandGroup(after: .newItem) {
            Button("打开会话或 HAR…") { appState.openSession() }.keyboardShortcut("o")
            Button("导入 Charles 会话…") { appState.importCharlesSession() }
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
                CopyPaste.copy(appState.activeStore.selectedTransactions.map(ExportService.curlCommand).joined(separator: "\n"))
            }
            .keyboardShortcut("C", modifiers: [.command, .shift])
            .disabled(appState.activeStore.selectedIDs.isEmpty)
            Button("复制为 HTTPie") {
                CopyPaste.copy(appState.activeStore.selectedTransactions.map(ExportService.httpieCommand).joined(separator: "\n"))
            }
            .disabled(appState.activeStore.selectedIDs.isEmpty)
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
        }
        // Flow 菜单（对齐 Proxyman Flow）
        CommandMenu("数据流") {
            Button("Repeat") { appState.repeatSelected() }
                .disabled(!appState.activeStore.selectedTransactions.contains(where: \.canReplay))
            Button("保存所选请求") { appState.activeStore.saveSelection() }
                .disabled(appState.activeStore.selectedIDs.isEmpty)
            Button("对比所选响应…") { appState.openComparison() }
                .disabled(appState.activeStore.selectedIDs.count != 2)
            Button("打开对比池（\(appState.diffPool.count)/2）…") { appState.openComparison(usePool: true) }
                .disabled(appState.diffPool.count != 2)
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
            Button("自定义工具栏…") {
                NSApp.windows.first { $0.isVisible && $0.toolbar?.allowsUserCustomization == true }?
                    .toolbar?.runCustomizationPalette(nil)
            }
        }
        CommandMenu("证书") { CertificateMenuContent() }
    }
}

@MainActor
final class ProxyMirrorLifecycle: NSObject, NSApplicationDelegate {
    private var localControl: DispatchSourceRead?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            localControl = try LocalControl.start()
        } catch {
            NSLog("[ProxyMirror] 本机控制接口启动失败：%@", error.localizedDescription)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        localControl?.cancel()
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
                DetailContentView(tx: tx, store: appState.store)
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
