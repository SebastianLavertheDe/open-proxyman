import SwiftUI

@MainActor
struct PreferencesMCPView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var controller = MCPPreferencesController.shared
    @State private var client = MCPPreferencesController.Client.manual
    @State private var transport = MCPPreferencesController.Transport.stdio

    private var configuration: String? { controller.configuration(client: client, transport: transport) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PreferencesSetting(target: .mcp) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(Strings.Settings.enableMcpServer, isOn: Binding(get: { settings.mcpEnabled }, set: controller.setEnabled))
                    PreferencesHelp(Strings.Settings.startALocalHttpServerForModelContext)
                        .padding(.leading, 19)
                    Label((controller.isRunning ? Strings.Settings.running : Strings.Settings.stopped),
                          systemImage: controller.isRunning ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(controller.isRunning ? Color.green : Color.secondary)
                        .padding(.leading, 23)
                    if let error = controller.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                    if let endpoint = controller.endpoint {
                        Text(endpoint).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled).padding(.leading, 23)
                    }
                    configurationPanel.padding(.leading, 23)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(Strings.Settings.privacy).fontWeight(.semibold)
                PreferencesSetting(target: .mcpPrivacy) {
                    PreferencesToggle(title: Strings.Settings.redactSensitiveDataBeforeSendingToAi, keyPath: \.mcpRedactSensitiveData)
                }
                PreferencesHelp(Strings.Settings.automaticallyRedactSensitiveInformationBeforeSendingItTo)
                    .padding(.leading, 19)
            }
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Text(Strings.Settings.aboutMcpIntegration).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                PreferencesHelp(Strings.Settings.mcpAllowsAiAssistantsToInteractWithProxymirror)
                Link(Strings.Settings.learnMoreAboutMcp, destination: URL(string: "https://modelcontextprotocol.io/introduction")!)
                    .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 10)
        .onAppear { controller.refresh() }
    }

    private var configurationPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Strings.Settings.mcpConfiguration).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $transport) {
                    ForEach(MCPPreferencesController.Transport.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 95)
            }
            Picker("", selection: $client) {
                ForEach(MCPPreferencesController.Client.allCases) { value in
                    Text(value == .manual ? Strings.Settings.manualConfiguration : value.title).tag(value)
                }
            }.labelsHidden().pickerStyle(.segmented)
            HStack {
                Spacer()
                Button {
                    if let configuration { CopyPaste.copy(configuration) }
                } label: { Label(Strings.Settings.copy, systemImage: "doc.on.doc") }
                    .disabled(configuration == nil)
            }
            ScrollView([.horizontal, .vertical]) {
                Text(configuration ?? (settings.mcpEnabled ? Strings.Settings.waitingForMcpConfiguration : Strings.Settings.enableTheMcpServerToViewItsConnection))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .frame(height: 135)
            .background(PreferencesPalette.strip, in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.2)) }
            PreferencesHelp(client == .codex ? Strings.Settings.addThisConfigurationToCodexSMcpConfiguration : Strings.Settings.addThisJsonToYourAiToolS)
        }
    }
}

struct PreferencesToolsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        PreferencesSetting(target: .copyBehavior) {
            VStack(alignment: .leading, spacing: 22) {
                PreferencesSection(title: Strings.Settings.copy) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Text(Strings.Settings.defaultCopyFormat).fontWeight(.medium)
                            Picker("", selection: Binding(get: { settings.defaultCopyFormat }, set: { settings.defaultCopyFormat = $0 })) {
                                ForEach(RequestCode.Format.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden().frame(width: 145)
                            Spacer(minLength: 0)
                        }
                        PreferencesToggle(title: Strings.Settings.addProxyToCopiedCommands, keyPath: \.appendProxyToCommands)
                        PreferencesToggle(title: Strings.Settings.preserveOriginalHeaders, keyPath: \.preserveOriginalHeaders)
                        PreferencesHelp(Strings.Settings.curlPreservesContentLengthAcceptEncodingAndContent)
                    }
                }
                PreferencesSection(title: Strings.Settings.repeatDiagnostics) {
                    VStack(alignment: .leading, spacing: 10) {
                        PreferencesToggle(title: Strings.Settings.disableCachingWhenRepeatingRequests, keyPath: \.noCacheOnRepeat)
                        PreferencesHelp(Strings.Settings.ignoreCachedResultsAndAlwaysFetchAResponse)
                        PreferencesToggle(title: Strings.Settings.addProxymirrorHeaders, keyPath: \.appendDiagnosticHeaders)
                            .padding(.top, 6)
                        PreferencesHelp(Strings.Settings.addDiagnosticHeadersToHttpMessagesProcessedBy)
                    }
                }
            }
        }
    }
}

struct PreferencesPrivacyView: View {
    var body: some View {
        PreferencesSetting(target: .privacy) {
            VStack(alignment: .leading, spacing: 22) {
                PreferencesSection(title: Strings.Settings.sensitiveInformation) {
                    VStack(alignment: .leading, spacing: 12) {
                        PreferencesToggle(title: Strings.Settings.redactSensitiveHeadersWhenCopyingAndExporting, keyPath: \.redactSensitiveHeaders)
                        PreferencesHelp(Strings.Settings.redactAuthorizationCookieSetCookieAndCommonApi)
                        PreferencesToggle(title: Strings.Settings.redactSensitiveDataBeforeSendingToAi, keyPath: \.mcpRedactSensitiveData)
                        PreferencesHelp(Strings.Settings.dataReturnedToAiToolsThroughMcpUses)
                    }
                }
                PreferencesSection(title: Strings.Settings.localData) {
                    VStack(alignment: .leading, spacing: 12) {
                        PreferencesHelp(Strings.Settings.capturedTrafficIsStoredOnThisMacReview)
                        Button(Strings.Settings.openUserDataFolder) { AppDiagnostics.openDataFolder() }
                    }
                }
            }
        }
    }
}

@MainActor
struct PreferencesNetworkExtensionView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        PreferencesSetting(target: .networkExtension) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text(Strings.Settings.networkExtension).fontWeight(.semibold)
                    Text(Strings.Settings.beta).font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(.yellow, in: Capsule())
                }
                PreferencesSection {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(Strings.Settings.enableNetworkExtension).fontWeight(.medium)
                            Label(Strings.Settings.captureHttpAndHttpsTrafficOnThisMac, systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Label(Strings.Settings.noNeedToConfigureAProxyForEach, systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 10)
                        Toggle("", isOn: Binding(get: { appState.transparentProxyNeedsStop }, set: { enabled in
                            if enabled != appState.transparentProxyNeedsStop { appState.toggleTransparentProxy() }
                        }))
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(appState.transparentProxyState == .stopping || appState.proxyRestarting)
                        .accessibilityLabel(Strings.Settings.enableNetworkExtension)
                    }
                }
                VStack(alignment: .leading, spacing: 9) {
                    Label(statusText, systemImage: statusSymbol)
                        .foregroundStyle(TransparentProxyController.isAvailable ? Color.secondary : Color.orange)
                    PreferencesHelp(Strings.Settings.theNetworkExtensionCapturesTrafficAtTheSystem)
                    PreferencesHelp(Strings.Settings.networkExtensionAndSystemProxyCannotRunAt)
                    PreferencesHelp(Strings.Settings.capturesTcpPorts80And443UdpQuic)
                }
                .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .trailing)
                if !TransparentProxyController.isAvailable {
                    PreferencesSection {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(Strings.Settings.signedNetworkExtensionBuildRequired).fontWeight(.semibold)
                            PreferencesHelp(Strings.Settings.thisApplicationBundleDoesNotIncludeTheNetwork)
                            Link(Strings.Settings.viewBuildInstallationInstructions, destination: URL(string: "https://github.com/SebastianLavertheDe/open-proxyman#macos-透明抓包")!)
                        }
                    }
                    .padding(.top, 16)
                }
                if let message = appState.systemProxyMessage {
                    PreferencesHelp(message).padding(.top, 4)
                }
            }
        }
    }

    private var statusText: String {
        guard TransparentProxyController.isAvailable else { return Strings.Settings.thisApplicationBundleDoesNotIncludeTheNetwork2 }
        switch appState.transparentProxyState {
        case .idle: return Strings.Settings.stopped
        case .activating: return Strings.Settings.activatingNetworkExtension
        case .awaitingApproval: return Strings.Settings.waitingForApprovalInMacosSystemSettings
        case .connecting: return Strings.Settings.connectingNetworkExtension
        case .running: return Strings.Settings.running
        case .stopping: return Strings.Settings.stoppingNetworkExtension
        case .failed(let message): return message
        }
    }

    private var statusSymbol: String {
        switch appState.transparentProxyState {
        case .running: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return TransparentProxyController.isAvailable ? "info.circle" : "exclamationmark.triangle.fill"
        }
    }
}

@MainActor
struct PreferencesAdvancedView: View {
    let onConnections: () -> Void
    let onCleanup: () -> Void
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settings = AppSettings.shared
    @State private var helper: SystemProxyController.ServiceStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PreferencesSetting(target: .systemProxy) {
                PreferencesSection(title: Strings.Settings.systemProxy) {
                    VStack(alignment: .leading, spacing: 24) {
                        PreferencesRow(label: Strings.Settings.proxyHelper, labelWidth: 165) {
                            VStack(alignment: .leading, spacing: 8) {
                                if let helper {
                                    Label(helper.statusText,
                                          systemImage: helper.healthy ? "checkmark.circle.fill" : "info.circle")
                                        .foregroundStyle(helper.healthy ? Color.green : Color.secondary)
                                    if helper.installed {
                                        Text(helper.identifier + (helper.version.isEmpty ? "" : " (\(helper.version))"))
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                } else {
                                    ProgressView().controlSize(.mini)
                                }
                                PreferencesHelp(appState.systemProxyActive ? Strings.Settings.yourHttpHttpsProxiesAreCurrentlyManagedBy : Strings.Settings.theProxyHelperIsInstalledWithAdministratorApproval)
                                HStack(spacing: 10) {
                                    Button((helper?.installed == true ? Strings.Settings.uninstall : Strings.Settings.installEnableSystemProxy)) {
                                        if helper?.installed == true { appState.uninstallSystemProxyService() }
                                        else { appState.startProxy(); appState.startSystemProxy() }
                                    }
                                    .disabled(appState.systemProxyBusy || (helper?.installed == true && appState.systemProxyActive))
                                    Menu(Strings.Settings.more) {
                                        Button(Strings.Settings.advancedProxySettings, action: onConnections)
                                        Button((appState.systemProxyActive ? Strings.Settings.restoreSystemProxy : Strings.Settings.setSystemProxy)) {
                                            if appState.systemProxyActive { appState.stopSystemProxy() }
                                            else { appState.startSystemProxy() }
                                        }.disabled(appState.systemProxyBusy)
                                        Divider()
                                        Button(Strings.Settings.refreshStatus, action: refreshHelper)
                                    }.fixedSize()
                                }
                            }
                        }
                        PreferencesRow(label: "", labelWidth: 165) {
                            VStack(alignment: .leading, spacing: 8) {
                                PreferencesToggle(title: Strings.Settings.restorePreviousHttpHttpsProxiesWhenProxymirrorQuits, keyPath: \.restorePreviousSystemProxy)
                                PreferencesHelp(Strings.Settings.requiresTheProxyHelperRestoreTheProxyConfiguration)
                            }
                        }
                    }
                }
            }
            Divider()
            captureSettings
            if let message = appState.systemProxyMessage { PreferencesHelp(message) }
        }
        .onAppear(perform: refreshHelper)
        .onChange(of: appState.systemProxyBusy) { busy in if !busy { refreshHelper() } }
    }

    private var captureSettings: some View {
        PreferencesRow(label: Strings.Settings.capture, labelWidth: 180) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    PreferencesSetting(target: .appleTraffic) {
                        PreferencesToggle(title: Strings.Settings.hideAppleTrafficFromIosSimulators, keyPath: \.hideAppleTraffic)
                    }
                    PreferencesHelp(Strings.Settings.hideRequestsFromKnownAppleBackgroundServicesAnd)
                }
                PreferencesSetting(target: .cleanup) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 12) {
                            PreferencesToggle(title: Strings.Settings.automaticallyRemoveOldRequests, keyPath: \.automaticTrafficCleanup)
                            Button(Strings.Settings.edit, action: onCleanup)
                        }
                        PreferencesHelp(Strings.Settings.removeOlderRequestsWhenMemoryExceedsMbChecking(settings.cleanupMemoryLimitMB, settings.cleanupIntervalMinutes))
                    }
                }
            }
        }
    }

    private func refreshHelper() {
        Task {
            helper = await Task.detached(priority: .utility) { SystemProxyController.shared.serviceStatus() }.value
        }
    }
}

@MainActor
struct PreferencesGitHubView: View {
    let onPublish: () -> Void
    @EnvironmentObject private var appState: AppState
    @State private var hasToken = false
    @State private var feedback: String?

    var body: some View {
        PreferencesSetting(target: .github) {
            VStack(alignment: .leading, spacing: 22) {
                PreferencesSection(title: "GitHub Gist") {
                    VStack(alignment: .leading, spacing: 12) {
                        PreferencesHelp(Strings.Settings.publishSelectedRequestsAsHarToGithubGist)
                        Label((hasToken ? Strings.Settings.aGithubTokenIsSavedInKeychain : Strings.Settings.noGithubTokenIsSaved),
                              systemImage: hasToken ? "checkmark.circle.fill" : "key")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(Strings.Settings.publishSelectedRequests, action: onPublish)
                                .disabled(appState.activeStore.selectedTransactions.isEmpty)
                            Button(Strings.Settings.removeSavedToken) {
                                do { try GistService.deleteToken(); hasToken = false; feedback = Strings.Settings.removed }
                                catch { feedback = LocalizedErrorPresentation.message(for: error) }
                            }.disabled(!hasToken)
                        }
                        if appState.activeStore.selectedTransactions.isEmpty {
                            PreferencesHelp(Strings.Settings.selectTheRequestsToShareInTheMain)
                        }
                        if let feedback { PreferencesHelp(feedback) }
                    }
                }
                PreferencesHelp(Strings.Settings.githubIntegrationUsesATokenWithGistsWrite)
            }
        }
        .onAppear {
            guard ProcessInfo.processInfo.environment["PM_SETTINGS_SNAPSHOT"] == nil else { return }
            hasToken = (try? GistService.savedToken()) != nil
        }
    }
}

@MainActor
struct PreferencesWorkspaceView: View {
    let onBackup: () -> Void
    @EnvironmentObject private var appState: AppState

    var body: some View {
        PreferencesSetting(target: .workspace) {
            VStack(alignment: .leading, spacing: 22) {
                PreferencesSection(title: Strings.Settings.workspace) {
                    VStack(alignment: .leading, spacing: 12) {
                        PreferencesHelp(Strings.Settings.createIndependentViewsOfCapturedTrafficEachRetaining)
                        Text(Strings.Settings.thereAreCurrentlyViews(appState.tabs.count)).foregroundStyle(.secondary)
                        HStack {
                            Button(Strings.Settings.newView) { appState.addWorkspace() }
                            Button(Strings.Settings.toggleSplitView) { appState.toggleSplit() }
                        }
                    }
                }
                PreferencesSection(title: Strings.Settings.sessionsBackups) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button(Strings.Settings.saveSession) { appState.saveSession() }
                            Button(Strings.Settings.openSession) { appState.openSession() }
                            Button(Strings.Settings.rulesSettingsBackup, action: onBackup)
                        }
                        Button(Strings.Settings.openBackupFolder) { AppDiagnostics.openDataFolder(backups: true) }
                        PreferencesHelp(Strings.Settings.workspacesAndSessionsStayOnThisMacExport)
                    }
                }
            }
        }
    }
}

@MainActor
struct PreferencesProductView: View {
    let onUpdates: () -> Void

    var body: some View {
        PreferencesSetting(target: .products) {
            PreferencesSection(title: "ProxyMirror") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("ProxyMirror").font(.title3).fontWeight(.semibold)
                            Text((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? Strings.Settings.developmentBuild)
                                .foregroundStyle(.secondary)
                        }
                    }
                    PreferencesHelp(Strings.Settings.aNativeMacosHttpHttpsTrafficCaptureAnd)
                    HStack(spacing: 18) {
                        Button(Strings.Settings.checkForUpdates, action: onUpdates)
                        Link(Strings.Settings.sourceCode, destination: URL(string: "https://github.com/SebastianLavertheDe/open-proxyman")!)
                        Link(Strings.Settings.releases, destination: AppUpdateController.releasesURL)
                    }
                }
            }
        }
    }
}
