import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import ProxyMirrorSystemProxy

/// A step-based guide backed by the same listener, CA and device services used by capture.
@MainActor
struct SetupGuideWindow: View {
    let platform: String
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.self) private var environment
    @State private var busy = false
    @State private var refreshing = false
    @State private var feedback = ""
    @State private var simulatorCount = 0
    @State private var androidDevices: [AndroidEmulatorSetup.Device] = []
    @State private var qrVisible = false
    @State private var textVisible = false
    @State private var automatic = true
    @State private var reboot = false
    @State private var helperStatus: SystemProxyController.ServiceStatus?

    private var title: String {
        switch platform {
        case "macOS": return Strings.Guides.setupMacTitle
        case "iOS": return Strings.Guides.setupIosTitle
        case "iOS Simulator": return Strings.Guides.setupSimulatorTitle
        case "Android": return Strings.Guides.setupAndroidTitle
        case "Android Emulator": return Strings.Guides.setupAndroidEmulatorTitle
        case "Helper": return Strings.Guides.setupHelperTitle
        default: return platform + " · " + Strings.Guides.setupGuide
        }
    }
    private var lan: LANAccess? { appState.proxyRunning ? appState.engine.lanAccess : appState.settings.lanAccess }
    private var address: String { lan?.address ?? LANAccess.addresses.first ?? "127.0.0.1" }
    private var remoteReady: Bool { appState.proxyRunning && lan?.valid == true }
    private var guide: CertificatePlatformGuides.Guide {
        CertificatePlatformGuides.guide(for: platform, certificatePath: appState.certificateAuthority.caCertPath.path, port: Int(appState.listenerPort))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Spacer()
                    Button(Strings.Guides.setupManageCertificates) { openWindow(id: "certificate-manager") }
                    Button(Strings.Tools.refreshDevices) { refresh() }.disabled(refreshing || busy)
                    if refreshing || busy { ProgressView().controlSize(.small) }
                }
                GuideTitle(title: title)
                switch platform {
                case "macOS": macGuide
                case "iOS": iosGuide
                case "iOS Simulator": simulatorGuide
                case "Android": androidGuide
                case "Android Emulator": androidEmulatorGuide
                case "Helper": helperGuide
                default: frameworkGuide
                }
                if !feedback.isEmpty {
                    Text(feedback).font(.system(size: 12)).textSelection(.enabled)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                HStack {
                    Button(Strings.Guides.setupTextInstructions) { textVisible = true }
                    Spacer()
                    Button(Strings.Guides.setupAutomatic) { openWindow(id: "automation") }
                }.font(.system(size: 11))
            }.padding(30)
        }
        .frame(minWidth: platform == "iOS Simulator" ? 580 : 760, idealWidth: 760, minHeight: 540, idealHeight: 650)
        .background(SetupWindowFocusObserver { refresh() })
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .proxyMirrorCertificatesChanged)) { _ in refresh() }
        .sheet(isPresented: $qrVisible) { CertificateQRCodeView() }
        .sheet(isPresented: $textVisible) {
            CertificateGuideSheet(platform: platform == "Android Emulator" ? "Android" : platform).environmentObject(appState)
        }
    }

    private var macGuide: some View {
        VStack(alignment: .leading, spacing: 18) {
            GuideStep(title: Strings.Guides.setupInstallTrust, state: appState.caInstalled ? .complete : .pending) {
                Text(Strings.Guides.setupMacInstallDescription)
                Picker(Strings.Guides.setupMethod, selection: $automatic) {
                    Text(Strings.Guides.setupAutomaticTab).tag(true)
                    Text(Strings.Guides.setupManualTab).tag(false)
                }.pickerStyle(.segmented)
                if automatic {
                    Button(Strings.Guides.setupInstallTrust, action: installCA)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(busy)
                    Text(Strings.Guides.setupRequiresAuthorization).font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button(Strings.Guides.setupAddKeychain) {
                            do { try appState.certificateAuthority.ensureCA(); NSWorkspace.shared.open(appState.certificateAuthority.caCertPath) }
                            catch { feedback = LocalizedErrorPresentation.message(for: error) }
                        }
                        Button(Strings.Guides.setupAddOwnCertificate) { CertificateToolWindows.showImporter(purpose: .rootCA) }
                    }
                    Text(Strings.Guides.setupKeychainTrust)
                    GuideCodeBlock(code: "sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain " + ProxyAutomation.shellQuote(appState.certificateAuthority.caCertPath.path))
                }
            }
            listenerStep(remote: false)
        }
    }

    private var iosGuide: some View {
        VStack(alignment: .leading, spacing: 22) {
            installStep
            listenerStep(remote: true)
            GuideStep(title: Strings.Guides.setupDownloadCertificate, state: remoteReady ? .pending : .attention) {
                Text(Strings.Guides.setupDownloadSafari)
                HStack {
                    Text(verbatim: "http://proxy.mirror/ssl").font(.system(size: 14, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    copyButton("http://proxy.mirror/ssl")
                    Button(Strings.Guides.setupShowQr) { qrVisible = true }
                    Button(Strings.Guides.setupAirdrop, action: airDropCertificate)
                }
            }
            GuideStep(title: Strings.Guides.setupIosTrust, state: .pending) {
                Text(Strings.Guides.setupIosProfile)
                Text(Strings.Guides.setupIosFullTrust)
                Text(Strings.Guides.setupIosTrustNote).font(.system(size: 11)).foregroundStyle(.secondary)
                Link(Strings.Guides.setupAppleInstructions, destination: URL(string: "https://support.apple.com/102390")!)
            }
        }
    }

    private var simulatorGuide: some View {
        VStack(alignment: .leading, spacing: 22) {
            installStep
            GuideStep(title: Strings.Guides.setupSimulatorInstall, state: simulatorCount > 0 ? .pending : .attention) {
                Text(Strings.Guides.setupSimulatorCompatibility)
                Text(Strings.Guides.setupRunningSimulators + ": \(simulatorCount)").foregroundStyle(.secondary)
                HStack {
                    Button(Strings.Tools.chooseSimulatorInstallCa) { CertificateToolWindows.showSimulatorInstaller(platform: "all") }
                    Button(Strings.Guides.setupInstallAllSimulators) {
                        run { try DeviceAutomation.setupSimulators(certificatePath: $0) }
                    }.disabled(busy || simulatorCount == 0)
                }
            }
            GuideStep(title: Strings.Guides.setupSimulatorRestart, state: .pending) {
                Text(Strings.Guides.setupSimulatorRestartNote)
                Button(Strings.Guides.setupRestartSimulators) {
                    run { _ in
                        let devices = try DeviceAutomation.bootedSimulators()
                        for device in devices { try DeviceAutomation.restartSimulator(device.udid) }
                        return Strings.Guides.setupOperationComplete
                    }
                }.disabled(busy || simulatorCount == 0)
            }
        }
    }

    private var androidGuide: some View {
        VStack(alignment: .leading, spacing: 22) {
            listenerStep(remote: true)
            GuideStep(title: Strings.Guides.setupAndroidInstall, state: .pending) {
                Text(Strings.Guides.setupAndroidInstallDescription)
                HStack {
                    Button(Strings.Guides.setupShowQr) { qrVisible = true }
                    Button(Strings.Tools.exportCaCertificate) { CertInstaller.exportCA(extension: "cer") }
                    Button(Strings.Tools.copyUserCaViaAdb) { appState.prepareAndroidUserCertificate() }
                }
            }
            GuideStep(title: Strings.Guides.setupAndroidProject, state: .pending) {
                Text(verbatim: "res/xml/network_security_config.xml").font(.system(size: 12, weight: .semibold))
                GuideCodeBlock(code: CertificatePlatformGuides.guide(for: "Android", certificatePath: "", port: Int(appState.listenerPort)).commands)
                Text(verbatim: "AndroidManifest.xml").font(.system(size: 12, weight: .semibold))
                GuideCodeBlock(code: "<application android:networkSecurityConfig=\"@xml/network_security_config\" … />")
                Button(Strings.Guides.setupTryAndroidEmulator) { openWindow(id: "setup-guide", value: "Android Emulator") }
            }
        }
    }

    private var androidEmulatorGuide: some View {
        VStack(alignment: .leading, spacing: 18) {
            GuideStep(title: Strings.Guides.setupAndroidOverride, state: androidDevices.contains(where: \.supported) ? .pending : .attention) {
                Text(Strings.Guides.setupAndroidOverrideDescription)
                if androidDevices.isEmpty { Text(Strings.Guides.setupNoAndroidDevices).foregroundStyle(.secondary) }
                ForEach(androidDevices) { device in
                    HStack(alignment: .top) {
                        Image(systemName: device.supported ? "checkmark.circle" : "exclamationmark.triangle").foregroundStyle(device.supported ? Color.green : .orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.serial + " · API \(device.api)" + (device.playStore ? " · Google Play" : ""))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            Text(Strings.Guides.setupHttpProxy + ": \(device.proxy) · CA: " + (device.certificatePresent ? Strings.Guides.setupPresent : Strings.Guides.setupMissing))
                            if !device.supported { Text(Strings.Guides.setupAndroidUnsupported).foregroundStyle(.orange) }
                        }.font(.system(size: 11))
                        Spacer()
                    }.padding(8).background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                }
                Toggle(Strings.Guides.setupRebootAfterChanges, isOn: $reboot)
                Text(Strings.Guides.setupAndroidNoCompanion).font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Button(Strings.Guides.setupOverrideAll) { overrideAndroid() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(busy || !appState.proxyRunning || !androidDevices.contains(where: \.supported))
                    Menu(Strings.Settings.more) {
                        Button(Strings.Guides.setupProxyOnly) { overrideAndroid(installCertificate: false) }
                        Button(Strings.Guides.setupCertificateOnly) { overrideAndroid(setProxy: false) }
                        Divider()
                        Button(Strings.Guides.setupManualTab) { textVisible = true }
                        Link(Strings.Guides.setupAndroidDocs, destination: URL(string: "https://developer.android.com/privacy-and-security/security-config")!)
                    }.disabled(busy)
                }
                if !appState.proxyRunning { Button(Strings.Tools.startProxyListener) { appState.startProxy() } }
            }
            GuideStep(title: Strings.Guides.setupRevert, state: .pending) {
                Text(Strings.Guides.setupRevertDescription)
                Button(Strings.Guides.setupRevertAll) {
                    let restart = reboot
                    run { _ in
                        let devices = try DeviceAutomation.androidSetup.revert(reboot: restart)
                        return Strings.Guides.setupRestoredDevices + ": " + devices.joined(separator: ", ")
                    }
                }.disabled(busy)
            }
            Text(Strings.Guides.setupAndroidRelaunch).font(.system(size: 13, weight: .semibold))
        }
    }

    private var helperGuide: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach([Strings.Guides.setupHelperBenefitProxy, Strings.Guides.setupHelperBenefitRestore, Strings.Guides.setupHelperBenefitAuthorization, Strings.Guides.setupHelperBenefitScope], id: \.self) { text in
                Label(text, systemImage: "checkmark.circle")
            }
            if let helperStatus {
                Label(helperStatus.statusText, systemImage: helperStatus.healthy ? "checkmark.shield" : "exclamationmark.shield")
                Text(helperStatus.identifier + " " + helperStatus.version).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button(Strings.Settings.installEnableSystemProxy) { appState.startProxy(); appState.startSystemProxy() }
                .buttonStyle(.borderedProminent).disabled(appState.systemProxyBusy)
            if appState.systemProxyBusy { ProgressView().controlSize(.small) }
            Text(appState.systemProxyMessage ?? "").font(.system(size: 11))
        }
    }

    private var frameworkGuide: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                GuideStep(title: "\(index + 1). " + platform, state: .pending) { Text(step) }
            }
            if !guide.commands.isEmpty { GuideCodeBlock(code: guide.commands) }
            ForEach(guide.links) { link in Link(link.title, destination: link.url) }
        }
    }

    private var installStep: some View {
        GuideStep(title: Strings.Guides.setupInstallRootMac, state: appState.caInstalled ? .complete : .pending) {
            Button(Strings.Guides.setupInstallTrust, action: installCA).disabled(busy)
            if let date = appState.certificateAuthority.caExpiry {
                Text(Strings.Guides.setupExpires + ": " + date.formatted()).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func listenerStep(remote: Bool) -> some View {
        GuideStep(title: remote ? Strings.Guides.setupConfigureWifi : Strings.Guides.setupListener, state: (remote ? remoteReady : appState.proxyRunning) ? .complete : .attention) {
            if remote { Text(Strings.Guides.setupWifiPath) }
            VStack(spacing: 8) {
                connectionRow(Strings.Guides.setupServer, remote ? address : "127.0.0.1")
                connectionRow(Strings.Guides.setupPort, String(appState.listenerPort))
                connectionRow(Strings.Guides.setupAuthentication, Strings.Guides.setupAuthenticationNo)
            }.padding(12).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            if remote && !remoteReady {
                Label(Strings.Guides.setupLocalhostWarning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button(Strings.Guides.setupProxySettings) {
                    appState.settingsTarget = .lan
                    if #available(macOS 14, *) { environment.openSettings() }
                    else { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
                }
            }
            if !appState.proxyRunning { Button(Strings.Tools.startProxyListener) { appState.startProxy() } }
            if remote { Text(Strings.Guides.setupVpnNote).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }

    private func connectionRow(_ name: String, _ value: String) -> some View {
        HStack { Text(name).fontWeight(.semibold).frame(width: 110, alignment: .trailing); Text(value).textSelection(.enabled); Spacer(); copyButton(value) }
    }
    private func copyButton(_ value: String) -> some View {
        Button { appState.copyText(value) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help(Strings.Tools.copyConfigurationExample)
    }
    private func installCA() {
        guard !busy else { return }
        busy = true
        CertInstaller.installSystemWide(authority: appState.certificateAuthority) { _, message in
            busy = false; feedback = message
            appState.refreshCertificateStatus()
        }
    }
    private func refresh() {
        guard !refreshing, !busy else { return }
        appState.refreshCertificateStatus()
        refreshing = true
        let selectedPlatform = platform, authority = appState.certificateAuthority
        let certificate = authority.caCertPath
        Task {
            defer { refreshing = false }
            do {
                if selectedPlatform == "iOS Simulator" {
                    simulatorCount = try await Task.detached { try DeviceAutomation.listSimulators().filter(\.isBooted).count }.value
                } else if selectedPlatform == "Android Emulator" {
                    androidDevices = try await Task.detached { try authority.ensureCA(); return try DeviceAutomation.androidEmulatorDetails(certificatePath: certificate.path) }.value
                } else if selectedPlatform == "Helper" {
                    helperStatus = await Task.detached { SystemProxyController.shared.serviceStatus() }.value
                }
            } catch { feedback = LocalizedErrorPresentation.message(for: error) }
        }
    }
    private func run(_ operation: @escaping @Sendable (String) throws -> String) {
        guard !busy else { return }
        busy = true; feedback = ""
        let authority = appState.certificateAuthority
        let certificate = authority.caCertPath.path
        Task {
            do { feedback = try await Task.detached { try authority.ensureCA(); return try operation(certificate) }.value }
            catch { feedback = setupError(error) }
            busy = false
            refresh()
        }
    }
    private func overrideAndroid(installCertificate: Bool = true, setProxy: Bool = true) {
        let port = appState.listenerPort, restart = reboot
        run { certificate in
            let changed = try DeviceAutomation.overrideAndroidEmulators(certificatePath: certificate, port: port,
                installCertificate: installCertificate, setProxy: setProxy, reboot: restart)
            return Strings.Guides.setupChangedDevices + ": " + changed.joined(separator: ", ")
        }
    }
    private func airDropCertificate() {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyMirror-AirDrop-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("ProxyMirror-CA.cer")
            try appState.certificateAuthority.caDER().write(to: url, options: .atomic)
            guard let sharing = NSSharingService(named: .sendViaAirDrop), sharing.canPerform(withItems: [url]) else {
                feedback = Strings.Guides.setupAirdropUnavailable; return
            }
            sharing.perform(withItems: [url])
        } catch { feedback = LocalizedErrorPresentation.message(for: error) }
    }
}

private func setupError(_ error: Error) -> String {
    if let failure = error as? AndroidEmulatorSetup.Failure {
        switch failure {
        case .invalidInput: return Strings.Guides.setupInvalidState
        case .unsupportedDevice(let serial), .rootUnavailable(let serial): return serial + ": " + Strings.Guides.setupAndroidUnsupported
        case .certificateConflict(let serial): return serial + ": " + Strings.Guides.setupCertificateConflict
        case .proxyChanged(let serial): return serial + ": " + Strings.Guides.setupProxyConflict
        }
    }
    return LocalizedErrorPresentation.message(for: error)
}

private enum GuideState { case pending, complete, attention }
private struct GuideStep<Content: View>: View {
    let title: String
    let state: GuideState
    let content: () -> Content
    init(title: String, state: GuideState, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.state = state; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
                Image(systemName: state == .complete ? "checkmark.circle.fill" : state == .attention ? "exclamationmark.triangle.fill" : "circle")
                    .foregroundStyle(state == .complete ? Color.green : state == .attention ? .orange : .secondary)
                    .accessibilityLabel((state == .complete ? Strings.Guides.setupComplete : state == .attention ? Strings.Guides.setupNeedsAttention : Strings.Guides.setupPending))
            }
            content().font(.system(size: 13))
        }
    }
}
struct GuideTitle: View {
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 34, weight: .thin))
            Divider().frame(height: 5)
        }
    }
}
struct GuideCodeBlock: View {
    let code: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Spacer(); Button(Strings.Tools.copyConfigurationExample) { AppState.shared.copyText(code) }.controlSize(.small) }
            Text(code).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12).foregroundStyle(.white).background(Color(nsColor: .darkGray), in: RoundedRectangle(cornerRadius: 6))
    }
}
private struct CertificateQRCodeView: View {
    @Environment(\.dismiss) private var dismiss
    private var image: NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data("http://proxy.mirror/ssl".utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 164, height: 164))
    }
    var body: some View {
        VStack(spacing: 12) {
            if let image { Image(nsImage: image).interpolation(.none).resizable().frame(width: 164, height: 164) }
            Text(verbatim: "http://proxy.mirror/ssl").font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(20).frame(width: 206, height: 228)
            .overlay(alignment: .topTrailing) {
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction).help(Strings.Tools.close).padding(6)
            }
    }
}
private struct SetupWindowFocusObserver: NSViewRepresentable {
    let refresh: () -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView(refresh: refresh) }
    func updateNSView(_ view: ObserverView, context: Context) { view.refresh = refresh }
    final class ObserverView: NSView {
        var refresh: () -> Void
        private var token: NSObjectProtocol?
        init(refresh: @escaping () -> Void) { self.refresh = refresh; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NotificationCenter.default.removeObserver(token) }
            guard let window else { return }
            token = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in self?.refresh() }
        }
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}
