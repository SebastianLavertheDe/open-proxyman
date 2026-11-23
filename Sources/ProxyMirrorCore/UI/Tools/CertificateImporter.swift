import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum CertificateToolWindows {
    private static var importer: NSWindowController?
    private static var exporter: NSWindowController?
    private static var simulatorInstaller: NSWindowController?

    static func showImporter(purpose: CertificateFormats.Purpose = .client) {
        if importer?.window?.isVisible == true { importer?.showWindow(nil); return }
        importer = window(title: Strings.Tools.certificateImportAssistant, view: CertificateImporterView(initialPurpose: purpose))
        importer?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func showExporter(format: CertificateFormats.ExportFormat) {
        if exporter?.window?.isVisible == true { exporter?.showWindow(nil); return }
        exporter = window(title: Strings.Tools.exportProxymirrorCa, view: CertificateExportView(format: format))
        exporter?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func showSimulatorInstaller(platform: String = "all") {
        if simulatorInstaller?.window?.isVisible == true { simulatorInstaller?.showWindow(nil); return }
        simulatorInstaller = window(title: Strings.Tools.simulatorCaInstaller, view: SimulatorCertificateInstallerView(initialPlatform: platform))
        simulatorInstaller?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func closeImporter() { importer?.close() }
    static func closeExporter() { exporter?.close() }

    private static func window<Content: View>(title: String, view: Content) -> NSWindowController {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return NSWindowController(window: window)
    }
}

@MainActor
private struct CertificateExportView: View {
    let format: CertificateFormats.ExportFormat
    @State private var password = ""
    @State private var confirmation = ""
    @State private var working = false
    @State private var feedback: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(format.localizedTitle).font(.headline)
            if format.needsPassword {
                Text(Strings.Tools.setAPasswordForTheExportedIdentityFilePermissions)
                    .font(.caption).foregroundStyle(.secondary)
                SecureField(Strings.Tools.exportPassword, text: $password)
                SecureField(Strings.Tools.confirmPassword, text: $confirmation)
            }
            if let feedback { Text(feedback).font(.caption).foregroundStyle(failed ? Color.red : .secondary).textSelection(.enabled) }
            HStack {
                Button(Strings.Tools.close) { CertificateToolWindows.closeExporter() }.disabled(working)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(Strings.Tools.chooseLocationExport) { export() }
                    .disabled(working || (format.needsPassword && (password.isEmpty || password != confirmation)))
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 490)
        .onDisappear { password = ""; confirmation = "" }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "proxymirror-ca." + format.fileExtension
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let secret = password
        password = ""; confirmation = ""
        working = true; feedback = nil
        let selectedFormat = format
        Task {
            defer { working = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try CertificateFormats.export(format: selectedFormat, password: secret, to: target)
                }.value
                feedback = Strings.Tools.exportedTo1(String(describing: target.path))
                failed = false
                NSWorkspace.shared.activateFileViewerSelecting([target])
            } catch { feedback = LocalizedErrorPresentation.message(for: error); failed = true }
        }
    }
}

@MainActor
private struct CertificateImporterView: View {
    let initialPurpose: CertificateFormats.Purpose
    @State private var purpose = CertificateFormats.Purpose.client
    @State private var certificate: URL?
    @State private var privateKey: URL?
    @State private var password = ""
    @State private var host = ""
    @State private var material: CertificateFormats.Material?
    @State private var working = false
    @State private var feedback: String?
    @State private var failed = false
    @State private var confirmRootReplacement = false

    private var pkcs12: Bool { certificate.map { ["p12", "pfx"].contains($0.pathExtension.lowercased()) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Strings.Tools.step1ChoosePurposeFile).font(.headline)
            Picker(Strings.Tools.importPurpose, selection: $purpose) {
                ForEach(CertificateFormats.Purpose.allCases) { Text($0.localizedTitle).tag($0) }
            }
            HStack {
                Button(certificate?.lastPathComponent ?? Strings.Tools.choosePemDerCerP12) {
                    certificate = choose(Strings.Tools.chooseACertificateCertificateChainOrPkcs12Identity) ?? certificate
                    material = nil
                }
                if purpose.needsKey && !pkcs12 {
                    Button(privateKey?.lastPathComponent ?? Strings.Tools.choosePrivateKeyOrUseTheSameIdentityFile) {
                        privateKey = choose(Strings.Tools.chooseAPemDerPrivateKey) ?? privateKey
                        material = nil
                    }
                }
            }
            if purpose.needsKey || pkcs12 {
                SecureField(Strings.Tools.p12EncryptedPrivateKeyPasswordLeaveEmptyIfNone, text: $password)
            }
            if purpose == .client || purpose == .server {
                TextField(Strings.Tools.targetHostOrExampleCom, text: $host)
            }
            Button(Strings.Tools.step2ParseValidate) { inspect() }.disabled(working || certificate == nil)
            if let material {
                Divider()
                Group {
                    Text(Strings.Tools.certificateSubject(material.subject))
                    Text(Strings.Tools.certificateIssuer(material.issuer))
                    Text(Strings.Tools.certificateMaterialSummary(String(describing: material.expiry.formatted()), material.certificateCount, String(describing: material.isCA ? "CA" : Strings.Tools.leafCertificate)))
                    Text("SHA-256: \(material.fingerprint)").font(.system(size: 10, design: .monospaced))
                }.font(.caption).textSelection(.enabled)
                Text(Strings.Tools.validityDatesCaIdentityUsageKeyMatchingAndServer)
                    .font(.caption).foregroundStyle(.secondary)
                if purpose == .rootCA {
                    Toggle(Strings.Tools.replaceTheCurrentCaptureRootCaIWillReinstall, isOn: $confirmRootReplacement)
                    Text(Strings.Tools.existingKeychainCertificatesAreNotDeletedEstablishedTlsConnections)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let feedback { Text(feedback).font(.caption).foregroundStyle(failed ? Color.red : .secondary).textSelection(.enabled) }
            HStack {
                Button(Strings.Tools.close) { CertificateToolWindows.closeImporter() }.disabled(working)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(purpose == .rootCA ? Strings.Tools.step3ReplaceTheCaptureRootCa : Strings.Tools.step3ImportForSelectedPurpose) { install() }
                    .disabled(working || material == nil || (purpose == .rootCA && !confirmRootReplacement))
            }
        }.padding(20).frame(width: 650).disabled(working)
        .onAppear { purpose = initialPurpose }
        .onChange(of: purpose) { _ in material = nil; confirmRootReplacement = false; feedback = nil }
        .onChange(of: host) { _ in material = nil }
        .onChange(of: password) { _ in material = nil }
        .onDisappear { password = ""; material = nil }
    }

    private func choose(_ message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.message = message
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func inspect() {
        guard let certificate else { return }
        let key = purpose.needsKey && !pkcs12 ? privateKey : nil
        let secret = password, target = purpose, targetHost = host
        material = nil; feedback = nil; confirmRootReplacement = false; working = true
        Task {
            defer { working = false }
            do {
                let parsed = try await Task.detached(priority: .userInitiated) {
                    let value = try CertificateFormats.load(certificate: certificate, privateKey: key, password: secret)
                    try CertificateFormats.validate(value, purpose: target, host: targetHost)
                    return value
                }.value
                material = parsed
                feedback = Strings.Tools.validationPassedReviewTheCertificateInformationBeforeImporting; failed = false
            } catch { feedback = LocalizedErrorPresentation.message(for: error); failed = true }
        }
    }

    private func install() {
        guard let material, purpose != .rootCA || confirmRootReplacement else { return }
        let target = purpose, targetHost = host
        working = true; feedback = nil
        Task {
            defer { working = false }
            do {
                try CertificateFormats.validate(material, purpose: target, host: targetHost)
                if target == .server {
                    try installServer(material, host: targetHost)
                } else {
                    try await Task.detached(priority: .userInitiated) {
                        switch target {
                        case .rootCA:
                            guard let key = material.privateKeyPEM else { throw CertificateFormats.FormatError(Strings.Tools.theCaPrivateKeyIsMissing) }
                            try CertificateAuthority.shared.importRootCA(certificatePEM: material.certificatePEM, privateKeyPEM: key)
                        case .upstreamCA: try UpstreamTrust.install(Data(material.certificatePEM.utf8))
                        case .client:
                            try ClientTLSIdentities.shared.install(host: targetHost, material: material)
                            UpstreamTrust.clearClientIdentityContexts()
                        case .server: break
                        }
                    }.value
                }
                if target == .rootCA {
                    AppState.shared.caInstalled = false
                    AppState.shared.caBannerDismissed = false
                    UserDefaults.standard.set(false, forKey: "caBannerDismissed")
                }
                NotificationCenter.default.post(name: .proxyMirrorCertificatesChanged, object: nil)
                self.material = nil; password = ""; confirmRootReplacement = false
                feedback = target == .rootCA ? Strings.Tools.theCaptureCaWasReplacedReinstallItFromThe : Strings.Tools.importedNewConnectionsWillUseTheSelectedCertificateConfiguration
                failed = false
            } catch { feedback = LocalizedErrorPresentation.message(for: error); failed = true }
        }
    }

    private func installServer(_ material: CertificateFormats.Material, host input: String) throws {
        guard let key = material.privateKeyPEM, let host = ClientTLSIdentities.hostPattern(input) else {
            throw CertificateFormats.FormatError(Strings.Tools.aValidServerIdentityAndDomainAreRequired)
        }
        let directory = CertificateAuthority.applicationSupport.appendingPathComponent("ServerIdentities", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let certificate = directory.appendingPathComponent("chain.pem")
        let privateKey = directory.appendingPathComponent("key.pem")
        do {
            try PrivateAppFile.write(Data(material.certificatePEM.utf8), to: certificate)
            try PrivateAppFile.write(Data(key.utf8), to: privateKey)
            let rules = RulesStore.shared
            var backup = rules.backup()
            var entries = backup.customCertificates ?? []
            // Append a separately identifiable rule. Existing user files and rules are preserved.
            entries.insert(CustomCertificateRule(hostPattern: host, certificatePath: certificate.path, privateKeyPath: privateKey.path), at: 0)
            backup.customCertificates = entries
            try rules.install(backup)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
