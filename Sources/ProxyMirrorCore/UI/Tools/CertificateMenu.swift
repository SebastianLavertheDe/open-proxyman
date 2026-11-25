import SwiftUI

/// 证书菜单的安装指南弹窗（iOS/Android/Java/Firefox 等平台的证书安装指引）
struct CertificateGuideSheet: View {
    let platform: String
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private var guide: CertificatePlatformGuides.Guide {
        CertificatePlatformGuides.guide(for: platform, certificatePath: appState.certificateAuthority.caCertPath.path,
                                       port: Int(appState.listenerPort))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Strings.Tools.installCertificateOn1(String(describing: platform)))
                .font(.system(size: 14, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                        Text(("\(index + 1). \(step)"))
                            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                    if !guide.commands.isEmpty {
                        Text(guide.commands).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled).padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        Button(Strings.Tools.copyConfigurationExample) { AppState.shared.copyText(guide.commands) }
                    }
                    ForEach(guide.links) { link in Link(link.title, destination: link.url) }
                }
            }.frame(maxHeight: 480)
            HStack {
                Button(Strings.Tools.exportCaCertificate) { CertInstaller.exportCA(extension: "pem") }
                    .buttonStyle(.borderedProminent)
                if platform == "iOS" || CertificatePlatformGuides.simulatorPlatforms.contains(platform) {
                    Button(Strings.Tools.chooseSimulatorInstallCa) { CertificateToolWindows.showSimulatorInstaller(platform: platform) }
                }
                Spacer()
                Button(Strings.Tools.done) { dismiss() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(16)
        .frame(width: 680)
    }
}

/// 证书菜单（对齐 Proxyman：安装/自定义/导出/重置）
struct CertificateMenuContent: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Group {
        Button(Strings.Tools.installCertificateOnThisMac) {
            openWindow(id: "setup-guide", value: "macOS")
        }
        Menu(Strings.Tools.installCertificateOnIos) {
            Button(Strings.Tools.setUpIosSimulator) { openWindow(id: "setup-guide", value: "iOS Simulator") }
            Button(Strings.Tools.chooseSimulatorInstallCa) { CertificateToolWindows.showSimulatorInstaller(platform: "iOS") }
            Button(Strings.Tools.installationGuide) { openWindow(id: "setup-guide", value: "iOS") }
        }
        Menu(Strings.Tools.installCertificateOnAndroid) {
            Button(Strings.Tools.copyUserCaViaAdb) { AppState.shared.prepareAndroidUserCertificate() }
            Button(Strings.Tools.androidEmulatorAutomationAdbRoot) { openWindow(id: "setup-guide", value: "Android Emulator") }
            Button(Strings.Tools.installationGuide) { openWindow(id: "setup-guide", value: "Android") }
        }
        Menu(Strings.Tools.otherApplePlatformsSwiftuiPreview) {
            ForEach(CertificatePlatformGuides.simulatorPlatforms, id: \.self) { platform in
                Menu(platform) {
                    Button(Strings.Tools.chooseDeviceInstallCa) { CertificateToolWindows.showSimulatorInstaller(platform: platform) }
                    Button(Strings.Tools.setupGuide) { openWindow(id: "setup-guide", value: platform) }
                }
            }
        }
        Menu(Strings.Tools.frameworkToolIntegration) {
            ForEach(CertificatePlatformGuides.frameworks, id: \.self) { framework in
                Button(framework + "…") { openWindow(id: "setup-guide", value: framework) }
            }
        }
        Menu(Strings.Tools.installCertificateInJavaVm) {
            Button(Strings.Tools.installationGuide) { openWindow(id: "setup-guide", value: "Java") }
        }
        Menu(Strings.Tools.installCertificateInAndroidDevelopmentBrowser) {
            Button(Strings.Tools.installationGuide) { openWindow(id: "setup-guide", value: "Android") }
        }
        Menu(Strings.Tools.installCertificateInFirefox) {
            Button(Strings.Tools.installationGuide) { openWindow(id: "setup-guide", value: "Firefox") }
        }
        }
        Divider()
        Group {
        Button(Strings.Tools.certificateImportWizardPemDerP12) { CertificateToolWindows.showImporter() }
        Button(Strings.Tools.importUpstreamMtlsIdentity) { CertificateToolWindows.showImporter(purpose: .client) }
        Button(Strings.Guides.setupManageCertificates) { openWindow(id: "certificate-manager") }
        Button(Strings.Tools.importCustomRootCertificatePemPrivateKey) { CertInstaller.importRootCA() }
        Button(Strings.Tools.addCustomCertificate) { CertInstaller.importCustomCertificate() }
        Button(Strings.Tools.importUpstreamCaTrustChainPem) {
            let panel = NSOpenPanel()
            panel.message = Strings.Tools.chooseThePemRootCertificateChainToTrustFor
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try UpstreamTrust.install(Data(contentsOf: url))
                AppState.shared.systemProxyMessage = Strings.Tools.theUpstreamCaTrustChainHasBeenUpdatedFor
            } catch {
                AppState.shared.systemProxyMessage = Strings.Tools.unableToImportTheUpstreamCa1(String(describing: LocalizedErrorPresentation.message(for: error)))
            }
        }
        Button(Strings.Tools.removeCustomUpstreamCaTrustChain) {
            do {
                try UpstreamTrust.reset()
                AppState.shared.systemProxyMessage = Strings.Tools.newUpstreamConnectionsNowUseSystemRootCertificates
            } catch {
                AppState.shared.systemProxyMessage = Strings.Tools.unableToRemoveTheUpstreamCa1(String(describing: LocalizedErrorPresentation.message(for: error)))
            }
        }
        }
        Divider()
        Menu(Strings.Tools.export) {
            Button(Strings.Tools.caCertificatePem) { CertInstaller.exportCA(extension: "pem") }
            Button(Strings.Tools.caCertificateCer) { CertInstaller.exportCA(extension: "cer") }
            Button(Strings.Tools.caCertificateDer) { CertificateToolWindows.showExporter(format: .der) }
            Button(Strings.Tools.encryptedCaPrivateKeyPem) { CertificateToolWindows.showExporter(format: .privateKey) }
            Button(Strings.Tools.caIdentityP12) { CertificateToolWindows.showExporter(format: .p12) }
        }
        Divider()
        Button(Strings.Tools.resetAllProxymirrorCertificates) {
            AppState.shared.showResetCA = true
        }
    }
}

struct GuidePlatformBox: Identifiable {
    let value: String
    var id: String { value }
}

struct ResetCAConfirmView: View {
    let onConfirm: () -> Void
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Strings.Tools.resetAllProxymirrorCertificates2)
                .font(.system(size: 14, weight: .semibold))
            Text(Strings.Tools.theProxymirrorCaWillBeRemovedFromTheKeychain)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(Strings.Tools.cancel) { onConfirm() }.disabled(working)
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Button(Strings.Tools.reset) {
                        working = true
                        errorMessage = nil
                        CertInstaller.resetAll { result in
                            working = false
                            switch result {
                            case .success:
                                appState.caInstalled = false
                                appState.caBannerDismissed = false
                                UserDefaults.standard.set(false, forKey: "caBannerDismissed")
                                appState.systemProxyMessage = Strings.Tools.proxymirrorCaHasBeenResetReinstallAndTrustThe
                                onConfirm()
                            case .failure(let error):
                                errorMessage = Strings.Tools.unableToResetTheCertificate1(String(describing: LocalizedErrorPresentation.message(for: error)))
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .frame(width: 400)
        .interactiveDismissDisabled(working)
    }
}
