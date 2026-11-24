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
        .onChange(of: appState.systemProxyMessage) { if let text = $0, !appState.systemProxyBusy { message = text } }
        .onChange(of: appState.showDiff) { showing in
            if showing { openWindow(id: "traffic-diff"); appState.showDiff = false }
        }
        .onAppear { if appState.shouldPresentSavedError(store.savedError) { message = store.savedError } }
        .onChange(of: store.savedError) { if appState.shouldPresentSavedError($0) { message = $0 } }
        .alert("ProxyMirror", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button(Strings.Traffic.ok) { message = nil }
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
                            Button(view.archiveName ?? Strings.Traffic.view(index + 1)) { appState.selectWorkspace(index) }
                                .buttonStyle(.plain)
                            if appState.tabs.count > 1 {
                                Button { appState.closeWorkspace(index) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                    .buttonStyle(.borderless).accessibilityLabel(Strings.Traffic.closeView(index + 1))
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(appState.activeTab === view ? Color.accentColor.opacity(0.16) : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            Button { appState.addWorkspace() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless).help(Strings.Traffic.newView).accessibilityLabel(Strings.Traffic.newView)
            Button { appState.toggleSplit() } label: { Image(systemName: "rectangle.split.2x1") }
                .buttonStyle(.borderless).help(Strings.Traffic.toggleSplitView).accessibilityLabel(Strings.Traffic.toggleSplitView)
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
                    Text(right ? Strings.Traffic.rightView : Strings.Traffic.leftView)
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
        if !appState.proxyRunning { return Strings.Traffic.startRecording }
        return isRecording ? Strings.Traffic.pauseRecording : Strings.Traffic.resumeRecording
    }

    private var isRoutingTraffic: Bool {
        appState.systemProxyActive || appState.transparentProxyState == .running
    }

    private var listenStatus: String {
        guard appState.proxyRunning else { return Strings.Traffic.proxymirrorListenerStopped }
        let mode = appState.systemProxyBusy ? Strings.Traffic.switchingMacosProxy : (isRoutingTraffic ? "" : Strings.Traffic.listeningOnly)
        return Strings.Traffic.proxymirrorListeningOn(ProxyEngine.shared.listenAddress) + mode + (isRecording ? "" : Strings.Traffic.paused)
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
            .help(Strings.Traffic.composeRequestN)
            .accessibilityLabel(Strings.Traffic.composeRequest)
        }
        ToolbarItem(id: "clear", placement: .navigation) {
            Button(action: appState.clearTraffic) {
                Image(systemName: "trash").frame(width: 30)
            }
            .help(Strings.Traffic.clearAllRequests)
            .accessibilityLabel(Strings.Traffic.clear)
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
            .help(Strings.Traffic.showProxyDetails)
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
                Label(Strings.Traffic.systemProxy, systemImage: appState.systemProxyActive ? "globe.badge.chevron.backward" : "globe")
            }
            .help(appState.systemProxyActive ? Strings.Traffic.restoreSystemProxy : Strings.Traffic.setAsSystemProxy)
            .disabled(appState.systemProxyBusy)
        }
        ToolbarItem(id: "command-palette", placement: .primaryAction) {
            Button { appState.showCommandPalette = true } label: {
                Label(Strings.Traffic.commandPalette, systemImage: "command")
            }
            .help(Strings.Traffic.commandPaletteP)
        }
        ToolbarItem(id: "split", placement: .primaryAction) {
            Button(action: appState.toggleSplit) {
                Label(Strings.Traffic.toggleSplitView, systemImage: "rectangle.split.2x1")
                    .foregroundStyle(appState.splitStore != nil ? Color.accentColor : Color.secondary)
            }
            .help(Strings.Traffic.toggleSplitView)
        }
        ToolbarItem(id: "detach-details", placement: .primaryAction) {
            Button {
                if let id = store.selectedID {
                    openWindow(id: "request-detail", value: "\(store.id.uuidString):\(id.uuidString)")
                }
            } label: {
                Label(Strings.Traffic.detachPanel, systemImage: "macwindow.on.rectangle")
            }
            .disabled(store.selectedID == nil)
            .help(Strings.Traffic.detachPanel)
        }
        ToolbarItem(id: "dock", placement: .primaryAction) {
            HStack(spacing: 13) {
                dockButton(Strings.Traffic.dockInspectorAtBottom, icon: "rectangle.bottomthird.inset.filled", right: false)
                dockButton(Strings.Traffic.dockInspectorOnRight, icon: "rectangle.righthalf.inset.filled", right: true)
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
            Button(action: appState.clearTraffic) { Label(Strings.Traffic.clear, systemImage: "trash") }
                .buttonStyle(FooterButtonStyle())
            Button { showFilterEditor = true } label: {
                let count = store.filter.conditions.conditionCount
                Label(count == 0 ? Strings.Traffic.filters2 : Strings.Traffic.filters(count), systemImage: "line.3.horizontal.decrease")
            }
            .buttonStyle(FooterButtonStyle())
            Button {
                store.followLatest.toggle()
            } label: {
                Text(Strings.Traffic.autoSelect).frame(minWidth: 76)
            }
            .buttonStyle(FooterButtonStyle(selected: store.followLatest))
            .accessibilityAddTraits(store.followLatest ? .isSelected : [])

            if showTrafficSearch || !store.filter.searchText.isEmpty {
                TextField(Strings.Traffic.filterF, text: Binding(
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
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).help(Strings.Traffic.selectedCurrentlyFilteredRequests)
            if showResourceUsage {
                ResourceUsageView(store: appState.store).lineLimit(1).minimumScaleFactor(0.85)
            } else {
                let counts = transferred()
                Text("↑ \(counts.request) ↓ \(counts.response)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(appState.systemProxyActive ? Strings.Traffic.systemProxyEnabled : listenFooter)
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
        if !appState.proxyRunning { return Strings.Traffic.listenerStopped }
        return isRecording ? Strings.Traffic.recording : Strings.Traffic.recordingPaused
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
                            .accessibilityLabel(Strings.Traffic.resizeInspectorHeight)
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
            Text(Strings.Traffic.editCommentsForRequests(targets.count)).font(.headline)
            TextEditor(text: $draft).accessibilityLabel(Strings.Traffic.comment)
            HStack {
                Spacer()
                Button(Strings.Traffic.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(Strings.Traffic.save) {
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
    private struct WindowCommand: Identifiable {
        let id: String
        let title: String
        let titleKey: String

        var searchAliases: [String] {
            [id, title] + ["en", "zh-Hans"].map {
                L10n.render(table: "Traffic", key: titleKey, arguments: [], englishFallback: title, language: $0)
            }
        }
    }

    private var windows: [WindowCommand] {
        [
            WindowCommand(id: "traffic-diff", title: Strings.Traffic.trafficComparison, titleKey: "traffic_comparison"),
            WindowCommand(id: "scripting", title: Strings.Traffic.scriptingAndConsole, titleKey: "scripting_and_console"),
            WindowCommand(id: "breakpoints", title: Strings.Traffic.breakpointQueueAndTemplates, titleKey: "breakpoint_queue_and_templates"),
            WindowCommand(id: "protobuf", title: Strings.Traffic.protobufSchemaAndMappings, titleKey: "protobuf_schema_and_mappings"),
            WindowCommand(id: "flow-summary", title: Strings.Traffic.trafficSummary, titleKey: "traffic_summary"),
            WindowCommand(id: "custom-previewers", title: Strings.Traffic.customPreviewers, titleKey: "custom_previewers"),
            WindowCommand(id: "automation", title: Strings.Traffic.automation, titleKey: "automation"),
            WindowCommand(id: "rule-folders", title: Strings.Traffic.ruleFolders, titleKey: "rule_folders"),
            WindowCommand(id: "updates", title: Strings.Traffic.softwareUpdates, titleKey: "software_updates")
        ]
    }

    private func matchesSearch(_ aliases: [String]) -> Bool {
        let terms = search.split(whereSeparator: \.isWhitespace)
        return terms.allSatisfy { term in aliases.contains { $0.localizedCaseInsensitiveContains(term) } }
    }

    var body: some View {
        VStack(spacing: 10) {
            TextField(Strings.Traffic.searchTools, text: $search).textFieldStyle(.roundedBorder)
            List {
                ForEach(ToolKind.allCases.filter { matchesSearch($0.searchAliases) }) { tool in
                    Button(tool.localizedTitle) {
                        dismiss()
                        DispatchQueue.main.async { appState.openTool(tool) }
                    }
                }
                ForEach(windows.filter { matchesSearch($0.searchAliases) }) { command in
                    Button(command.title) {
                        dismiss()
                        DispatchQueue.main.async { openWindow(id: command.id) }
                    }
                }
            }
            Button(Strings.Traffic.close) { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(minWidth: 440, minHeight: 320)
    }
}
