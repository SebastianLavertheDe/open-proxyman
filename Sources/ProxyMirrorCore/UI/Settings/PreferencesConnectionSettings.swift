import SwiftUI

private enum PreferencesConnectionTool: String, Identifiable {
    case applications, certificates
    var id: String { rawValue }
}

@MainActor
struct PreferencesConnectionSettings: View {
    let target: SettingsSearchTarget?
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    @State private var excludedHostsText = AppSettings.shared.mitmExcludedHosts.joined(separator: "\n")
    @State private var tool: PreferencesConnectionTool?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(Strings.Settings.advancedProxySettings2).font(.headline)
                Spacer()
                Button(Strings.Settings.done) { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(18)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        PreferencesSetting(target: .autoStart) {
                            PreferencesToggle(title: Strings.Settings.startTheProxyListenerAtLaunch, keyPath: \.autoStartProxy)
                        }
                        PreferencesSetting(target: .lan) {
                            PreferencesSection(title: Strings.Settings.listenerAccessControl) { AccessControlSettingsView() }
                        }
                        PreferencesSetting(target: .applyListener) {
                            Button(Strings.Settings.applyListenerSettings) { appState.applyAndRestartIfNeeded() }
                                .disabled(settings.lanAccess?.valid == false || appState.systemProxyBusy)
                        }
                        captureSettings
                        sslSettings
                        PreferencesSetting(target: .clientCertificate) {
                            PreferencesSection(title: Strings.Settings.clientCertificates) { ClientTLSIdentitySettings() }
                        }
                        PreferencesSetting(target: .bypassProxy) {
                            PreferencesSection(title: Strings.Settings.systemProxyBypass) { SystemBypassProxyView() }
                        }
                        PreferencesSetting(target: .upstreamProxy) {
                            PreferencesSection { ExternalProxySettings() }
                        }
                        PreferencesSetting(target: .restart) {
                            HStack {
                                Spacer()
                                Button((appState.proxyRunning ? Strings.Settings.applyRestartProxy : Strings.Settings.applySettings)) {
                                    appState.applyAndRestartProxy()
                                }.buttonStyle(.borderedProminent)
                            }
                        }
                        if let message = appState.systemProxyMessage { PreferencesHelp(message) }
                    }.padding(22)
                }
                .onAppear {
                    guard let target else { return }
                    DispatchQueue.main.async { proxy.scrollTo(target.id, anchor: .top) }
                }
            }
        }
        .frame(width: 780, height: 660)
        .font(.system(size: 13)).controlSize(.small)
        .disabled(appState.proxyRestarting)
        .sheet(item: $tool) { destination in
            switch destination {
            case .applications: SSLApplicationRulesView(transaction: nil).environmentObject(appState)
            case .certificates: CustomCertificateView().environmentObject(appState)
            }
        }
        .onChange(of: settings.mitmExcludedHosts) { hosts in
            if AppState.mitmExcludedHosts(from: excludedHostsText) != hosts { excludedHostsText = hosts.joined(separator: "\n") }
        }
    }

    private var captureSettings: some View {
        PreferencesSection(title: Strings.Settings.captureAppearance) {
            VStack(alignment: .leading, spacing: 14) {
                PreferencesSetting(target: .followLatest) {
                    Toggle(Strings.Settings.followLatestRequest, isOn: Binding(get: { settings.followLatest }, set: appState.setFollowLatest))
                }
                PreferencesSetting(target: .bodyLimit) {
                    Stepper(Strings.Settings.bodyCaptureLimitMb(settings.maxBodyMB),
                            value: Binding(get: { settings.maxBodyMB }, set: { settings.maxBodyMB = $0; appState.applyAndRestartIfNeeded() }), in: 1...100)
                }
                PreferencesSetting(target: .transactionLimit) {
                    Stepper(Strings.Settings.maximumRetainedRequests(settings.maxTransactions),
                            value: Binding(get: { settings.maxTransactions }, set: { settings.maxTransactions = $0; appState.applyAndRestartIfNeeded() }), in: 100...50_000, step: 500)
                }
            }
        }
    }

    private var sslSettings: some View {
        PreferencesSection(title: "SSL / HTTPS") {
            VStack(alignment: .leading, spacing: 14) {
                PreferencesSetting(target: .decryptHTTPS) {
                    Toggle(Strings.Settings.enableHttpsDecryptionMitm, isOn: Binding(get: { settings.mitmEnabled }, set: {
                        settings.mitmEnabled = $0; appState.applyAndRestartIfNeeded()
                    }))
                }
                PreferencesSetting(target: .h2c) {
                    H2CUpstreamSettings().disabled(!settings.http2Enabled || !settings.mitmEnabled)
                }
                Divider()
                PreferencesSetting(target: .excludedHosts) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Strings.Settings.hostsExcludedFromDecryptionOnePerLineExample)
                        TextEditor(text: Binding(get: { excludedHostsText }, set: {
                            excludedHostsText = $0; appState.setMITMExcludedHosts($0)
                        }))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 95).border(Color.primary.opacity(0.2))
                    }
                }
                HStack {
                    Button(Strings.Settings.configureSslByApplication) { tool = .applications }
                    Button(Strings.Settings.certificateImportWizard) { CertificateToolWindows.showImporter() }
                    Button(Strings.Settings.customServerCertificatesByDomain) { tool = .certificates }
                }
            }
        }
    }
}

struct PreferencesCleanupSettings: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    @State private var memoryMB = AppSettings.shared.cleanupMemoryLimitMB
    @State private var intervalMinutes = AppSettings.shared.cleanupIntervalMinutes

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(Strings.Settings.automaticallyRemoveOldRequests).font(.headline)
            PreferencesRow(label: Strings.Settings.memoryLimit, labelWidth: 100) {
                Stepper(Strings.Settings.mb(memoryMB), value: $memoryMB, in: 256...65_536, step: 256)
            }
            PreferencesRow(label: Strings.Settings.checkInterval, labelWidth: 100) {
                Stepper(Strings.Settings.minutes(intervalMinutes), value: $intervalMinutes, in: 1...60)
            }
            PreferencesHelp(Strings.Settings.whenMemoryExceedsTheLimitRemoveTheOldest)
            PreferencesHelp(Strings.Settings.removedRequestsCanNoLongerBeViewedOr)
            Divider()
            HStack {
                Spacer()
                Button(Strings.Settings.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(Strings.Settings.save) {
                    settings.cleanupMemoryLimitMB = memoryMB
                    settings.cleanupIntervalMinutes = intervalMinutes
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 13)).controlSize(.small).padding(22).frame(width: 490)
    }
}
