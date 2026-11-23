import SwiftUI

struct AccessControlSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var settings = AppSettings.shared
    @State private var enabled = false
    @State private var address = ""
    @State private var rangesText = ""
    @State private var checkAddress = ""
    @State private var feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Strings.Settings.proxyAccessControl).font(.headline)
            Toggle(Strings.Settings.allowApprovedDevicesToConnectToTheLan, isOn: $enabled)
            if enabled {
                Picker(Strings.Settings.localListenAddress, selection: $address) {
                    Text(Strings.Settings.chooseLocalAddress).tag("")
                    ForEach(LANAccess.addresses, id: \.self) { Text($0).tag($0) }
                    if !address.isEmpty, !LANAccess.addresses.contains(address) {
                        Text(Strings.Settings.currentlyUnavailable(address)).tag(address)
                    }
                }
                Text(Strings.Settings.allowedDeviceIpsOrCidrsOnePerLine).font(.callout)
                TextEditor(text: $rangesText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 96)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
                    .accessibilityLabel(Strings.Settings.deviceIpCidrAllowlist)
                Text(Strings.Settings.forExample192168120192168)
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField(Strings.Settings.checkADeviceIp, text: $checkAddress)
                    if !checkAddress.trimmingCharacters(in: .whitespaces).isEmpty {
                        let allowed = (try? NetworkAccessPolicy(ranges: ranges))?.allows(checkAddress) == true
                        Label(allowed ? Strings.Settings.allowed : Strings.Settings.denied, systemImage: allowed ? "checkmark.shield" : "xmark.shield")
                            .foregroundStyle(allowed ? Color.green : Color.secondary)
                    }
                }
                Text(Strings.Settings.useTheSelectedAddressAndPortOnYour(Int(settings.port)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let issue = validation ?? feedback {
                Text(issue).font(.caption).foregroundStyle(validation == nil ? Color.secondary : Color.red)
            }
            Button(Strings.Settings.applyAccessControlListenerSettings, action: save)
                .disabled(validation != nil || appState.systemProxyBusy || appState.proxyRestarting)
        }
        .onAppear(perform: load)
        .onChange(of: appState.proxyRestarting) { running in if !running { load() } }
        .onChange(of: rangesText) { _ in feedback = nil }
        .onChange(of: address) { _ in feedback = nil }
        .onChange(of: enabled) { _ in feedback = nil }
    }

    private var ranges: [String] {
        rangesText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private var validation: String? {
        guard enabled else { return nil }
        if !LANAccess.addresses.contains(address) { return Strings.Settings.chooseAnAvailableLocalLanAddress }
        if ranges.isEmpty { return Strings.Settings.addAtLeastOneAllowedIpOrCidr }
        return NetworkAccessPolicy.localizedValidationError(for: ranges)
    }

    private func load() {
        enabled = settings.lanEnabled
        address = settings.lanAddress
        let values = settings.allowedPeerRanges.isEmpty
            ? (settings.deviceAddress.isEmpty ? [] : [settings.deviceAddress]) : settings.allowedPeerRanges
        rangesText = values.joined(separator: "\n")
    }

    private func save() {
        guard validation == nil else { return }
        do {
            if !enabled {
                settings.lanEnabled = false
                appState.applyAndRestartIfNeeded()
                feedback = Strings.Settings.savedForLocalAccessOnly
                if !appState.proxyRestarting { load() }
                return
            }
            let policy = try NetworkAccessPolicy(ranges: ranges)
            settings.lanEnabled = enabled
            settings.lanAddress = address
            settings.allowedPeerRanges = policy.ranges
            // Retain the legacy device field for older backups and single-device guides.
            if policy.ranges.count == 1, !policy.ranges[0].contains("/"),
               NumericIPAddress(policy.ranges[0])?.bytes.count == 4 {
                settings.deviceAddress = policy.ranges[0]
            }
            appState.applyAndRestartIfNeeded()
            feedback = appState.proxyRunning ? Strings.Settings.appliedRestartingTheListenerClosesExistingDeviceConnections : Strings.Settings.accessControlSavedItTakesEffectWhenListening
            if !appState.proxyRestarting { load() }
        } catch { feedback = LocalizedErrorPresentation.message(for: error) }
    }
}
