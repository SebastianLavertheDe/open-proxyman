import SwiftUI
import UniformTypeIdentifiers

struct SSLApplicationRulesView: View {
    @Environment(\.dismiss) private var dismiss
    let transaction: Transaction?

    @State private var rules: [SSLApplicationRule] = []
    @State private var selection: String?
    @State private var bundleID = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("按应用配置 SSL").font(.headline)
            Text("匹配的应用按下表解密或透传。其他来源继续使用域名规则。全局 SSL 开关和排除主机优先。规则应用于新连接。")
                .font(.callout).foregroundStyle(.secondary)

            List(selection: $selection) {
                ForEach($rules) { $rule in
                    HStack(spacing: 12) {
                        Toggle("启用 \(rule.bundleID)", isOn: $rule.enabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rule.name.isEmpty ? rule.bundleID : rule.name)
                            if !rule.name.isEmpty {
                                Text(rule.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Picker("SSL 行为", selection: $rule.action) {
                            ForEach(SSLApplicationRule.Action.allCases, id: \.self) { action in
                                Text(action.title).tag(action)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 136)
                    }
                    .tag(rule.id)
                }
            }
            .overlay {
                if rules.isEmpty {
                    Text("选择本机应用，或输入它的 Bundle ID。").foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }

            HStack {
                Button("选择应用…", action: chooseApplication)
                TextField("Bundle ID", text: $bundleID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTypedApplication)
                Button("添加", action: addTypedApplication).disabled(bundleID.isEmpty)
                Button("移除所选") {
                    rules.removeAll { $0.id == selection }
                    selection = nil
                }
                .disabled(selection == nil)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(16)
        .frame(width: 620, height: 370)
        .onAppear {
            rules = RulesStore.shared.sslApplications
            if let bundleID = transaction?.clientBundle {
                addApplication(bundleID, name: transaction?.clientName ?? "")
            }
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else {
            error = "所选应用没有可用的 Bundle ID。"
            return
        }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        addApplication(identifier, name: name)
    }

    private func addTypedApplication() { addApplication(bundleID, name: "") }

    private func addApplication(_ identifier: String, name: String) {
        let id = SSLApplicationRule.normalize(identifier)
        guard SSLApplicationRule.isValid(id) else { error = "请输入有效的 Bundle ID。"; return }
        if !rules.contains(where: { $0.id == id }) {
            rules.append(SSLApplicationRule(bundleID: id, name: name))
        }
        selection = id
        bundleID = ""
        error = nil
    }

    private func save() {
        if !bundleID.isEmpty {
            addTypedApplication()
            guard error == nil else { return }
        }
        let store = RulesStore.shared
        var backup = store.backup()
        backup.sslApplications = rules
        do { try store.install(backup); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
