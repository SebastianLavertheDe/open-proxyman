import AppKit
import SwiftUI

/// Root trust, pinned server identities and upstream mTLS identities have distinct lifecycles.
@MainActor
struct CertificateManagerView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var rules = RulesStore.shared
    @State private var tab = 0
    @State private var clients: [ClientTLSIdentities.Summary] = []
    @State private var feedback = ""
    @State private var resetConfirmation = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TabView(selection: $tab) {
                root.tabItem { Text(Strings.Guides.setupRootCertificate) }.tag(0)
                server.tabItem { Text(Strings.Guides.setupServerCertificates) }.tag(1)
                client.tabItem { Text(Strings.Guides.setupClientCertificates) }.tag(2)
            }
            if !feedback.isEmpty { Text(feedback).font(.system(size: 11)).textSelection(.enabled) }
        }.padding(16).frame(width: 700, height: 498)
        .onAppear { appState.refreshCertificateStatus(); refreshClients() }
        .onReceive(NotificationCenter.default.publisher(for: .proxyMirrorCertificatesChanged)) { _ in
            appState.refreshCertificateStatus(); refreshClients()
        }
        .alert(Strings.Tools.resetAllProxymirrorCertificates2, isPresented: $resetConfirmation) {
            Button(Strings.Tools.cancel, role: .cancel) {}
            Button(Strings.Tools.reset, role: .destructive) {
                busy = true
                CertInstaller.resetAll { result in
                    busy = false
                    switch result {
                    case .success:
                        appState.caBannerDismissed = false
                        UserDefaults.standard.set(false, forKey: "caBannerDismissed")
                        appState.refreshCertificateStatus()
                        feedback = Strings.Guides.setupRootReset
                    case .failure(let error): feedback = LocalizedErrorPresentation.message(for: error)
                    }
                }
            }
        } message: { Text(Strings.Tools.theProxymirrorCaWillBeRemovedFromTheKeychain) }
    }

    private var root: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image(systemName: "checkmark.seal").font(.system(size: 45)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(appState.certificateAuthority.caCommonName ?? "ProxyMirror CA").font(.system(size: 13, weight: .semibold))
                    if let created = appState.certificateAuthority.caNotBefore { Text(Strings.Guides.setupGenerated + ": " + created.formatted()) }
                    if let expiry = appState.certificateAuthority.caExpiry { Text(Strings.Guides.setupExpires + ": " + expiry.formatted()) }
                    Label((appState.caInstalled ? Strings.Guides.setupInstalledTrusted : Strings.Guides.setupNotTrusted), systemImage: appState.caInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(appState.caInstalled ? Color.green : .orange)
                }.font(.system(size: 11)).textSelection(.enabled)
                Spacer()
            }.padding(16).frame(maxWidth: .infinity).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            Text(Strings.Guides.setupRootDescription).font(.system(size: 13))
            if let hash = appState.certificateAuthority.caFingerprintSHA256 {
                Text(verbatim: "SHA-256: " + hash).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            }
            Spacer()
            HStack {
                Button(Strings.Tools.delete, role: .destructive) { resetConfirmation = true }.disabled(busy)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(Strings.Guides.setupPreview) { previewRoot() }.disabled(busy)
                Menu(Strings.Guides.setupImport) {
                    Button { CertificateToolWindows.showImporter(purpose: .rootCA) } label: { Text(verbatim: "PEM / DER…") }
                    Button { CertificateToolWindows.showImporter(purpose: .rootCA) } label: { Text(verbatim: "P12…") }
                }
            }
        }.padding(16)
    }

    private var server: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Strings.Guides.setupServerDescription).font(.system(size: 13))
            List {
                ForEach(rules.customCertificates) { rule in
                    HStack {
                        Text(rule.hostPattern).font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Button(Strings.Guides.setupPreview) { previewServer(URL(fileURLWithPath: rule.certificatePath)) }
                        Button(Strings.Tools.delete) { rules.customCertificates.removeAll { $0.id == rule.id } }
                    }.frame(minHeight: 24)
                    .contextMenu {
                        Button(Strings.Guides.setupPreview) { previewServer(URL(fileURLWithPath: rule.certificatePath)) }
                        Button(Strings.Tools.export) { exportFile(URL(fileURLWithPath: rule.certificatePath)) }
                        Button(Strings.Tools.delete) { rules.customCertificates.removeAll { $0.id == rule.id } }
                    }
                }
            }
            importMenu(.server)
        }.padding(16)
    }

    private var client: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Strings.Guides.setupClientDescription).font(.system(size: 13))
            List {
                ForEach(clients) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.host).font(.system(size: 12, design: .monospaced))
                            Text(entry.subject + " · " + entry.expiry.formatted()).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(Strings.Guides.setupPreview) { previewClient(entry.id) }
                        Button(Strings.Tools.delete) { deleteClient(entry.id) }
                    }.frame(minHeight: 24)
                    .contextMenu {
                        Button(Strings.Guides.setupPreview) { previewClient(entry.id) }
                        Button(Strings.Tools.delete) { deleteClient(entry.id) }
                    }
                }
            }
            importMenu(.client)
        }.padding(16)
    }

    private func importMenu(_ purpose: CertificateFormats.Purpose) -> some View {
        HStack {
            Spacer()
            Menu(Strings.Guides.setupImport) {
                Button { CertificateToolWindows.showImporter(purpose: purpose) } label: { Text(verbatim: "PEM / DER…") }
                Button { CertificateToolWindows.showImporter(purpose: purpose) } label: { Text(verbatim: "P12…") }
            }
        }
    }
    private func refreshClients() {
        clients = ClientTLSIdentities.shared.summaries
        if let error = ClientTLSIdentities.shared.loadError { feedback = error }
    }
    nonisolated private static func previewFile(data: Data, name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyMirror-Certificate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(name)
        try PrivateAppFile.write(data, to: url)
        return url
    }
    private func previewRoot() {
        let authority = appState.certificateAuthority
        showPreview(name: "ProxyMirror-CA.cer") { try authority.caDER() }
    }
    private func previewServer(_ source: URL) {
        showPreview(name: "ProxyMirror-Server.cer") {
            try PublicCertificateData(CertificateFormats.read(source)).leafDER
        }
    }
    private func showPreview(name: String, load: @escaping @Sendable () throws -> Data) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try Self.previewFile(data: load(), name: name)
                }.value
                NSWorkspace.shared.open(url)
            } catch { feedback = LocalizedErrorPresentation.message(for: error) }
        }
    }
    private func previewClient(_ id: UUID) {
        showPreview(name: "ProxyMirror-Client.cer") {
            guard let bytes = ClientTLSIdentities.shared.certificateData(id: id) else { throw CocoaError(.fileReadNoSuchFile) }
            return try PublicCertificateData(bytes).leafDER
        }
    }
    private func deleteClient(_ id: UUID) {
        do { try ClientTLSIdentities.shared.remove(id); UpstreamTrust.clearClientIdentityContexts(); refreshClients() }
        catch { feedback = LocalizedErrorPresentation.message(for: error) }
    }
    private func exportFile(_ source: URL) {
        guard !busy else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + ".pem"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    let publicData = try PublicCertificateData(CertificateFormats.read(source))
                    try PrivateAppFile.write(publicData.chainPEM, to: destination)
                }.value
            } catch { feedback = LocalizedErrorPresentation.message(for: error) }
        }
    }
}
