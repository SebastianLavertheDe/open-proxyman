import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExternalProxySettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var draft = InterceptionConfig.shared.externalProxy.value
    @State private var port = String(InterceptionConfig.shared.externalProxy.value.port)
    @State private var bypass = InterceptionConfig.shared.externalProxy.value.bypassHosts ?? []
    @State private var newBypassHost = ""
    @State private var includedTargets = InterceptionConfig.shared.externalProxy.value.includedTargets ?? []
    @State private var newIncludedTarget = ""
    @State private var pacChecking = false
    @State private var pacFeedback: String?
    @State private var feedback: String?
    @State private var saveFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Strings.Settings.externalProxy).font(.headline)
            Toggle(Strings.Settings.connectThroughAnExternalProxy, isOn: $draft.enabled)
            if draft.enabled {
                Picker(Strings.Settings.protocol, selection: $draft.mode) {
                    ForEach(ExternalProxyConfig.Mode.allCases, id: \.self) { mode in
                        Text(mode == .http || mode == .https ? "\(mode.rawValue) CONNECT" : mode.rawValue).tag(mode)
                    }
                }
                if draft.mode == .pac {
                    pacSettings
                } else {
                    manualSettings
                }
                Picker(Strings.Settings.routingScope, selection: Binding(get: { draft.effectiveRoutingMode }, set: { draft.routingMode = $0 })) {
                    ForEach(ExternalProxyConfig.RoutingMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }
                if draft.effectiveRoutingMode == .bypass {
                    Text(Strings.Settings.directHosts).fontWeight(.medium)
                    bypassList
                    Text(Strings.Settings.listedHostsConnectDirectlyOtherTargetsUseThe)
                        .font(.caption).foregroundStyle(.secondary)
                } else if draft.effectiveRoutingMode == .inclusive {
                    Text(Strings.Settings.targetsUsingTheUpstreamProxy).fontWeight(.medium)
                    inclusiveList
                    Text(Strings.Settings.forExampleExampleComOrHttpsApiExample)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(Strings.Settings.localhostLocalhost12700081)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let issue = validation ?? feedback {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(validation != nil || saveFailed ? Color.red : Color.secondary)
            }
            Button(Strings.Settings.applyExternalProxySettings) { save() }
                .disabled(validation != nil)
        }
        .onChange(of: draft) { _ in feedback = nil; pacFeedback = nil }
        .onChange(of: port) { _ in feedback = nil }
        .onChange(of: bypass) { _ in feedback = nil }
        .onChange(of: includedTargets) { _ in feedback = nil }
    }

    private var bypassList: some View {
        VStack(spacing: 6) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(bypass.indices, id: \.self) { index in
                        HStack {
                            Text(bypass[index]).font(.system(.caption, design: .monospaced))
                            Spacer()
                            Button { bypass.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).accessibilityLabel(Strings.Settings.removeDirectHost(bypass[index]))
                        }
                    }
                }.frame(maxWidth: .infinity)
            }.frame(height: min(105, max(30, CGFloat(bypass.count) * 22)))
                .padding(5).overlay(Rectangle().strokeBorder(.quaternary))
            HStack {
                TextField(Strings.Settings.hostOrExampleCom, text: $newBypassHost).onSubmit(addBypass)
                Button(Strings.Settings.add, action: addBypass).disabled(newBypassHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var inclusiveList: some View {
        VStack(spacing: 6) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(includedTargets.indices, id: \.self) { index in
                        HStack {
                            Text(includedTargets[index]).font(.system(.caption, design: .monospaced))
                            Spacer()
                            Button { includedTargets.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).accessibilityLabel(Strings.Settings.removeIncludedTarget(includedTargets[index]))
                        }
                    }
                }.frame(maxWidth: .infinity)
            }.frame(height: min(105, max(30, CGFloat(includedTargets.count) * 22)))
                .padding(5).overlay(Rectangle().strokeBorder(.quaternary))
            HStack {
                TextField(Strings.Settings.hostOrFullUrlPattern, text: $newIncludedTarget).onSubmit(addIncludedTarget)
                Button(Strings.Settings.add, action: addIncludedTarget)
                    .disabled(newIncludedTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || includedTargets.count >= 256)
            }
        }
    }

    private func addIncludedTarget() {
        let raw = newIncludedTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = ExternalProxyTarget(raw) else { feedback = Strings.Settings.enterAValidHostOrHttpSUrl; saveFailed = true; return }
        if !includedTargets.contains(target.pattern) { includedTargets.append(target.pattern) }
        newIncludedTarget = ""; feedback = nil
    }

    private func addBypass() {
        let value = newBypassHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return }
        var check = candidate; check.bypassHosts = [value]
        if let issue = check.localizedValidationError { feedback = issue; saveFailed = true; return }
        if !bypass.contains(value) { bypass.append(value) }
        newBypassHost = ""; feedback = nil
    }

    private var pacSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField(Strings.Settings.pacUrl, text: Binding(get: { draft.pacURL ?? "" }, set: { draft.pacURL = $0 }))
                Button(Strings.Settings.choosePacFile) {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.data]
                    if panel.runModal() == .OK { draft.pacURL = panel.url?.absoluteString }
                }
            }
            HStack {
                Button(Strings.Settings.validatePac) {
                    pacChecking = true; pacFeedback = nil
                    ExternalProxyPACValidation.check(candidate) { result in
                        pacChecking = false
                        switch result {
                        case .success(let description): pacFeedback = description
                        case .failure(let error): pacFeedback = Strings.Settings.pacFailureReason(LocalizedErrorPresentation.message(for: error))
                        }
                    }
                }.disabled(pacChecking || candidate.validationError != nil)
                if pacChecking { ProgressView().controlSize(.small) }
            }
            Text((pacFeedback ?? Strings.Settings.supportsDirectProxyAndRoutesExplicitlyIdentifiedAs))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var manualSettings: some View {
        HStack {
            TextField(Strings.Settings.proxyHost, text: $draft.host)
                .accessibilityLabel(Strings.Settings.externalProxyHost)
            TextField(Strings.Settings.port2, text: $port)
                .frame(width: 80)
                .accessibilityLabel(Strings.Settings.externalProxyPort)
        }
        Toggle(Strings.Settings.useUsernameAndPassword, isOn: $draft.useAuth)
        if draft.useAuth {
            HStack {
                TextField(Strings.Settings.username, text: $draft.username)
                SecureField(Strings.Settings.password, text: $draft.password)
            }
            if draft.mode != .https {
                Text(Strings.Settings.thisProtocolSendsCredentialsToTheProxyHttps)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var candidate: ExternalProxyConfig {
        var value = draft
        value.port = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        value.host = ExternalProxyHost(draft.host)?.name ?? draft.host
        value.pacURL = draft.pacURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.mode == .pac { value.useAuth = false }
        value.bypassHosts = bypass.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        value.includedTargets = includedTargets.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return value
    }

    private var validation: String? {
        guard draft.enabled else { return nil }
        if candidate.targetsLoopback(port: Int(settings.port)) {
            return Strings.Settings.theExternalProxyCannotPointToProxymirrorS
        }
        return candidate.localizedValidationError
    }

    private func save() {
        var value = candidate
        if !value.enabled {
            value = InterceptionConfig.shared.externalProxy.value
            value.enabled = false
        }
        if !value.useAuth {
            value.username = ""
            value.password = ""
        }
        do {
            var backup = RulesStore.shared.backup()
            backup.external = value
            try RulesStore.shared.install(backup)
            feedback = value.enabled ? Strings.Settings.externalProxySettingsSavedTheyApplyToNew : Strings.Settings.externalProxyDisabled
            saveFailed = false
        } catch {
            feedback = Strings.Settings.saveFailureReason(LocalizedErrorPresentation.message(for: error))
            saveFailed = true
        }
    }

}
