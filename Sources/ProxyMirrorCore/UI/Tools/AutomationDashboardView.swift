import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct AutomationDashboardView: View {
    @ObservedObject private var appState = AppState.shared
    @State private var message = ""
    @State private var error = false
    @State private var busy = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Automation Dashboard", systemImage: "terminal")
                .font(.title2.bold())
            Text("启动应用时带上 ProxyMirror 的代理配置。浏览器使用独立 Profile；终端窗口携带代理和 CA 环境变量。")
                .foregroundStyle(.secondary)
            Label("HTTP / SOCKS5：127.0.0.1:\(appState.settings.port)", systemImage: "network")
                .font(.system(.body, design: .monospaced))
            if !appState.proxyRunning {
                Button("启动代理监听") { appState.startProxy() }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(ProxyAutomation.Target.allCases) { target in
                    Button { launch(target) } label: {
                        HStack {
                            Image(systemName: [ProxyAutomation.Target.chrome, .firefox, .electron].contains(target) ? "globe" : "terminal")
                            Text(target.rawValue)
                            Spacer()
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .padding(10)
                    }
                    .disabled(!appState.proxyRunning || busy)
                }
            }
            Divider()
            Text("手动配置").font(.headline)
            Text(ProxyAutomation.environment(port: appState.settings.port, certificate: CertificateAuthority.shared.caCertPath)
                .keys.sorted().map { key in
                    let value = ProxyAutomation.environment(port: appState.settings.port, certificate: CertificateAuthority.shared.caCertPath)[key]!
                    return "export \(key)=\(ProxyAutomation.shellQuote(value))"
                }.joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(error ? .red : .secondary).textSelection(.enabled)
            }
            Text("HTTPS 需在对应客户端信任 ProxyMirror CA。需要 macOS「自动化」权限的终端首次启动时会显示系统提示。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(minWidth: 640, idealWidth: 700, minHeight: 600)
    }

    private func launch(_ target: ProxyAutomation.Target) {
        var application: URL?
        if target.needsApplication {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.applicationBundle]
            panel.message = "选择 \(target.rawValue) 应用"
            guard panel.runModal() == .OK else { return }
            application = panel.url
        }
        busy = true
        message = "正在启动…"
        let selected = application
        Task { @MainActor in
            defer { busy = false }
            do {
                try CertificateAuthority.shared.ensureCA()
                message = try await ProxyAutomation.launchAndWait(target, port: appState.settings.port,
                    certificate: CertificateAuthority.shared.caCertPath, application: selected)
                error = false
            } catch {
                message = error.localizedDescription
                self.error = true
            }
        }
    }
}
