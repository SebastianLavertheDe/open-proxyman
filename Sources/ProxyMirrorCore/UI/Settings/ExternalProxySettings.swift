import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExternalProxySettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var draft = InterceptionConfig.shared.externalProxy.value
    @State private var port = String(InterceptionConfig.shared.externalProxy.value.port)
    @State private var bypass = (InterceptionConfig.shared.externalProxy.value.bypassHosts ?? []).joined(separator: "\n")
    @State private var feedback: String?
    @State private var saveFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("外部代理").font(.headline)
            Toggle("通过外部代理连接目标", isOn: $draft.enabled)
            if draft.enabled {
                Picker("协议", selection: $draft.mode) {
                    ForEach(ExternalProxyConfig.Mode.allCases, id: \.self) { mode in
                        Text(mode == .http || mode == .https ? "\(mode.rawValue) CONNECT" : mode.rawValue).tag(mode)
                    }
                }
                if draft.mode == .pac {
                    pacSettings
                } else {
                    manualSettings
                }
                Text("直连主机").fontWeight(.medium)
                TextEditor(text: $bypass)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 55)
                    .overlay(Rectangle().strokeBorder(.quaternary))
                    .accessibilityLabel("外部代理直连主机")
                Text("每行一个主机。example.com 仅匹配该主机，*.example.com 匹配其子域。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let issue = validation ?? feedback {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(validation != nil || saveFailed ? Color.red : Color.secondary)
            }
            Button("应用外部代理设置") { save() }
                .disabled(validation != nil)
        }
        .onChange(of: draft) { _ in feedback = nil }
        .onChange(of: port) { _ in feedback = nil }
        .onChange(of: bypass) { _ in feedback = nil }
    }

    private var pacSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("PAC URL", text: Binding(get: { draft.pacURL ?? "" }, set: { draft.pacURL = $0 }))
                Button("选择 PAC 文件…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.data]
                    if panel.runModal() == .OK { draft.pacURL = panel.url?.absoluteString }
                }
            }
            Text("支持 DIRECT、PROXY 和系统明确标记为 SOCKS5 的路由。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var manualSettings: some View {
        HStack {
            TextField("代理主机", text: $draft.host)
                .accessibilityLabel("外部代理主机")
            TextField("端口", text: $port)
                .frame(width: 80)
                .accessibilityLabel("外部代理端口")
        }
        Toggle("使用用户名和密码", isOn: $draft.useAuth)
        if draft.useAuth {
            HStack {
                TextField("用户名", text: $draft.username)
                SecureField("密码", text: $draft.password)
            }
            if draft.mode != .https {
                Text("此协议会将认证凭据发送给代理。HTTPS CONNECT 可加密这段连接。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var candidate: ExternalProxyConfig {
        var value = draft
        value.port = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        value.host = ExternalProxyHost(draft.host)?.name ?? draft.host
        value.pacURL = draft.pacURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.mode == .pac { value.useAuth = false }
        value.bypassHosts = bypass.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return value
    }

    private var validation: String? {
        guard draft.enabled else { return nil }
        if candidate.targetsLoopback(port: Int(settings.port)) {
            return "外部代理不能指向 ProxyMirror 的本机监听端口。"
        }
        return candidate.validationError
    }

    private func save() {
        var value = candidate
        if !value.enabled {
            value = InterceptionConfig.shared.externalProxy.value
            value.enabled = false
        }
        if !value.useAuth {
            value.username = ""
            value.password = ""
        }
        do {
            try store(value)
            InterceptionConfig.shared.externalProxy.set(value)
            feedback = value.enabled ? "外部代理设置已保存，应用于新连接。" : "已关闭外部代理。"
            saveFailed = false
        } catch {
            feedback = "保存失败：\(error.localizedDescription)"
            saveFailed = true
        }
    }

    private func store(_ config: ExternalProxyConfig) throws {
        let target = RulesFileIO.dir.appendingPathComponent("external.json")
        try PrivateAppFile.write(JSONEncoder().encode(config), to: target)
    }
}
