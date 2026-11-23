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
            Label(("Automation Dashboard"), systemImage: "terminal")
                .font(.title2.bold())
            Text(Strings.Tools.launchApplicationsWithProxymirrorProxySettingsBrowsersUseSeparate)
                .foregroundStyle(.secondary)
            Label(("HTTP / SOCKS5：127.0.0.1:\(appState.listenerPort)"), systemImage: "network")
                .font(.system(.body, design: .monospaced))
            if !appState.proxyRunning {
                Button(Strings.Tools.startProxyListener) { appState.startProxy() }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(ProxyAutomation.Target.allCases) { target in
                    Button { launch(target) } label: {
                        HStack {
                            Image(systemName: [ProxyAutomation.Target.chrome, .firefox, .electron].contains(target) ? "globe" : "terminal")
                            Text(target.localizedTitle)
                            Spacer()
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .padding(10)
                    }
                    .disabled(!appState.proxyRunning || busy)
                }
            }
            Divider()
            Text(Strings.Tools.manualConfiguration).font(.headline)
            Text(ProxyAutomation.environment(port: appState.listenerPort, certificate: CertificateAuthority.shared.caCertPath)
                .keys.sorted().map { key in
                    let value = ProxyAutomation.environment(port: appState.listenerPort, certificate: CertificateAuthority.shared.caCertPath)[key]!
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
            Text(Strings.Tools.httpsRequiresTrustingTheProxymirrorCaInEachClient)
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
            panel.message = Strings.Tools.chooseTargetApplication(String(describing: target.localizedTitle))
            guard panel.runModal() == .OK else { return }
            application = panel.url
        }
        busy = true
        message = Strings.Tools.starting
        let selected = application
        Task { @MainActor in
            defer { busy = false }
            do {
                try CertificateAuthority.shared.ensureCA()
                message = try await ProxyAutomation.launchAndWait(target, port: appState.listenerPort,
                    certificate: CertificateAuthority.shared.caCertPath, application: selected)
                error = false
            } catch {
                message = LocalizedErrorPresentation.message(for: error)
                self.error = true
            }
        }
    }
}
