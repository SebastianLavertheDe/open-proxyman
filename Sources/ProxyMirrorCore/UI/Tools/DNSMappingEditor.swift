import SwiftUI

struct DNSMappingEditor: View {
    let initialHost: String
    @Environment(\.dismiss) private var dismiss
    @State private var rules: [DNSSpoofRule] = []
    @State private var selection: Set<UUID> = []
    @State private var host = ""
    @State private var address = ""
    @State private var error: String?

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
                        Text(rule.hostPattern)
                        Spacer()
                        Text(rule.ip).foregroundStyle(.secondary)
                    }
                    .tag(rule.id)
                }
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
        .frame(width: 590, height: 340)
        .onAppear { rules = InterceptionConfig.shared.dnsSpoof.value; host = initialHost }
    }

    private func append() {
        rules.append(DNSSpoofRule(hostPattern: host.lowercased(), ip: address))
        host = ""
        address = ""
    }
}
