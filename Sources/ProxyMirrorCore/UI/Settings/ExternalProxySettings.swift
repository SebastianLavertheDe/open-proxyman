import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExternalProxySettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var draft = InterceptionConfig.shared.externalProxy.value
    @State private var port = String(InterceptionConfig.shared.externalProxy.value.port)
    @State private var bypass = InterceptionConfig.shared.externalProxy.value.bypassHosts ?? []
    @State private var newBypassHost = ""
    @State private var includedTargets = InterceptionConfig.shared.externalProxy.value.includedTargets ?? []
    @State private var newIncludedTarget = ""
    @State private var pacChecking = false
    @State private var pacFeedback: String?
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
                Picker("路由范围", selection: Binding(get: { draft.effectiveRoutingMode }, set: { draft.routingMode = $0 })) {
                    ForEach(ExternalProxyConfig.RoutingMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }
                if draft.effectiveRoutingMode == .bypass {
                    Text("直连主机").fontWeight(.medium)
                    bypassList
                    Text("列表中的主机直连，其余目标使用上游。example.com 仅匹配该主机，*.example.com 匹配子域。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if draft.effectiveRoutingMode == .inclusive {
                    Text("使用上游的包含目标").fontWeight(.medium)
                    inclusiveList
                    Text("例如 *.example.com 或 https://api.example.com/v1/*。仅命中的主机或完整 URL 使用上游，其余目标直连。URL 的路径和查询区分大小写，* 匹配任意字符。HTTPS 路径匹配需要 SSL 解密，透传连接请使用主机匹配。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("localhost、*.localhost、127.0.0.0/8、::1 与其 IPv4 映射地址在所有模式下始终直连。")
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
        .onChange(of: draft) { _ in feedback = nil; pacFeedback = nil }
        .onChange(of: port) { _ in feedback = nil }
        .onChange(of: bypass) { _ in feedback = nil }
        .onChange(of: includedTargets) { _ in feedback = nil }
    }

    private var bypassList: some View {
        VStack(spacing: 6) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(bypass.indices, id: \.self) { index in
                        HStack {
                            Text(bypass[index]).font(.system(.caption, design: .monospaced))
                            Spacer()
                            Button { bypass.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).accessibilityLabel("移除直连主机 \(bypass[index])")
                        }
                    }
                }.frame(maxWidth: .infinity)
            }.frame(height: min(105, max(30, CGFloat(bypass.count) * 22)))
                .padding(5).overlay(Rectangle().strokeBorder(.quaternary))
            HStack {
                TextField("主机或 *.example.com", text: $newBypassHost).onSubmit(addBypass)
                Button("添加", action: addBypass).disabled(newBypassHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var inclusiveList: some View {
        VStack(spacing: 6) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(includedTargets.indices, id: \.self) { index in
                        HStack {
                            Text(includedTargets[index]).font(.system(.caption, design: .monospaced))
                            Spacer()
                            Button { includedTargets.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).accessibilityLabel("移除包含目标 \(includedTargets[index])")
                        }
                    }
                }.frame(maxWidth: .infinity)
            }.frame(height: min(105, max(30, CGFloat(includedTargets.count) * 22)))
                .padding(5).overlay(Rectangle().strokeBorder(.quaternary))
            HStack {
                TextField("主机通配或完整 URL 通配", text: $newIncludedTarget).onSubmit(addIncludedTarget)
                Button("添加", action: addIncludedTarget)
                    .disabled(newIncludedTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || includedTargets.count >= 256)
            }
        }
    }

    private func addIncludedTarget() {
        let raw = newIncludedTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = ExternalProxyTarget(raw) else { feedback = "请输入有效的主机通配或 HTTP(S) URL 通配。"; saveFailed = true; return }
        if !includedTargets.contains(target.pattern) { includedTargets.append(target.pattern) }
        newIncludedTarget = ""; feedback = nil
    }

    private func addBypass() {
        let value = newBypassHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return }
        var check = candidate; check.bypassHosts = [value]
        if let issue = check.validationError { feedback = issue; saveFailed = true; return }
        if !bypass.contains(value) { bypass.append(value) }
        newBypassHost = ""; feedback = nil
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
            HStack {
                Button("验证 PAC") {
                    pacChecking = true; pacFeedback = nil
                    ExternalProxyPACValidation.check(candidate) { result in
                        pacChecking = false
                        switch result {
                        case .success(let description): pacFeedback = description
                        case .failure(let error): pacFeedback = "PAC 验证失败：" + error.localizedDescription
                        }
                    }
                }.disabled(pacChecking || candidate.validationError != nil)
                if pacChecking { ProgressView().controlSize(.small) }
            }
            Text(pacFeedback ?? "支持 DIRECT、PROXY 和系统明确标记为 SOCKS5 的路由。验证会实际加载 PAC 并计算 https://example.com/ 的路由。")
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
        value.bypassHosts = bypass.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        value.includedTargets = includedTargets.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
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
            var backup = RulesStore.shared.backup()
            backup.external = value
            try RulesStore.shared.install(backup)
            feedback = value.enabled ? "外部代理设置已保存，应用于新连接。" : "已关闭外部代理。"
            saveFailed = false
        } catch {
            feedback = "保存失败：\(error.localizedDescription)"
            saveFailed = true
        }
    }

}
