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
            Text(charlesOnly ? "从 Charles 导入规则" : "规则与设置备份").font(.headline)
            HStack {
                Button(charlesOnly ? "选择 Charles XML…" : "读取备份…", action: choose)
                Spacer()
                if !charlesOnly {
                    Menu("导出…") {
                        Button("规则与设置") { export(nil) }
                        ForEach(RuleBackup.Section.allCases) { section in
                            Button(section.title) { export(section) }
                        }
                    }
                }
            }
            if let backup, let previewBase {
                if !charlesOnly {
                    Picker("导入方式", selection: $mode) {
                        Text("按规则 ID 合并").tag(RuleBackup.ImportMode.merge)
                        Text("替换文件中包含的工具").tag(RuleBackup.ImportMode.replace)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        if let counts = charlesRules?.counts {
                            Text("Rewrite \(counts.rewrite) · Map Local \(counts.mapLocal) · Block List \(counts.blockList)")
                            Text("合并到当前规则。Map Local 使用此 Mac 上的文件。")
                        }
                        ForEach(backup.changes(from: previewBase, mode: mode)) { change in
                            let order = change.reordered ? " · 调整顺序" : ""
                            let configuration = change.configurationChanged == true ? " · 全局开关变化" : ""
                            Text("\(change.section.title) · 新增 \(change.added) · 覆盖 \(change.updated) · 移除 \(change.removed) · 相同 \(change.unchanged)\(order)\(configuration)")
                        }
                        if backup.settings != nil {
                            Text("应用设置在下次启动时生效，也可前往设置手动应用。")
                        }
                        if !unknown.isEmpty {
                            Text("未映射字段 · \(unknown.joined(separator: "、"))")
                        }
                        ForEach(notes.indices, id: \.self) { Text(notes[$0]) }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            } else {
                Text(charlesOnly
                     ? "选择 Charles 的 Rewrite、Map Local、Block List 或完整设置 XML 导出。"
                     : "支持 ProxyMirror 备份与旧版 rules.json。Map Local 保留文件路径。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Divider()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("导入") { install() }.disabled(backup == nil || charlesRules?.hasRules == false)
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
                notes = imported.skipped.map { "未迁移 · \($0)" } + imported.notes
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
            message = error.localizedDescription
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
            message = "已导出 \(url.lastPathComponent)"
        } catch {
            message = error.localizedDescription
        }
    }

    private func install() {
        guard let backup, let previewBase else { return }
        do {
            let current = RuleBackup.snapshot(settings: appState.settings)
            guard try previewBase.encoded() == current.encoded() else {
                self.previewBase = current
                message = "当前规则或设置已更新，请核对新的预览后再导入。"
                return
            }
            try RulesStore.shared.install(backup.resolve(with: current, merge: mode == .merge))
            backup.settings?.apply(to: appState.settings)
            self.backup = nil
            self.previewBase = nil
            self.charlesRules = nil
            message = charlesOnly ? "已导入 Charles 规则" : "已导入规则与设置"
        } catch {
            message = error.localizedDescription
        }
    }
}
