import SwiftUI

struct DNSMappingEditor: View {
    let initialHost: String
    @Environment(\.dismiss) private var dismiss
    @State private var rules: [DNSSpoofRule] = []
    @State private var selection: Set<UUID> = []
    @State private var host = ""
    @State private var address = ""
    @State private var error: String?
    @State private var folderDraft = RuleFolderEditingDraft()

    private var validHost: Bool {
        let name = host.hasPrefix("*.") ? String(host.dropFirst(2)) : host
        return !name.isEmpty && !name.contains("*") && RulesSnapshot.sslHostPattern(name) == name.lowercased()
            && !name.contains("/") && !name.contains(":") && name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    private var canAdd: Bool { validHost && URLParser.isIPAddress(address) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DNS 映射").font(.headline)
            Text("指定目标主机连接的 IP，HTTP Host 和 TLS 域名仍使用原主机。")
                .font(.caption).foregroundStyle(.secondary)
            List(selection: $selection) {
                ForEach($rules) { $rule in
                    HStack {
                        Toggle("启用规则", isOn: $rule.enabled).labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name.flatMap { $0.isEmpty ? nil : $0 } ?? rule.hostPattern)
                            if let name = rule.name, !name.isEmpty {
                                Text(rule.hostPattern).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(rule.ip).foregroundStyle(.secondary)
                    }
                    .tag(rule.id)
                }
            }
            if selection.count == 1, let id = selection.first, let index = rules.firstIndex(where: { $0.id == id }) {
                TextField("选中规则名称（可选）", text: Binding(
                    get: { rules[index].name ?? "" },
                    set: { rules[index].name = $0.isEmpty ? nil : $0 }
                ))
                HStack {
                    TextField("选中规则主机", text: $rules[index].hostPattern)
                    TextField("选中规则 IP", text: $rules[index].ip)
                }
                RuleFolderPicker(tool: "dns", ruleID: id.uuidString, draft: $folderDraft).id(id)
            }
            HStack {
                TextField("主机或 *.example.com", text: $host)
                TextField("IPv4 或 IPv6 地址", text: $address)
                Button("添加") { append() }.disabled(!canAdd)
                Button("移除所选") { rules.removeAll { selection.contains($0.id) }; selection = [] }
                    .disabled(selection.isEmpty)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if canAdd { append() }
                    let store = RulesStore.shared
                    var backup = store.backup()
                    backup.dns = rules
                    do {
                        backup.organization = try folderDraft.merging(into: backup.organization ?? RuleOrganizationStore.shared.snapshot(), tool: "dns", keeping: Set(rules.map { $0.id.uuidString }))
                        try store.install(backup)
                        dismiss()
                    } catch let failure {
                        error = failure.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 650, height: 440)
        .onAppear { rules = InterceptionConfig.shared.dnsSpoof.value; host = initialHost; folderDraft = RuleFolderEditingDraft() }
    }

    private func append() {
        let rule = DNSSpoofRule(hostPattern: host.lowercased(), ip: address)
        rules.append(rule)
        selection = [rule.id]
        host = ""
        address = ""
    }
}
