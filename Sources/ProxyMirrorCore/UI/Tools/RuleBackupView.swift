import SwiftUI
import UniformTypeIdentifiers

struct RuleBackupView: View {
    var charlesOnly = false
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var backup: RuleBackup?
    @State private var charlesRules: CharlesImport.Rules?
    @State private var previewBase: RuleBackup?
    @State private var unknown: [String] = []
    @State private var notes: [String] = []
    @State private var mode = RuleBackup.ImportMode.merge
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(charlesOnly ? Strings.Tools.importRulesFromCharles : Strings.Tools.ruleAndSettingsBackup).font(.headline)
            HStack {
                Button(charlesOnly ? Strings.Tools.chooseCharlesXml : Strings.Tools.openBackup, action: choose)
                Spacer()
                if !charlesOnly {
                    Menu(Strings.Tools.export2) {
                        Button(Strings.Tools.rulesSettings) { export(nil) }
                        ForEach(RuleBackup.Section.allCases) { section in
                            Button(section.title) { export(section) }
                        }
                    }
                }
            }
            if let backup, let previewBase {
                if !charlesOnly {
                    Picker(Strings.Tools.importMode, selection: $mode) {
                        Text(Strings.Tools.mergeByRuleId).tag(RuleBackup.ImportMode.merge)
                        Text(Strings.Tools.replaceToolsIncludedInTheFile).tag(RuleBackup.ImportMode.replace)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        if let counts = charlesRules?.counts {
                            Text(Strings.Tools.charlesRuleSummary(counts.rewrite, counts.mapLocal, counts.blockList))
                            Text(Strings.Tools.mergeIntoCurrentRulesMapLocalUsesFilesOn)
                        }
                        ForEach(backup.changes(from: previewBase, mode: mode)) { change in
                            let order = change.reordered ? Strings.Tools.reordered : ""
                            let configuration = change.configurationChanged == true ? Strings.Tools.globalSwitchChanged : ""
                            Text(Strings.Tools.backupChangeSummary(String(describing: (change.section.title)), change.added, change.updated, change.removed, change.unchanged, String(describing: order), String(describing: configuration)))
                        }
                        if backup.settings != nil {
                            Text(Strings.Tools.applicationSettingsTakeEffectAtTheNextLaunchOr)
                        }
                        if !unknown.isEmpty {
                            Text(Strings.Tools.unmappedFields1(String(describing: unknown.joined(separator: ", "))))
                        }
                        ForEach(notes.indices, id: \.self) { Text(notes[$0]) }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            } else {
                Text(charlesOnly
                     ? Strings.Tools.chooseACharlesXmlExportContainingRewriteMapLocal
                     : Strings.Tools.supportsBackupsFromTheCurrentVersionOfProxymirrorMap)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Divider()
            HStack {
                Spacer()
                Button(Strings.Tools.close) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(Strings.Tools.import) { install() }.disabled(backup == nil || charlesRules?.hasRules == false)
            }
        }
        .padding(20)
        .frame(width: 510)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = charlesOnly ? [.xml] : [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if charlesOnly {
                let imported = try CharlesImport.readRules(url)
                charlesRules = imported
                backup = imported.backup
                unknown = []
                notes = imported.skipped.map { Strings.Tools.notImported1(String(describing: $0)) } + imported.notes
            } else {
                let (incoming, unmapped) = try RuleBackup.read(RuleBackup.contents(of: url))
                backup = incoming
                unknown = unmapped
                notes = incoming.migrationNotes()
            }
            previewBase = RuleBackup.snapshot(settings: appState.settings)
            message = nil
        } catch {
            backup = nil
            previewBase = nil
            message = LocalizedErrorPresentation.message(for: error)
        }
    }

    private func export(_ section: RuleBackup.Section?) {
        let file = RuleBackup.snapshot(settings: appState.settings).subset(section)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ProxyMirror Rules.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PrivateAppFile.write(file.exportData(), to: url)
            message = Strings.Tools.exported1(String(describing: url.lastPathComponent))
        } catch {
            message = LocalizedErrorPresentation.message(for: error)
        }
    }

    private func install() {
        guard let backup, let previewBase else { return }
        do {
            let current = RuleBackup.snapshot(settings: appState.settings)
            guard try previewBase.encoded() == current.encoded() else {
                self.previewBase = current
                message = Strings.Tools.rulesOrSettingsHaveChangedReviewTheUpdatedPreview
                return
            }
            try RulesStore.shared.install(backup.resolve(with: current, merge: mode == .merge))
            backup.settings?.apply(to: appState.settings)
            self.backup = nil
            self.previewBase = nil
            self.charlesRules = nil
            message = charlesOnly ? Strings.Tools.charlesRulesImported : Strings.Tools.rulesAndSettingsImported
        } catch {
            message = LocalizedErrorPresentation.message(for: error)
        }
    }
}
