import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ClientTLSIdentitySettings: View {
    @State private var entries = ClientTLSIdentities.shared.summaries
    @State private var host = ""
    @State private var certificate: URL?
    @State private var privateKey: URL?
    @State private var feedback: String?
    @State private var saving = false
    @State private var failed = false
    @State private var usePKCS12 = false
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Strings.Settings.upstreamClientCertificatesMtls).font(.headline)
            Text(Strings.Settings.chooseAPemCertificateChainAndPrivateKey)
                .font(.caption).foregroundStyle(.secondary)
            ForEach(entries) { item in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.host).fontWeight(.medium)
                        Text(item.subject).font(.caption).foregroundStyle(.secondary)
                        Text(Strings.Settings.expires(item.expiry.formatted(date: .abbreviated, time: .omitted)))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { remove(item.id) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Strings.Settings.removeClientCertificateFor(item.host))
                    .disabled(saving)
                }
            }
            Picker(Strings.Settings.identityFormat, selection: $usePKCS12) {
                Text(Strings.Settings.pemCertificatePrivateKey).tag(false)
                Text("PKCS#12 (.p12/.pfx)").tag(true)
            }.pickerStyle(.segmented)
            TextField(Strings.Settings.targetHostOrExampleCom, text: $host)
                .accessibilityLabel(Strings.Settings.mtlsTargetHost)
            HStack {
                Button(certificate?.lastPathComponent ?? Strings.Settings.chooseCertificateChain) { certificate = choose() ?? certificate }
                    .accessibilityLabel(Strings.Settings.chooseClientCertificateChain)
                if !usePKCS12 {
                    Button(privateKey?.lastPathComponent ?? Strings.Settings.choosePrivateKey) { privateKey = choose() ?? privateKey }
                        .accessibilityLabel(Strings.Settings.chooseClientPrivateKey)
                }
            }
            if usePKCS12 { SecureField(Strings.Settings.p12Password, text: $password) }
            HStack {
                Button(Strings.Settings.saveClientIdentity) { save() }
                    .disabled(saving || certificate == nil || (!usePKCS12 && privateKey == nil) || ClientTLSIdentities.hostPattern(host) == nil)
                if saving { ProgressView().controlSize(.small) }
                Button(Strings.Settings.certificateImportWizard) { CertificateToolWindows.showImporter(purpose: .client) }
            }
            if let feedback = feedback ?? ClientTLSIdentities.shared.loadError {
                Text(feedback).font(.caption)
                    .foregroundStyle(failed || ClientTLSIdentities.shared.loadError != nil ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }
        }
        .onAppear { entries = ClientTLSIdentities.shared.summaries }
        .onReceive(NotificationCenter.default.publisher(for: .proxyMirrorCertificatesChanged).receive(on: RunLoop.main)) { _ in
            entries = ClientTLSIdentities.shared.summaries
        }
        .onChange(of: usePKCS12) { _ in certificate = nil; privateKey = nil; password = ""; feedback = nil }
        .onDisappear { password = "" }
    }

    private func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func save() {
        guard let certificate, usePKCS12 || privateKey != nil else { return }
        let key = privateKey, p12 = usePKCS12, secret = password
        password = ""
        let targetHost = host
        perform(Strings.Settings.clientIdentitySavedItAppliesToNewUpstream) {
            if p12 {
                try ClientTLSIdentities.shared.install(host: targetHost, p12: certificate, password: secret)
            } else if let key {
                try ClientTLSIdentities.shared.install(host: targetHost, certificate: certificate, privateKey: key)
            }
        } after: {
            host = ""
            self.certificate = nil
            self.privateKey = nil
        }
    }

    private func remove(_ id: UUID) {
        perform(Strings.Settings.clientIdentityRemoved) { try ClientTLSIdentities.shared.remove(id) }
    }

    private func perform(_ success: String, operation: @Sendable @escaping () throws -> Void,
                         after: @escaping () -> Void = {}) {
        saving = true
        feedback = nil
        Task {
            defer { saving = false }
            do {
                try await Task.detached(priority: .userInitiated, operation: operation).value
                UpstreamTrust.clearClientIdentityContexts()
                entries = ClientTLSIdentities.shared.summaries
                feedback = success
                failed = false
                after()
            } catch {
                feedback = LocalizedErrorPresentation.message(for: error)
                failed = true
            }
        }
    }
}
