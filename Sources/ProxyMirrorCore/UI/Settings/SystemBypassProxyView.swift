import ProxyMirrorSystemProxy
import SwiftUI

struct SystemBypassProxyView: View {
    @EnvironmentObject private var appState: AppState
    @State private var useCustom = SystemProxyBypass.savedHosts != nil
    @State private var hosts = SystemProxyBypass.savedHosts ?? []
    @State private var newHost = ""
    @State private var services: [SystemProxyBypass.Service] = []
    @State private var applying = false
    @State private var feedback: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("系统代理旁路").font(.headline)
            Toggle("接管期间使用自定义旁路列表", isOn: $useCustom)
            if useCustom {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(hosts.indices, id: \.self) { index in
                            HStack {
                                Text(hosts[index]).font(.system(.caption, design: .monospaced))
                                Spacer()
                                Button { hosts.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).accessibilityLabel("移除旁路 \(hosts[index])")
                            }
                        }
                    }.frame(maxWidth: .infinity)
                }.frame(height: min(120, max(30, CGFloat(hosts.count) * 24)))
                    .padding(6).overlay(Rectangle().strokeBorder(.quaternary))
                HStack {
                    TextField("*.example.com / 10.0.0.0/8", text: $newHost).onSubmit(add)
                    Button("添加", action: add).disabled(newHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("复制当前服务列表") {
                        hosts = SystemProxyBypassList.normalized(services.flatMap(\.hosts)); feedback = nil
                    }.disabled(services.isEmpty)
                }
                Text("匹配的主机由系统直接连接，不会进入抓包。空列表表示不额外旁路。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("设置通过已有系统代理后台服务应用。停止接管、退出或连接意外断开时恢复原列表；其他应用随后修改的列表会保留。")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("当前网络服务的旁路列表") {
                ForEach(services) { service in
                    Text("\(service.name)：\(service.hosts.isEmpty ? "（空）" : service.hosts.joined(separator: ", "))")
                        .font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let feedback { Text(feedback).font(.caption).foregroundStyle(failed ? Color.red : Color.secondary) }
            HStack {
                Button(appState.systemProxyActive ? "应用到当前接管" : "保存，供下次接管使用", action: apply)
                    .disabled(applying || appState.systemProxyBusy || appState.proxyRestarting)
                if applying { ProgressView().controlSize(.small) }
                Button("刷新") { services = SystemProxyBypass.services() }.disabled(applying)
            }
        }
        .onAppear { services = SystemProxyBypass.services() }
        .disabled(applying)
    }

    private func add() {
        let candidate = SystemProxyBypassList.normalized([newHost])
        guard !candidate.isEmpty else { return }
        if let issue = SystemProxyBypassList.validationError(candidate) { feedback = issue; failed = true; return }
        hosts = SystemProxyBypassList.normalized(hosts + candidate)
        newHost = ""; feedback = nil
    }

    private func apply() {
        let desired = useCustom ? SystemProxyBypassList.normalized(hosts) : nil
        if let desired, let issue = SystemProxyBypassList.validationError(desired) { feedback = issue; failed = true; return }
        if appState.systemProxyActive {
            applying = true
            SystemProxyController.shared.updateBypass(desired) { success, message in
                applying = false
                guard success else { feedback = message; failed = true; return }
                complete(desired, active: true)
            }
        } else { complete(desired, active: false) }
    }

    private func complete(_ desired: [String]?, active: Bool) {
        do {
            try SystemProxyBypass.save(desired)
            feedback = active ? "已应用旁路列表；停止接管时恢复原配置。" : "已保存；下次接管时应用。"
            failed = false; services = SystemProxyBypass.services()
        } catch { feedback = error.localizedDescription; failed = true }
    }
}
