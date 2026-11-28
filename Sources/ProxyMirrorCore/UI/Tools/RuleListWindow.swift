import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 所有列表变更直接进入共享 store；只有单条规则的编辑保留可取消的草稿。
struct RuleListWindow: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.self) private var environment
    @ObservedObject private var store = RulesStore.shared
    let kind: ToolKind
    var initialPattern = ""
    @State private var selection = Set<UUID>()
    @State private var showSSLExclusions = false
    @State private var search = ""
    @State private var showEnabled = false
    @State private var showFilter = false
    @State private var expandedFolders = Set<UUID>()
    @FocusState private var filterFocused: Bool
    @State private var organization = RuleOrganizationStore.shared.snapshot()
    @State private var editing: ProxyRule?
    @State private var folderDraft: RuleFolderDraft?
    @State private var backupSheet = false
    @State private var charlesSheet = false
    @State private var proxymanHelp = false
    @State private var error: String?

    private var tool: String { kind.rawValue }
    private var folders: [RuleFolder] { organization.folders.filter { $0.tool == tool } }
    private var selectedRules: [ProxyRule] { rules.wrappedValue.filter { selection.contains($0.id) } }
    private var canUseRowShortcuts: Bool {
        !showSSLExclusions && !filterFocused && editing == nil && folderDraft == nil && !backupSheet && !charlesSheet && !proxymanHelp
    }
    private var rules: Binding<[ProxyRule]> {
        switch kind {
        case .mapLocal: return $store.mapLocal
        case .mapRemote: return $store.mapRemote
        case .blockList: return $store.blockList
        case .allowList: return $store.allowList
        case .sslProxyingList: return $store.sslProxyingList
        default: return .constant([])
        }
    }
    private var enabled: Binding<Bool> {
        Binding(get: { !organization.disabledTools.contains(tool) }, set: { value in
            perform { try RuleOrganizationStore.shared.setEnabled(value, tool: tool) }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if kind == .sslProxyingList {
                Picker(Strings.Tools.sslProxyingList, selection: $showSSLExclusions) {
                    Text(Strings.Tools.ruleWindowIncludeList).tag(false)
                    Text(Strings.Tools.ruleWindowExcludeList).tag(true)
                }.pickerStyle(.segmented)
            }
            if showSSLExclusions {
                SSLExclusionRulesView()
            } else {
                if showFilter {
                    TextField(Strings.Tools.ruleWindowSearch, text: $search)
                        .textFieldStyle(.roundedBorder).focused($filterFocused)
                        .onExitCommand { search = ""; showFilter = false; filterFocused = false }
                }
                list
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                Text(Strings.Tools.ruleWindowShortcuts).font(.system(size: 11)).foregroundStyle(.secondary)
                toolbar
            }
            if kind == .sslProxyingList {
                Button(Strings.Settings.systemProxyBypass) {
                    appState.settingsTarget = .bypassProxy
                    if #available(macOS 14, *) { environment.openSettings() }
                    else { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
                }.controlSize(.small)
            }
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 840, minHeight: 500, idealHeight: 540)
        .navigationTitle(kind.localizedTitle)
        .background(shortcuts)
        .onAppear {
            if !initialPattern.isEmpty { editing = ProxyRule(pattern: initialPattern) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ruleOrganizationChanged)) { _ in
            organization = RuleOrganizationStore.shared.snapshot()
        }
        .sheet(item: $editing) { draft in
            RuleEntryEditor(kind: kind, draft: draft) { saved in
                var current = rules.wrappedValue
                if let index = current.firstIndex(where: { $0.id == saved.id }) { current[index] = saved }
                else { current.append(saved) }
                replace(current)
                selection = [saved.id]
            }
        }
        .sheet(item: $folderDraft) { draft in
            RuleFolderNameSheet(draft: draft) { name in
                perform {
                    if let id = draft.existingID { try RuleOrganizationStore.shared.renameFolder(id: id, name: name) }
                    else { try RuleOrganizationStore.shared.createFolder(tool: tool, name: name, parentID: draft.parentID) }
                }
            }
        }
        .sheet(isPresented: $backupSheet) { RuleBackupView() }
        .sheet(isPresented: $charlesSheet) { RuleBackupView(charlesOnly: true) }
        .sheet(isPresented: $proxymanHelp) { ProxymanRulesImportGuide() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle(Strings.Tools.ruleWindowEnable(kind.localizedTitle), isOn: enabled)
                .font(.system(size: 13, weight: .semibold)).toggleStyle(.checkbox)
            Text(kind == .sslProxyingList ? Strings.Tools.hostnamesSupportExampleComWildcardsMatchSubdomains :
                    kind == .mapLocal ? Strings.Tools.directoryMappingsFindFilesUsingTheRequestPath :
                    Strings.Tools.theFirstMatchingRuleInListOrderApplies)
                .font(.system(size: 13)).foregroundStyle(.secondary)
            if kind == .blockList || kind == .allowList {
                Text(Strings.Tools.httpsTunnelsAreMatchedByDomainAndPortMatching)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(folders.filter { $0.parentID == nil }) { folder in folderRow(folder) }
            ruleRows(in: nil)
            if rules.wrappedValue.isEmpty && folders.isEmpty {
                Text(Strings.Tools.ruleWindowEmpty).italic().foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .listStyle(.inset)
        .environment(\.defaultMinListRowHeight, 24)
        .overlay(Rectangle().strokeBorder(.quaternary))
        .onMoveCommand { direction in
            if direction == .up { moveSelected(-1) }
            else if direction == .down { moveSelected(1) }
        }
    }

    private func folderRow(_ folder: RuleFolder) -> AnyView {
        AnyView(DisclosureGroup(isExpanded: Binding(
            get: { !search.isEmpty || expandedFolders.contains(folder.id) },
            set: { expanded in
                if expanded { expandedFolders.insert(folder.id) }
                else { expandedFolders.remove(folder.id) }
            })) {
            ForEach(folders.filter { $0.parentID == folder.id }) { child in folderRow(child) }
            ruleRows(in: folder.id)
        } label: {
            HStack(spacing: 8) {
                Toggle(Strings.Tools.enableGroup, isOn: Binding(
                    get: { folder.enabled != false },
                    set: { value in perform { try RuleOrganizationStore.shared.setFolderEnabled(id: folder.id, enabled: value) } }))
                    .labelsHidden().toggleStyle(.checkbox)
                Label(folder.name, systemImage: "folder")
                Spacer()
                Text(String(rules.wrappedValue.filter { folderID($0) == folder.id }.count))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12)).frame(minHeight: 24)
        }
        .tag(folder.id)
        .contextMenu {
            Button(Strings.Tools.ruleWindowRenameFolder) {
                folderDraft = RuleFolderDraft(existingID: folder.id, name: folder.name)
            }
            Button(Strings.Tools.ruleWindowNewFolder) {
                folderDraft = RuleFolderDraft(parentID: folder.id)
            }.disabled(folder.parentID != nil)
            Button(Strings.Tools.removeSelected) {
                perform { try RuleOrganizationStore.shared.deleteFolder(id: folder.id) }
            }
        })
    }

    @ViewBuilder
    private func ruleRows(in folder: UUID?) -> some View {
        let visible = rules.wrappedValue.filter { folderID($0) == folder && matches($0) }
        ForEach(visible) { rule in
            ruleRow(rule).tag(rule.id)
                .contextMenu { ruleContext(rule) }
                .simultaneousGesture(TapGesture(count: 2).onEnded { editing = rule })
        }
        .onMove { offsets, destination in reorder(visible, from: offsets, to: destination) }
    }

    private func ruleRow(_ rule: ProxyRule) -> some View {
        HStack(spacing: 10) {
            Toggle(Strings.Tools.enableRule, isOn: Binding(get: { rule.enabled }, set: { value in
                var current = rules.wrappedValue
                if let index = current.firstIndex(where: { $0.id == rule.id }) { current[index].enabled = value; replace(current) }
            })).labelsHidden().toggleStyle(.checkbox)
            Text(rule.urlRegex.map { "/" + $0 + "/" } ?? (rule.pattern.isEmpty ? "*" : rule.pattern))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(kind == .blockList ? (rule.blockAction ?? .forbidden).localizedTitle : rule.target)
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Text(rule.comment).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced)).lineLimit(1).frame(height: 24)
    }

    @ViewBuilder
    private func ruleContext(_ rule: ProxyRule) -> some View {
        Button(Strings.Tools.ruleWindowNewRule) { editing = ProxyRule(pattern: "") }
        Button(Strings.Tools.edit) { editing = rule }
        Button(Strings.Tools.ruleWindowDuplicate) { duplicate([rule]) }
        Button(rule.enabled ? Strings.Tools.ruleWindowDisableRule : Strings.Tools.enableRule) { toggle([rule.id]) }
        Menu(Strings.Tools.moveToFolder) {
            Button(Strings.Tools.ungrouped) { assign([rule.id], folder: nil) }
            ForEach(folders) { folder in Button(folder.name) { assign([rule.id], folder: folder.id) } }
        }
        Divider()
        Button(Strings.Tools.ruleWindowExportSelected) { export(ids: [rule.id]) }
        imports
        Divider()
        Button(Strings.Tools.removeSelected) { remove([rule.id]) }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { editing = ProxyRule(pattern: "") } label: { Image(systemName: "plus") }
                .help(Strings.Tools.ruleWindowNewRule).keyboardShortcut("n", modifiers: .command)
            Button(action: deleteSelection) { Image(systemName: "minus") }
                .help(Strings.Tools.removeSelected).disabled(selection.isEmpty)
            Button(Strings.Tools.ruleWindowNewFolder) { folderDraft = RuleFolderDraft() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Spacer()
            Toggle(Strings.Tools.ruleWindowShowEnabled, isOn: $showEnabled).toggleStyle(.checkbox)
            Button { showFilter = true; filterFocused = true } label: {
                Label(Strings.Common.search, systemImage: "line.3.horizontal.decrease.circle")
            }.keyboardShortcut("f", modifiers: .command)
            Menu(Strings.Tools.ruleWindowMore) {
                Button(Strings.Tools.ruleWindowExportSettings) { export(ids: nil) }
                Button(Strings.Tools.ruleWindowExportSelected) { export(ids: Set(selectedRules.map(\.id))) }
                    .disabled(selectedRules.isEmpty)
                imports
                Divider()
                Button(Strings.Tools.removeSelected, action: deleteSelection).disabled(selection.isEmpty)
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder private var imports: some View {
        Menu(Strings.Tools.ruleWindowImportSettings) {
            Button(Strings.Tools.ruleWindowFromProxyMirror) { backupSheet = true }
            Button(Strings.Tools.ruleWindowFromProxyman) { proxymanHelp = true }
            Button(Strings.Tools.ruleWindowFromCharles) { charlesSheet = true }
        }
    }

    private var shortcuts: some View {
        HStack {
            Button(Strings.Tools.edit) { editing = selectedRules.first }
                .keyboardShortcut(.return, modifiers: .command).disabled(selectedRules.count != 1 || !canUseRowShortcuts)
            Button(Strings.Tools.removeSelected, action: deleteSelection)
                .keyboardShortcut(.delete, modifiers: .command).disabled(selection.isEmpty || !canUseRowShortcuts)
            Button(Strings.Tools.ruleWindowDuplicate) { duplicate(selectedRules) }
                .keyboardShortcut("d", modifiers: .command).disabled(selectedRules.isEmpty || !canUseRowShortcuts)
            Button(Strings.Tools.enableRule) { toggle(Set(selectedRules.map(\.id))) }
                .keyboardShortcut(.space, modifiers: []).disabled(selectedRules.isEmpty || !canUseRowShortcuts)
        }.hidden().frame(width: 0, height: 0)
    }

    private func matches(_ rule: ProxyRule) -> Bool {
        (!showEnabled || (rule.enabled && organization.ruleIsEnabled(tool: tool, ruleID: rule.id.uuidString))) &&
        (search.isEmpty || [rule.pattern, rule.urlRegex ?? "", rule.target, rule.comment].contains { $0.localizedCaseInsensitiveContains(search) })
    }
    private func folderID(_ rule: ProxyRule) -> UUID? {
        organization.assignments[tool + ":" + rule.id.uuidString].flatMap(UUID.init(uuidString:))
    }
    private func replace(_ replacement: [ProxyRule]) {
        rules.wrappedValue = replacement
        perform { try store.flushPendingSave() }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); organization = RuleOrganizationStore.shared.snapshot(); error = nil }
        catch { self.error = LocalizedErrorPresentation.message(for: error) }
    }
    private func deleteSelection() {
        let selectedFolders = folders.filter { selection.contains($0.id) }
        remove(Set(selectedRules.map(\.id)))
        for folder in selectedFolders {
            // 删除父目录时子目录也会移除；同一选择中的子目录无需再删除。
            if RuleOrganizationStore.shared.folders(tool: tool).contains(where: { $0.id == folder.id }) {
                perform { try RuleOrganizationStore.shared.deleteFolder(id: folder.id) }
            }
        }
        selection.removeAll()
    }

    private func remove(_ ids: Set<UUID>) {
        replace(rules.wrappedValue.filter { !ids.contains($0.id) })
        selection.subtract(ids)
        for id in ids { perform { try RuleOrganizationStore.shared.assign(ruleID: id.uuidString, tool: tool, folderID: nil) } }
    }
    private func duplicate(_ entries: [ProxyRule]) {
        var current = rules.wrappedValue
        var added = Set<UUID>()
        var memberships: [(UUID, UUID)] = []
        for rule in entries {
            var copy = rule; copy.id = UUID()
            if let index = current.firstIndex(where: { $0.id == rule.id }) { current.insert(copy, at: index + 1) }
            else { current.append(copy) }
            added.insert(copy.id)
            if let folder = folderID(rule) { memberships.append((copy.id, folder)) }
        }
        replace(current)
        for (id, folder) in memberships { assign([id], folder: folder) }
        selection = added
    }
    private func toggle(_ ids: Set<UUID>) {
        var current = rules.wrappedValue
        let value = !current.filter { ids.contains($0.id) }.allSatisfy(\.enabled)
        for index in current.indices where ids.contains(current[index].id) { current[index].enabled = value }
        replace(current)
    }
    private func assign(_ ids: Set<UUID>, folder: UUID?) {
        for id in ids { perform { try RuleOrganizationStore.shared.assign(ruleID: id.uuidString, tool: tool, folderID: folder) } }
    }
    private func reorder(_ visible: [ProxyRule], from offsets: IndexSet, to destination: Int) {
        var moved = visible
        moved.move(fromOffsets: offsets, toOffset: destination)
        let ids = Set(visible.map(\.id))
        var current = rules.wrappedValue
        let positions = current.indices.filter { ids.contains(current[$0].id) }
        for (position, rule) in zip(positions, moved) { current[position] = rule }
        replace(current)
    }
    private func moveSelected(_ offset: Int) {
        guard selectedRules.count == 1, let id = selectedRules.first?.id else { return }
        var current = rules.wrappedValue
        guard let index = current.firstIndex(where: { $0.id == id }), current.indices.contains(index + offset) else { return }
        current.swapAt(index, index + offset)
        replace(current)
    }
    private func export(ids: Set<UUID>?) {
        guard let section = RuleBackup.Section(rawValue: tool) else { return }
        var file = store.backup().subset(section)
        if let ids {
            let selected = rules.wrappedValue.filter { ids.contains($0.id) }
            switch kind {
            case .mapLocal: file.mapLocal = selected
            case .mapRemote: file.mapRemote = selected
            case .blockList: file.blockList = selected
            case .allowList: file.allowList = selected
            case .sslProxyingList: file.sslProxyingList = selected
            default: break
            }
            if var metadata = file.organization {
                metadata.assignments = metadata.assignments.filter { key, _ in
                    guard let id = UUID(uuidString: String(key.dropFirst(tool.count + 1))) else { return false }
                    return ids.contains(id)
                }
                file.organization = metadata
            }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ProxyMirror \(kind.rawValue).json"
        if panel.runModal() == .OK, let url = panel.url { perform { try PrivateAppFile.write(file.exportData(), to: url) } }
    }
}

private struct RuleFolderDraft: Identifiable {
    let id = UUID()
    var existingID: UUID?
    var parentID: UUID?
    var name = ""
}

private struct RuleFolderNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let draft: RuleFolderDraft
    let save: (String) -> Void
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.existingID == nil ? Strings.Tools.ruleWindowNewFolder : Strings.Tools.ruleWindowRenameFolder).font(.headline)
            TextField(Strings.Tools.groupName, text: $name)
            HStack {
                Spacer()
                Button(Strings.Common.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(Strings.Common.save) { save(name); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 360).onAppear { name = draft.name }
    }
}

private struct RuleEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    let kind: ToolKind
    @State var draft: ProxyRule
    let save: (ProxyRule) -> Void
    @State private var status = "200"
    @State private var headers = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(kind.localizedTitle).font(.headline)
            TextField(Strings.Tools.patternEGHttpsApiExampleCom, text: $draft.pattern)
            if draft.urlRegex != nil {
                TextField(Strings.Tools.urlRegularExpression, text: Binding(
                    get: { draft.urlRegex ?? "" }, set: { draft.urlRegex = $0 }))
            }
            if kind == .mapLocal {
                HStack {
                    TextField(Strings.Tools.localFilePath, text: $draft.target)
                    Button(Strings.Tools.chooseFile) {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { draft.target = url.path }
                    }
                }
                TextField(Strings.Tools.statusCode, text: $status)
                TextField(Strings.Tools.extraResponseHeadersOnePerLine, text: $headers, axis: .vertical).lineLimit(3...6)
            } else if kind == .mapRemote {
                TextField(Strings.Tools.targetHttpsNewhostBase, text: $draft.target)
            } else if kind == .blockList {
                Picker(Strings.Tools.ruleWindowBlockAction, selection: Binding(get: { draft.blockAction ?? .forbidden }, set: { draft.blockAction = $0 })) {
                    ForEach(RuleBlockAction.allCases, id: \.self) { action in Text(action.localizedTitle).tag(action) }
                }
            }
            TextField(Strings.Tools.ruleWindowComment, text: $draft.comment)
            Toggle(Strings.Tools.enableRule, isOn: $draft.enabled)
            if !valid { Text(Strings.Tools.ruleWindowInvalid).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button(Strings.Common.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(Strings.Common.save) {
                    if kind == .sslProxyingList { draft.pattern = RulesSnapshot.sslHostPattern(draft.pattern) }
                    if kind == .mapLocal { draft.responseStatus = Int(status); draft.responseHeaders = parsedHeaders }
                    save(draft); dismiss()
                }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .textFieldStyle(.roundedBorder).padding(20).frame(width: 620)
        .onAppear {
            status = String(draft.responseStatus ?? 200)
            headers = draft.responseHeaders?.pairs.map { "\($0.name): \($0.value)" }.joined(separator: "\n") ?? ""
        }
    }
    private var valid: Bool {
        guard !draft.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let regex = draft.urlRegex {
            guard !regex.isEmpty, regex.utf8.count <= 8192, URLRule.regexCache(regex) != nil else { return false }
        }
        switch kind {
        case .mapLocal:
            return FileManager.default.isReadableFile(atPath: draft.target) &&
                Int(status).map { (200...599).contains($0) } == true && parsedHeaders != nil
        case .mapRemote: return RulesSnapshot(mapRemote: [draft]).mapRemoteTarget(for: "http://example.invalid/") != nil
        default: return true
        }
    }
    private var parsedHeaders: HTTPHeaders? {
        ComposeService.parse("GET http://localhost/ HTTP/1.1\n" + headers.split(whereSeparator: \.isNewline).joined(separator: "\n"))
            .map { HTTPHeaders($0.headers) }
    }
}

struct ProxymanRulesImportGuide: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Strings.Tools.ruleWindowFromProxyman).font(.headline)
            Text(Strings.Tools.ruleWindowProxymanImportHelp).textSelection(.enabled)
            Link(Strings.Tools.ruleWindowOfficialDocs, destination: URL(string: "https://proxyman.com/docs/basic-features/import-export-settings")!)
            HStack { Spacer(); Button(Strings.Common.close) { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 500)
    }
}

extension RuleBlockAction {
    var localizedTitle: String {
        switch self {
        case .forbidden: return "403 Forbidden"
        case .serviceUnavailable: return "503 Service Unavailable"
        case .tooManyRequests: return "429 Too Many Requests"
        case .disconnect: return Strings.Tools.ruleWindowDisconnect
        }
    }
}

/// 排除列表复用已存在的HTTPS旁路设置，更新后立即同步引擎，避免建立第二份排除规则。
private struct SSLExclusionRulesView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settings = AppSettings.shared
    @State private var selection = Set<String>()
    @State private var search = ""
    @State private var editing: SSLExcludedHostDraft?

    private var hosts: [String] { settings.mitmExcludedHosts }
    private var visibleHosts: [String] { Array(Set(hosts)).sorted().filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Strings.Settings.hostsExcludedFromDecryptionOnePerLineExample).font(.caption).foregroundStyle(.secondary)
            TextField(Strings.Tools.ruleWindowSearch, text: $search).textFieldStyle(.roundedBorder)
            List(selection: $selection) {
                ForEach(visibleHosts, id: \.self) { host in
                    Text(host).font(.system(size: 12, design: .monospaced)).frame(height: 24).tag(host)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { editing = SSLExcludedHostDraft(original: host, value: host) })
                        .contextMenu {
                            Button(Strings.Common.edit) { editing = SSLExcludedHostDraft(original: host, value: host) }
                            Button(Strings.Common.delete) { replace(hosts.filter { $0 != host }) }
                        }
                }
            }.environment(\.defaultMinListRowHeight, 24).overlay(Rectangle().strokeBorder(.quaternary))
            HStack {
                Button { editing = SSLExcludedHostDraft() } label: { Image(systemName: "plus") }
                    .keyboardShortcut("n", modifiers: .command)
                Button { removeSelection() } label: { Image(systemName: "minus") }
                    .keyboardShortcut(.delete, modifiers: .command).disabled(selection.isEmpty)
                Button(Strings.Common.edit) {
                    if let host = selection.first { editing = SSLExcludedHostDraft(original: host, value: host) }
                }.keyboardShortcut(.return, modifiers: .command).disabled(selection.count != 1)
                Spacer()
            }.controlSize(.small)
        }
        .sheet(item: $editing) { draft in
            SSLExcludedHostEditor(draft: draft) { value in
                var replacement = hosts.filter { $0 != draft.original && $0 != value }
                replacement.append(value)
                replace(replacement)
                selection = [value]
            }
        }
    }
    private func replace(_ values: [String]) { appState.setMITMExcludedHosts(values.joined(separator: "\n")) }
    private func removeSelection() {
        replace(hosts.filter { !selection.contains($0) })
        selection.removeAll()
    }
}

private struct SSLExcludedHostDraft: Identifiable {
    let id = UUID()
    var original: String?
    var value = ""
}

private struct SSLExcludedHostEditor: View {
    @Environment(\.dismiss) private var dismiss
    let draft: SSLExcludedHostDraft
    let save: (String) -> Void
    @State private var value = ""
    private var normalized: String { RulesSnapshot.sslHostPattern(value) }
    private var valid: Bool {
        !normalized.isEmpty && normalized.utf8.count <= 1024 &&
            !normalized.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) &&
            !normalized.contains("/") && !normalized.contains("\\")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Strings.Tools.ruleWindowExcludeList).font(.headline)
            TextField(Strings.Tools.hostOrPattern, text: $value).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(Strings.Common.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(Strings.Common.save) { save(normalized); dismiss() }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(20).frame(width: 430).onAppear { value = draft.value }
    }
}
