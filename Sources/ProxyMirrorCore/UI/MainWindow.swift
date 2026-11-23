import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    private var store: TrafficStore { appState.activeStore }
    @FocusState private var trafficFilterFocused: Bool
    @State private var message: String?
    @State private var showFilterEditor = false
    @State private var showTrafficSearch = false
    @State private var showListenDetails = false
    @AppStorage("ui.showResourceUsage") private var showResourceUsage = true

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { appState.showSidebar ? NavigationSplitViewVisibility.all : .detailOnly },
            set: { appState.showSidebar = $0 == .all })) {
            SourceSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 200, ideal: 296, max: 520)
        } detail: {
            VStack(spacing: 0) {
                if appState.tabs.count > 1 || appState.activeTab.archiveName != nil { workspaceTabs }
                if let split = appState.splitStore {
                    HSplitView {
                        splitPane(appState.activeTab, right: false)
                        splitPane(split, right: true)
                    }
                } else {
                    workspace(appState.activeTab, dockRight: appState.dockRight).id(appState.activeTab.id)
                }
                bottomStatusBar
            }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("ProxyMirror")
        .toolbar(id: "proxymirror.capture-toolbar") { mainToolbar }
        .frame(minWidth: 980, minHeight: 560)
        .onReceive(NotificationCenter.default.publisher(for: .focusTrafficFilter)) { _ in
            showTrafficSearch = true
            DispatchQueue.main.async { trafficFilterFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pmOpenProtobuf)) { _ in openWindow(id: "protobuf") }
        .onChange(of: appState.proxyStartError) { if let text = $0 { message = text } }
        .onChange(of: appState.systemProxyMessage) { if let text = $0, !text.hasPrefix("正在") { message = text } }
        .onChange(of: appState.showDiff) { showing in
            if showing { openWindow(id: "traffic-diff"); appState.showDiff = false }
        }
        .onAppear { if let text = store.savedError { message = text } }
        .onChange(of: store.savedError) { if let text = $0 { message = text } }
        .alert("ProxyMirror", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: {
            Text(message ?? "")
        }
        .sheet(item: $appState.activeTool, onDismiss: appState.dismissTool) { tool in
            if tool == .compose {
                ComposeRequestView(transaction: appState.toolTransaction)
            } else if tool == .dnsMapping {
                DNSMappingEditor(initialHost: appState.toolTransaction?.host ?? "")
            } else if tool == .reverseProxy {
                ReverseProxyEditor()
            } else if tool == .sslApplications {
                SSLApplicationRulesView(transaction: appState.toolTransaction)
            } else if tool == .customCertificates {
                CustomCertificateView()
            } else {
                RulesEditorView(kind: tool, initialPattern: appState.toolTransaction.map {
                    tool == .sslProxyingList ? $0.host : $0.originalURL ?? $0.fullURL
                } ?? "")
            }
        }
        .sheet(isPresented: $appState.showCommentSheet, onDismiss: appState.dismissComments) {
            CommentEditor(targets: appState.commentTargets, store: store)
        }
        .sheet(isPresented: $appState.showCommandPalette) {
            CommandPalette()
        }
        .sheet(isPresented: $showFilterEditor) {
            TrafficFilterEditor(store: store)
        }
        .sheet(isPresented: $appState.showBridgePairing) {
            BridgePairingView()
        }
        .sheet(isPresented: $appState.showRuleBackup) {
            RuleBackupView()
        }
        .sheet(isPresented: $appState.showCharlesRules) {
            RuleBackupView(charlesOnly: true)
        }
        .sheet(isPresented: $appState.showColumnEditor) {
            CustomizeTrafficColumnsView()
        }
        .sheet(isPresented: $appState.showLatencyEditor) {
            LatencyConditionsView()
        }
        .sheet(isPresented: $appState.showFactoryReset) { FactoryResetView() }
        .sheet(isPresented: $appState.showGistPublish) { GistPublishView(transactions: store.selectedTransactions) }
        .sheet(item: Binding(get: { appState.certificateGuide.map(GuidePlatformBox.init(value:)) },
                             set: { appState.certificateGuide = $0?.value })) {
            CertificateGuideSheet(platform: $0.value)
        }
        .sheet(isPresented: $appState.showResetCA) {
            ResetCAConfirmView { appState.showResetCA = false }
        }
    }

    @ViewBuilder
    private func workspace(_ store: TrafficStore, dockRight: Bool) -> some View {
        if dockRight {
            HSplitView {
                TrafficListView(store: store).frame(minWidth: 245)
                DetailView(store: store).frame(minWidth: 400)
            }
        } else {
            CaptureDetailSplit(store: store)
        }
    }

    private var workspaceTabs: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(appState.tabs.enumerated()), id: \.element.id) { index, view in
                        HStack(spacing: 5) {
                            Button(view.archiveName ?? "视图 \(index + 1)") { appState.selectWorkspace(index) }
                                .buttonStyle(.plain)
                            if appState.tabs.count > 1 {
                                Button { appState.closeWorkspace(index) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                    .buttonStyle(.borderless).accessibilityLabel("关闭视图 \(index + 1)")
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(appState.activeTab === view ? Color.accentColor.opacity(0.16) : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            Button { appState.addWorkspace() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless).help("新建视图").accessibilityLabel("新建视图")
            Button { appState.toggleSplit() } label: { Image(systemName: "rectangle.split.2x1") }
                .buttonStyle(.borderless).help("切换分屏").accessibilityLabel("切换分屏")
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(ProxymanTheme.topBarBackground)
    }

    private func splitPane(_ store: TrafficStore, right: Bool) -> some View {
        VStack(spacing: 0) {
            Button {
                appState.focusSplit(right)
            } label: {
                HStack {
                    Text(right ? "右侧视图" : "左侧视图")
                    Spacer()
                    if appState.splitFocused == right { Image(systemName: "circle.inset.filled") }
                }
                .font(.caption)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .background(appState.splitFocused == right ? Color.accentColor.opacity(0.12) : .clear)
            }
            .buttonStyle(.plain)
            workspace(store, dockRight: appState.dockRight)
                .id(store.id)
                .simultaneousGesture(TapGesture().onEnded { appState.focusSplit(right) })
        }
        .frame(minWidth: 270)
    }

    private var isRecording: Bool { appState.proxyRunning && appState.recordingEnabled }
    private var recordAction: String {
        if !appState.proxyRunning { return "开始录制" }
        return isRecording ? "暂停录制" : "恢复录制"
    }

    private var isRoutingTraffic: Bool {
        appState.systemProxyActive || appState.transparentProxyState == .running
    }

    private var listenStatus: String {
        guard appState.proxyRunning else { return "ProxyMirror | 监听已停止" }
        let mode = appState.systemProxyBusy ? " | macOS 代理切换中" : (isRoutingTraffic ? "" : " | 仅监听")
        return "ProxyMirror | 正在监听 \(ProxyEngine.shared.listenAddress)" + mode + (isRecording ? "" : " | 暂停")
    }

    @ToolbarContentBuilder
    private var mainToolbar: some CustomizableToolbarContent {
        ToolbarItem(id: "record", placement: .navigation) {
            Button(action: appState.toggleRecording) {
                Image(systemName: isRecording ? "pause.fill" : "record.circle")
                    .foregroundStyle(isRecording ? Color.secondary : Color.red)
                    .frame(width: 30)
            }
            .help(recordAction)
            .accessibilityLabel(recordAction)
        }
        ToolbarItem(id: "compose", placement: .navigation) {
            Button { appState.openTool(.compose) } label: {
                Image(systemName: "square.and.pencil").frame(width: 30)
            }
            .help("构建请求 ⌥⌘N")
            .accessibilityLabel("构建请求")
        }
        ToolbarItem(id: "clear", placement: .navigation) {
            Button(action: appState.clearTraffic) {
                Image(systemName: "trash").frame(width: 30)
            }
            .help("清除所有请求")
            .accessibilityLabel("清除")
        }

        ToolbarItem(id: "listen-status", placement: .principal) {
            Button {
                showListenDetails.toggle()
            } label: {
                HStack(spacing: 5) {
                    let color: Color = isRecording && isRoutingTraffic ? .green : (appState.proxyRunning ? .orange : .secondary)
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                        .padding(2)
                        .background(color.opacity(0.22), in: Circle())
                    Text(listenStatus)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("显示代理详细信息")
            .accessibilityIdentifier("proxy-status")
            .popover(isPresented: $showListenDetails, arrowEdge: .bottom) {
                ProxyStatusPopover()
            }
        }

        ToolbarItem(id: "right-space", placement: .primaryAction) {
            Spacer()
        }
        ToolbarItem(id: "system-proxy", placement: .primaryAction) {
            Button(action: toggleSystemProxy) {
                Label("系统代理", systemImage: appState.systemProxyActive ? "globe.badge.chevron.backward" : "globe")
            }
            .help(appState.systemProxyActive ? "恢复系统代理" : "接管系统代理")
            .disabled(appState.systemProxyBusy)
        }
        ToolbarItem(id: "command-palette", placement: .primaryAction) {
            Button { appState.showCommandPalette = true } label: {
                Label("命令面板", systemImage: "command")
            }
            .help("命令面板 ⌘P")
        }
        ToolbarItem(id: "split", placement: .primaryAction) {
            Button(action: appState.toggleSplit) {
                Label("切换分屏", systemImage: "rectangle.split.2x1")
                    .foregroundStyle(appState.splitStore != nil ? Color.accentColor : Color.secondary)
            }
            .help("切换分屏")
        }
        ToolbarItem(id: "detach-details", placement: .primaryAction) {
            Button {
                if let id = store.selectedID {
                    openWindow(id: "request-detail", value: "\(store.id.uuidString):\(id.uuidString)")
                }
            } label: {
                Label("分离面板", systemImage: "macwindow.on.rectangle")
            }
            .disabled(store.selectedID == nil)
            .help("分离面板")
        }
        ToolbarItem(id: "dock", placement: .primaryAction) {
            HStack(spacing: 13) {
                dockButton("详情停靠在底部", icon: "rectangle.bottomthird.inset.filled", right: false)
                dockButton("详情停靠在右侧", icon: "rectangle.righthalf.inset.filled", right: true)
            }
        }
    }

    private func dockButton(_ title: String, icon: String, right: Bool) -> some View {
        Button { appState.dockRight = right } label: {
            Image(systemName: icon)
                .foregroundStyle(appState.dockRight == right ? Color.accentColor : Color.secondary)
                .frame(width: 21, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(appState.dockRight == right ? .isSelected : [])
    }

    private func toggleSystemProxy() {
        if appState.systemProxyActive { appState.stopSystemProxy() } else { appState.startSystemProxy() }
    }

    private var bottomStatusBar: some View {
        HStack(spacing: 7) {
            Button(action: appState.clearTraffic) { Label("清除", systemImage: "trash") }
                .buttonStyle(FooterButtonStyle())
            Button { showFilterEditor = true } label: {
                let count = store.filter.conditions.conditionCount
                Label(count == 0 ? "过滤器" : "过滤器（\(count)）", systemImage: "line.3.horizontal.decrease")
            }
            .buttonStyle(FooterButtonStyle())
            Button {
                store.followLatest.toggle()
            } label: {
                Text("自动选择").frame(minWidth: 76)
            }
            .buttonStyle(FooterButtonStyle(selected: store.followLatest))
            .accessibilityAddTraits(store.followLatest ? .isSelected : [])

            if showTrafficSearch || !store.filter.searchText.isEmpty {
                TextField("过滤 (⌘F)", text: Binding(
                    get: { store.filter.searchText },
                    set: { store.filter.searchText = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .focused($trafficFilterFocused)
                    .controlSize(.small)
                    .frame(minWidth: 75, idealWidth: 150, maxWidth: 180)
                    .onExitCommand {
                        store.filter.searchText = ""
                        showTrafficSearch = false
                    }
            }
            Spacer(minLength: 6)
            Text("\(store.selectedIDs.count)/\(store.visible.count)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).help("所选 / 当前过滤后的请求数")
            if showResourceUsage {
                ResourceUsageView(store: appState.store).lineLimit(1).minimumScaleFactor(0.85)
            } else {
                let counts = transferred()
                Text("↑ \(counts.request) ↓ \(counts.response)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(appState.systemProxyActive ? "代理已覆盖" : listenFooter)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(ProxymanTheme.controlBackground.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
        }
        .font(.system(size: 12))
        .padding(.horizontal, 7)
        .frame(height: ProxymanTheme.bottomBarHeight)
        .background(ProxymanTheme.inspectorChrome)
        .overlay(alignment: .top) { Rectangle().fill(ProxymanTheme.paneDivider).frame(height: 1) }
    }

    private var listenFooter: String {
        if !appState.proxyRunning { return "监听已停止" }
        return isRecording ? "录制中" : "录制已暂停"
    }

    private func transferred() -> (request: String, response: String) {
        let bytes = store.transferredBytes
        return (ByteCountFormatter.string(fromByteCount: bytes.request, countStyle: .file),
                ByteCountFormatter.string(fromByteCount: bytes.response, countStyle: .file))
    }
}

private struct CaptureDetailSplit: View {
    @ObservedObject var store: TrafficStore
    @State private var detailSplit: CGFloat = 0.51

    var body: some View {
        GeometryReader { geometry in
            let height = max(1, geometry.size.height - 1)
            let minimumTop: CGFloat = 120
            let maximumTop = max(minimumTop, height - 160)
            let top = min(max(height * detailSplit, minimumTop), maximumTop)
            VStack(spacing: 0) {
                TrafficListView(store: store).frame(height: top)
                Rectangle()
                    .fill(ProxymanTheme.paneDivider)
                    .frame(height: 1)
                    .overlay {
                        CaptureDetailDivider { offset in
                            detailSplit = min(max(top + offset, minimumTop), maximumTop) / height
                        }
                        .frame(height: 9)
                    }
                    .accessibilityRepresentation {
                        Slider(value: Binding(
                            get: { top / height },
                            set: { detailSplit = $0 }
                        ), in: (minimumTop / height)...(maximumTop / height))
                            .accessibilityLabel("调整详情面板高度")
                    }
                    .zIndex(1)
                DetailView(store: store).frame(maxHeight: .infinity)
            }
        }
    }
}

private struct CaptureDetailDivider: NSViewRepresentable {
    var onDrag: (CGFloat) -> Void

    func makeNSView(context: Context) -> DividerView {
        let view = DividerView()
        view.onDrag = onDrag
        return view
    }

    func updateNSView(_ view: DividerView, context: Context) {
        view.onDrag = onDrag
    }

    final class DividerView: NSView {
        var onDrag: ((CGFloat) -> Void)?
        private var drag: (startY: CGFloat, update: (CGFloat) -> Void)?

        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds.intersection(visibleRect), cursor: .resizeUpDown)
        }

        override func mouseDown(with event: NSEvent) {
            guard let onDrag else { return }
            drag = (event.locationInWindow.y, onDrag)
            NSCursor.resizeUpDown.set()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let drag else { return }
            NSCursor.resizeUpDown.set()
            drag.update(drag.startY - event.locationInWindow.y)
        }

        override func mouseUp(with event: NSEvent) {
            drag = nil
            let location = convert(event.locationInWindow, from: nil)
            let cursor = bounds.contains(location) ? NSCursor.resizeUpDown : NSCursor.arrow
            cursor.set()
        }
    }
}

private struct FooterButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(ProxymanTheme.controlBackground.opacity(selected ? 1 : 0.78),
                        in: RoundedRectangle(cornerRadius: 4))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct CommentEditor: View {
    let targets: [Transaction]
    let store: TrafficStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("编辑 \(targets.count) 条请求的备注").font(.headline)
            TextEditor(text: $draft).accessibilityLabel("备注")
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    for tx in targets { tx.comment = draft }
                    store.update(targets)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 460, height: 220)
        .onAppear { if targets.count == 1 { draft = targets[0].comment } }
    }
}

private struct CommandPalette: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    private let windows = ["Diff 流量对比": "traffic-diff", "Scripting 脚本与 Console": "scripting", "断点队列与模板": "breakpoints",
        "Protobuf Schema 与映射": "protobuf", "流量汇总": "flow-summary", "自定义 Previewer 预览器": "custom-previewers",
        "Automation 自动化": "automation", "规则文件夹": "rule-folders", "软件更新": "updates"]

    var body: some View {
        VStack(spacing: 10) {
            TextField("搜索工具", text: $search).textFieldStyle(.roundedBorder)
            List {
                ForEach(ToolKind.allCases.filter { search.isEmpty || $0.rawValue.localizedCaseInsensitiveContains(search) }) { tool in
                    Button(tool.rawValue) {
                        dismiss()
                        DispatchQueue.main.async { appState.openTool(tool) }
                    }
                }
                ForEach(windows.keys.sorted().filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { title in
                    Button(title) {
                        dismiss()
                        if let id = windows[title] { DispatchQueue.main.async { openWindow(id: id) } }
                    }
                }
            }
            Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(width: 400, height: 320)
    }
}
