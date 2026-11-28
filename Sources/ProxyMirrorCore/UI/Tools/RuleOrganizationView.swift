import SwiftUI

struct ToolsEnableMenu: View {
    @State private var revision = UUID()
    @State private var onlyEnabled = false
    var body: some View {
        Menu(Strings.Tools.enableDisableTools) {
            Toggle(Strings.Tools.showEnabledToolsOnly, isOn: $onlyEnabled)
            Divider()
            ForEach(RuleBackup.Section.allCases.filter { $0 != .settings && $0 != .organization && $0 != .h2c }, id: \.self) { tool in
                if !onlyEnabled || RuleOrganizationStore.shared.isEnabled(tool.rawValue) {
                    Toggle(tool.title, isOn: Binding(get: { RuleOrganizationStore.shared.isEnabled(tool.rawValue) }, set: { value in
                        do { try RuleOrganizationStore.shared.setEnabled(value, tool: tool.rawValue); revision = UUID() }
                        catch { AppState.shared.systemProxyMessage = LocalizedErrorPresentation.message(for: error) }
                    }))
                    .keyboardShortcut(toolShortcut(tool), modifiers: [.control, .option, .command])
                }
            }
        }
        .id(revision)
        .onReceive(NotificationCenter.default.publisher(for: .ruleOrganizationChanged)) { _ in revision = UUID() }
    }
    private func toolShortcut(_ tool: RuleBackup.Section) -> KeyEquivalent {
        let key: Character
        switch tool {
        case .mapLocal: key = "l"
        case .mapRemote: key = "r"
        case .blockList: key = "b"
        case .allowList: key = "a"
        case .sslProxyingList: key = "p"
        case .sslApplications: key = "i"
        case .customCertificates: key = "c"
        case .dns: key = "d"
        case .breakpoints: key = "k"
        case .rewrite: key = "s"
        case .latency: key = "j"
        case .noCaching: key = "n"
        case .reverse: key = "v"
        case .external: key = "e"
        case .protobuf: key = "u"
        case .h2c: key = "h"
        case .settings, .organization: key = "x"
        }
        return KeyEquivalent(key)
    }

}

/// The same folder tree is used by UI, CLI and MCP and is included in rule backups.
struct RuleOrganizationView: View {
    @State private var tool = RuleBackup.Section.mapLocal
    @State private var state = RuleOrganizationStore.shared.snapshot()
    @State private var selected: UUID?
    @State private var folderName = ""
    @State private var error: String?
    private var folders: [RuleFolder] { state.folders.filter { $0.tool == tool.rawValue } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(Strings.Tools.tools, selection: $tool) {
                ForEach(RuleBackup.Section.allCases.filter { ![.settings, .noCaching, .organization, .external, .h2c].contains($0) }, id: \.self) { Text($0.title).tag($0) }
            }.onChange(of: tool) { _ in selected = nil }
            Toggle(Strings.Tools.enableThisTool, isOn: Binding(get: { !state.disabledTools.contains(tool.rawValue) }, set: { enabled in
                perform { try RuleOrganizationStore.shared.setEnabled(enabled, tool: tool.rawValue) }
            }))
            HSplitView {
                VStack(alignment: .leading) {
                    Text(Strings.Tools.folder).font(.headline)
                    List(selection: $selected) {
                        ForEach(orderedFolders(parent: nil), id: \.folder.id) { entry in
                            Text(String(repeating: "　", count: entry.depth) + (entry.folder.enabled == false ? "○ " : "📁 ") + entry.folder.name)
                                .tag(entry.folder.id)
                        }
                    }
                    TextField(Strings.Tools.folderName, text: $folderName)
                    HStack {
                        Button(Strings.Tools.new2) { perform { _ = try RuleOrganizationStore.shared.createFolder(tool: tool.rawValue, name: folderName) } }
                        Button(Strings.Tools.newSubfolder) { perform { _ = try RuleOrganizationStore.shared.createFolder(tool: tool.rawValue, name: folderName, parentID: selected) } }.disabled(selected == nil)
                    }.disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    HStack {
                        Button(Strings.Tools.rename) { if let selected { perform { try RuleOrganizationStore.shared.renameFolder(id: selected, name: folderName) } } }.disabled(selected == nil || folderName.isEmpty)
                        Button(Strings.Tools.enableDisable) {
                            if let folder = folders.first(where: { $0.id == selected }) {
                                perform { try RuleOrganizationStore.shared.setFolderEnabled(id: folder.id, enabled: folder.enabled == false) }
                            }
                        }.disabled(selected == nil)
                        Button(Strings.Tools.delete, role: .destructive) { if let selected { perform { try RuleOrganizationStore.shared.deleteFolder(id: selected) }; self.selected = nil } }.disabled(selected == nil)
                    }
                }.frame(minWidth: 260)
                VStack(alignment: .leading) {
                    Text(Strings.Tools.ruleMembership).font(.headline)
                    List {
                        ForEach(ruleRows, id: \.id) { row in
                            HStack {
                                Text(row.title).lineLimit(2)
                                Spacer()
                                Picker(Strings.Tools.folder, selection: Binding(get: { state.assignments[tool.rawValue + ":" + row.id] ?? "" }, set: { folder in
                                    perform { try RuleOrganizationStore.shared.assign(ruleID: row.id, tool: tool.rawValue, folderID: UUID(uuidString: folder)) }
                                })) {
                                    Text(Strings.Tools.ungrouped).tag("")
                                    ForEach(orderedFolders(parent: nil), id: \.folder.id) { entry in
                                        Text(String(repeating: "　", count: entry.depth) + entry.folder.name).tag(entry.folder.id.uuidString)
                                    }
                                }.labelsHidden().frame(width: 180)
                            }
                        }
                        if ruleRows.isEmpty { Text(Strings.Tools.thisToolHasNoRulesYetAddARule).foregroundStyle(.secondary) }
                    }
                }.frame(minWidth: 380)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Text(Strings.Tools.disablingAFolderAlsoDisablesRulesInItsSubfolders).font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(minWidth: 760, minHeight: 480)
        .onReceive(NotificationCenter.default.publisher(for: .ruleOrganizationChanged)) { _ in state = RuleOrganizationStore.shared.snapshot() }
    }
    private struct Row { let id: String; let title: String }
    private var ruleRows: [Row] {
        let backup = RulesStore.shared.backup()
        func classic(_ rules: [ProxyRule]?) -> [Row] { (rules ?? []).map { Row(id: $0.id.uuidString, title: $0.comment.isEmpty ? $0.pattern : $0.comment) } }
        switch tool {
        case .mapLocal: return classic(backup.mapLocal)
        case .mapRemote: return classic(backup.mapRemote)
        case .blockList: return classic(backup.blockList)
        case .allowList: return classic(backup.allowList)
        case .sslProxyingList: return classic(backup.sslProxyingList)
        case .sslApplications: return (backup.sslApplications ?? []).map { Row(id: $0.id, title: $0.name.isEmpty ? $0.bundleID : $0.name) }
        case .customCertificates: return (backup.customCertificates ?? []).map { Row(id: $0.id.uuidString, title: $0.hostPattern) }
        case .dns: return (backup.dns ?? []).map { Row(id: $0.id.uuidString, title: $0.hostPattern) }
        case .breakpoints: return (backup.breakpoints ?? []).map { Row(id: $0.id.uuidString, title: $0.rule.name.isEmpty ? $0.rule.summary : $0.rule.name) }
        case .rewrite: return (backup.rewrite ?? []).flatMap { $0.rules.map { Row(id: $0.id.uuidString, title: $0.rule.name.isEmpty ? $0.rule.summary : $0.rule.name) } }
        case .latency: return (backup.latency?.rules ?? []).map { Row(id: $0.id.uuidString, title: $0.name) }
        case .reverse: return (backup.reverse ?? []).map { Row(id: $0.id.uuidString, title: $0.name) }
        case .protobuf: return (backup.protobuf?.rules ?? []).map { Row(id: $0.id.uuidString, title: $0.name) }
        default: return []
        }
    }
    private func orderedFolders(parent: UUID?, depth: Int = 0) -> [(folder: RuleFolder, depth: Int)] {
        guard depth < 32 else { return [] }
        return folders.filter { $0.parentID == parent }.sorted { $0.name < $1.name }.flatMap {
            [($0, depth)] + orderedFolders(parent: $0.id, depth: depth + 1)
        }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); state = RuleOrganizationStore.shared.snapshot(); error = nil }
        catch { self.error = LocalizedErrorPresentation.message(for: error) }
    }
}
