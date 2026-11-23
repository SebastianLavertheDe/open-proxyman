import SwiftUI

struct AccessControlSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var settings = AppSettings.shared
    @State private var enabled = false
    @State private var address = ""
    @State private var rangesText = ""
    @State private var checkAddress = ""
    @State private var feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("代理访问控制").font(.headline)
            Toggle("允许白名单设备连接局域网代理", isOn: $enabled)
            if enabled {
                Picker("本机监听地址", selection: $address) {
                    Text("选择本机地址").tag("")
                    ForEach(LANAccess.addresses, id: \.self) { Text($0).tag($0) }
                    if !address.isEmpty, !LANAccess.addresses.contains(address) {
                        Text("\(address)（当前不可用）").tag(address)
                    }
                }
                Text("允许的设备 IP 或 CIDR（每行一项）").font(.callout)
                TextEditor(text: $rangesText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 96)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
                    .accessibilityLabel("设备 IP 与 CIDR 白名单")
                Text("例如 192.168.1.20、192.168.10.0/24、2001:db8::5 或 fd00::/64。最多 256 项，仅接受数值地址。CIDR 会授权该范围内的所有设备。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("检查某个设备 IP", text: $checkAddress)
                    if !checkAddress.trimmingCharacters(in: .whitespaces).isEmpty {
                        let allowed = (try? NetworkAccessPolicy(ranges: ranges))?.allows(checkAddress) == true
                        Label(allowed ? "允许" : "拒绝", systemImage: allowed ? "checkmark.shield" : "xmark.shield")
                            .foregroundStyle(allowed ? Color.green : Color.secondary)
                    }
                }
                Text("设备代理填写所选地址及端口 \(settings.port)。只在该明确地址增加监听，本机 127.0.0.1 代理继续可用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let issue = validation ?? feedback {
                Text(issue).font(.caption).foregroundStyle(validation == nil ? Color.secondary : Color.red)
            }
            Button("应用访问控制与监听设置", action: save)
                .disabled(validation != nil || appState.systemProxyBusy || appState.proxyRestarting)
        }
        .onAppear(perform: load)
        .onChange(of: appState.proxyRestarting) { running in if !running { load() } }
        .onChange(of: rangesText) { _ in feedback = nil }
        .onChange(of: address) { _ in feedback = nil }
        .onChange(of: enabled) { _ in feedback = nil }
    }

    private var ranges: [String] {
        rangesText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private var validation: String? {
        guard enabled else { return nil }
        if !LANAccess.addresses.contains(address) { return "请选择当前可用的本机局域网地址。" }
        if ranges.isEmpty { return "启用局域网监听前，请至少填写一个允许的 IP 或 CIDR。" }
        return NetworkAccessPolicy.validationError(for: ranges)
    }

    private func load() {
        enabled = settings.lanEnabled
        address = settings.lanAddress
        let values = settings.allowedPeerRanges.isEmpty
            ? (settings.deviceAddress.isEmpty ? [] : [settings.deviceAddress]) : settings.allowedPeerRanges
        rangesText = values.joined(separator: "\n")
    }

    private func save() {
        guard validation == nil else { return }
        do {
            if !enabled {
                settings.lanEnabled = false
                appState.applyAndRestartIfNeeded()
                feedback = "已保存为仅本机访问。"
                if !appState.proxyRestarting { load() }
                return
            }
            let policy = try NetworkAccessPolicy(ranges: ranges)
            settings.lanEnabled = enabled
            settings.lanAddress = address
            settings.allowedPeerRanges = policy.ranges
            // Retain the legacy device field for older backups and single-device guides.
            if policy.ranges.count == 1, !policy.ranges[0].contains("/"),
               NumericIPAddress(policy.ranges[0])?.bytes.count == 4 {
                settings.deviceAddress = policy.ranges[0]
            }
            appState.applyAndRestartIfNeeded()
            feedback = appState.proxyRunning ? "已应用；监听重启会关闭旧设备连接。" : "访问控制已保存，启动监听后生效。"
            if !appState.proxyRestarting { load() }
        } catch { feedback = error.localizedDescription }
    }
}
