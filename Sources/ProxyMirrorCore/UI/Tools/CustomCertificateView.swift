import SwiftUI
import UniformTypeIdentifiers

/// G7：按域名自定义服务端证书编辑器
/// MITM 命中域名通配时，直接使用用户指定的证书链 + 私钥应答 TLS 握手（不走动态签发）。
struct CustomCertificateView: View {
    @ObservedObject private var store = RulesStore.shared
    @State private var selection = Set<UUID>()
    @State private var draftHost = ""
    @State private var draftCertPath = ""
    @State private var draftKeyPath = ""
    @State private var editingID: UUID?
    @Environment(\.dismiss) private var dismiss

    private var rules: Binding<[CustomCertificateRule]> {
        Binding(get: { store.customCertificates }, set: { store.customCertificates = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("按域名自定义服务端证书").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("删除") { removeSelected() }.disabled(selection.isEmpty)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)

            List(selection: $selection) {
                ForEach(store.customCertificates) { rule in
                    HStack(spacing: 8) {
                        Toggle("", isOn: bindingEnabled(rule)).toggleStyle(.checkbox).labelsHidden()
                        Text(rule.hostPattern.isEmpty ? "(未填域名)" : rule.hostPattern)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(width: 180, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("证书: \(rule.certificatePath)").lineLimit(1).truncationMode(.middle)
                            Text("私钥: \(rule.privateKeyPath)").lineLimit(1).truncationMode(.middle)
                        }
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Spacer()
                        Button("编辑") { startEdit(rule) }.controlSize(.small)
                            .opacity(editingID == rule.id ? 0.4 : 1)
                    }
                    .tag(rule.id)
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 180)

            Divider()
            editor
            Divider()
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.return, modifiers: .command)
            }
            .padding(10)
        }
        .frame(width: 640, height: 420)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(editingID == nil ? "添加规则" : "更新规则").font(.caption.weight(.semibold))
            HStack(spacing: 8) {
                Text("域名通配").font(.caption).frame(width: 64, alignment: .leading)
                TextField("*.example.com 或 example.com", text: $draftHost)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                Text("证书链").font(.caption).frame(width: 64, alignment: .leading)
                Text(draftCertPath.isEmpty ? "未选择" : draftCertPath)
                    .font(.system(size: 10.5)).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("选择 PEM…") { pickFile { draftCertPath = $0 } }.controlSize(.small)
            }
            HStack(spacing: 8) {
                Text("私钥").font(.caption).frame(width: 64, alignment: .leading)
                Text(draftKeyPath.isEmpty ? "未选择" : draftKeyPath)
                    .font(.system(size: 10.5)).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("选择 PEM…") { pickFile { draftKeyPath = $0 } }.controlSize(.small)
            }
            HStack {
                Button(editingID == nil ? "添加" : "更新规则") { commitDraft() }
                    .disabled(draftHost.trimmingCharacters(in: .whitespaces).isEmpty
                              || draftCertPath.isEmpty || draftKeyPath.isEmpty)
                if editingID != nil { Button("结束编辑") { clearDraft() }.controlSize(.small) }
                Spacer()
                Text("叶子证书需在前，后跟中间证书。").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func bindingEnabled(_ rule: CustomCertificateRule) -> Binding<Bool> {
        Binding(get: { rule.enabled }, set: { newValue in
            if let index = store.customCertificates.firstIndex(where: { $0.id == rule.id }) {
                store.customCertificates[index].enabled = newValue
            }
        })
    }

    private func pickFile(_ assign: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        assign(url.path)
    }

    private func startEdit(_ rule: CustomCertificateRule) {
        editingID = rule.id
        draftHost = rule.hostPattern
        draftCertPath = rule.certificatePath
        draftKeyPath = rule.privateKeyPath
    }

    private func clearDraft() {
        editingID = nil
        draftHost = ""
        draftCertPath = ""
        draftKeyPath = ""
    }

    private func commitDraft() {
        var rule = store.customCertificates.first { $0.id == editingID } ?? CustomCertificateRule()
        rule.hostPattern = draftHost.trimmingCharacters(in: .whitespaces)
        rule.certificatePath = draftCertPath
        rule.privateKeyPath = draftKeyPath
        if let index = store.customCertificates.firstIndex(where: { $0.id == rule.id }) {
            store.customCertificates[index] = rule
        } else {
            store.customCertificates.append(rule)
        }
        clearDraft()
    }

    private func removeSelected() {
        if let editingID, selection.contains(editingID) { clearDraft() }
        store.customCertificates.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }
}
