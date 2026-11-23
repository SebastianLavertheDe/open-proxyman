import SwiftUI

struct PreferencesGeneralView: View {
    let onAdvanced: () -> Void
    let onUpdates: () -> Void
    let onResetCertificate: () -> Void
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settings = AppSettings.shared
    @State private var portDraft = String(AppSettings.shared.port)
    @State private var portError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            displaySettings
            Divider()
            proxySettings
            Divider()
            behaviorSettings
            Divider()
            PreferencesCertificateCard(onReset: onResetCertificate)
        }
        .padding(.horizontal, 10)
        .onChange(of: settings.port) { value in portDraft = String(value) }
        .disabled(appState.proxyRestarting)
    }

    private var displaySettings: some View {
        VStack(spacing: 12) {
            PreferencesSetting(target: .contentLayout) {
                PreferencesRow(label: Strings.Settings.contentLayout) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("", selection: Binding(get: { settings.contentLayout }, set: { settings.contentLayout = $0 })) {
                            Text(Strings.Settings.vertical).tag("vertical")
                            Text(Strings.Settings.horizontal).tag("horizontal")
                        }.pickerStyle(.radioGroup).labelsHidden()
                        PreferencesHelp(Strings.Settings.arrangeTheRequestAndResponsePanelsVerticallyOr)
                    }
                }
            }
            PreferencesSetting(target: .menuBar) {
                PreferencesRow(label: Strings.Settings.menuBar) {
                    PreferencesToggle(title: Strings.Settings.showProxymirrorInTheMenuBar, keyPath: \.showMenuBarIcon)
                }
            }
            PreferencesSetting(target: .truncation) {
                PreferencesRow(label: Strings.Settings.truncationStyle) {
                    Picker("", selection: Binding(get: { settings.truncationStyle }, set: { settings.truncationStyle = $0 })) {
                        Text(Strings.Settings.head).tag("head")
                        Text(Strings.Settings.middle).tag("middle")
                        Text(Strings.Settings.tail).tag("tail")
                    }.labelsHidden().frame(width: 76)
                }
            }
        }
    }

    private var proxySettings: some View {
        PreferencesRow(label: Strings.Settings.port) {
            VStack(alignment: .leading, spacing: 10) {
                PreferencesSetting(target: .listenPort) {
                    HStack(spacing: 8) {
                        TextField("9090", text: $portDraft)
                            .frame(width: 78).onSubmit(applyPort)
                            .accessibilityLabel(Strings.Settings.proxyPort)
                        if portDraft != String(settings.port) {
                            Button(Strings.Settings.applySettings, action: applyPort)
                                .disabled(validPort == nil || appState.systemProxyBusy)
                        }
                    }
                }
                if let portError { Text(portError).font(.caption).foregroundStyle(.red) }
                PreferencesSetting(target: .autoTakeOver) {
                    VStack(alignment: .leading, spacing: 5) {
                        PreferencesToggle(title: Strings.Settings.overrideSystemProxySettingsAtLaunch, keyPath: \.autoTakeOverSystemProxy)
                        PreferencesHelp(Strings.Settings.setTheHttpAndHttpsProxiesInNetwork)
                    }
                }
                PreferencesSetting(target: .recording) {
                    VStack(alignment: .leading, spacing: 5) {
                        PreferencesToggle(title: Strings.Settings.startRecordingTrafficAtLaunch, keyPath: \.autoStartRecording)
                        PreferencesHelp(Strings.Settings.recordHttpHttpsTrafficAndShowItIn)
                    }
                }
                PreferencesSetting(target: .http2) {
                    VStack(alignment: .leading, spacing: 5) {
                        Toggle(Strings.Settings.useHttp2, isOn: Binding(get: { settings.http2Enabled }, set: {
                            settings.http2Enabled = $0; appState.applyAndRestartIfNeeded()
                        }))
                        PreferencesHelp(Strings.Settings.preferHttp2ForNewHttpsConnectionsFall)
                    }
                }
                Button(Strings.Settings.advancedProxySettings, action: onAdvanced)
                if let error = appState.proxyStartError {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red)
                } else if let message = appState.systemProxyMessage {
                    PreferencesHelp(message)
                }
            }
        }
    }

    private var behaviorSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            PreferencesSetting(target: .appBehavior) {
                PreferencesRow(label: Strings.Settings.application) {
                    VStack(alignment: .leading, spacing: 9) {
                        PreferencesToggle(title: Strings.Settings.warnBeforeQuitting, keyPath: \.warnBeforeQuit)
                        PreferencesToggle(title: Strings.Settings.showUpdateNotificationsAtLaunch, keyPath: \.showUpdateNotifications)
                    }
                }
            }
            PreferencesSetting(target: .language) {
                PreferencesRow(label: Strings.Settings.language) {
                    VStack(alignment: .leading, spacing: 7) {
                        Picker("", selection: Binding(get: { settings.applicationLanguage }, set: { settings.applicationLanguage = $0 })) {
                            Text(Strings.Settings.system).tag("system")
                            Text(Strings.Settings.languageSimplifiedChineseAutonym).tag("zh-Hans")
                            Text(Strings.Settings.languageEnglishAutonym).tag("en")
                        }.labelsHidden().frame(width: 170)
                        PreferencesHelp(Strings.Settings.chooseTheLanguageUsedInProxymirror)
                        PreferencesHelp(Strings.Settings.languageRestartNotice)
                    }
                }
            }
        }
    }

    private var validPort: UInt16? {
        guard let port = UInt16(portDraft.trimmingCharacters(in: .whitespacesAndNewlines)), port >= 1024 else { return nil }
        return port
    }

    private func applyPort() {
        guard let port = validPort else { portError = Strings.Settings.thePortMustBeBetween1024And65535; return }
        portError = nil
        settings.port = port
        appState.applyAndRestartIfNeeded()
        portDraft = String(settings.port)
    }
}

struct PreferencesCertificateCard: View {
    let onReset: () -> Void
    @EnvironmentObject private var appState: AppState
    @State private var status: CertInstaller.CertificateStatus?
    @State private var refreshing = false

    var body: some View {
        PreferencesSetting(target: .caCertificate) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "doc.text.image")
                    .font(.system(size: 35, weight: .light))
                    .foregroundStyle(.orange)
                    .frame(width: 62, height: 54)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay { Rectangle().strokeBorder(Color.orange, lineWidth: 2) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(status?.commonName ?? "ProxyMirror CA").fontWeight(.semibold)
                    if let before = status?.notBefore {
                        Text(Strings.Settings.certificateValidFrom(dateString(before))).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if let after = status?.notAfter {
                        Text(Strings.Settings.certificateValidUntil(dateString(after))).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if let status {
                        Label(status.statusText, systemImage: status.trusted ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .font(.system(size: 11)).foregroundStyle(status.trusted ? Color.green : Color.secondary)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                    HStack(spacing: 8) {
                        Button(Strings.Settings.generateNewCertificate, action: onReset)
                        Menu(Strings.Settings.more) {
                            Button(Strings.Settings.installTrust) { appState.installCACertificate() }
                            Button(Strings.Settings.showInFinder) { appState.revealCAFile() }
                            Button(Strings.Settings.exportCaCertificatePem) { CertInstaller.exportCA(extension: "pem") }
                            Button(Strings.Settings.copySha256Fingerprint) {
                                if let fingerprint = CertificateAuthority.shared.caFingerprintSHA256 { appState.copyText(fingerprint) }
                            }
                            Divider()
                            Button(Strings.Settings.refreshStatus) { refresh() }
                            Button(Strings.Settings.resetCertificate, action: onReset)
                        }.fixedSize()
                        if refreshing { ProgressView().controlSize(.mini) }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 114)
        }
        .id(SettingsSearchTarget.fingerprint)
        .onAppear(perform: refresh)
        .onChange(of: appState.systemProxyMessage) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .proxyMirrorCertificatesChanged)) { _ in refresh() }
    }

    private func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .long
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            let result = await Task.detached(priority: .utility) { CertInstaller.certificateStatus() }.value
            status = result
            refreshing = false
        }
    }
}
