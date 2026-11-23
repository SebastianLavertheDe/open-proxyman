import ProxyMirrorSystemProxy
import SwiftUI

struct SystemBypassProxyView: View {
    @EnvironmentObject private var appState: AppState
    @State private var useCustom = SystemProxyBypass.savedHosts != nil
    @State private var hosts = SystemProxyBypass.savedHosts ?? []
    @State private var newHost = ""
    @State private var services: [SystemProxyBypass.Service] = []
    @State private var applying = false
    @State private var feedback: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Strings.Settings.systemProxyBypass).font(.headline)
            Toggle(Strings.Settings.useACustomBypassListWhileTheSystem, isOn: $useCustom)
            if useCustom {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(hosts.indices, id: \.self) { index in
                            HStack {
                                Text(hosts[index]).font(.system(.caption, design: .monospaced))
                                Spacer()
                                Button { hosts.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).accessibilityLabel(Strings.Settings.removeBypass(hosts[index]))
                            }
                        }
                    }.frame(maxWidth: .infinity)
                }.frame(height: min(120, max(30, CGFloat(hosts.count) * 24)))
                    .padding(6).overlay(Rectangle().strokeBorder(.quaternary))
                HStack {
                    TextField("*.example.com / 10.0.0.0/8", text: $newHost).onSubmit(add)
                    Button(Strings.Settings.add, action: add).disabled(newHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(Strings.Settings.copyCurrentServiceList) {
                        hosts = SystemProxyBypassList.normalized(services.flatMap(\.hosts)); feedback = nil
                    }.disabled(services.isEmpty)
                }
                Text(Strings.Settings.matchingHostsConnectDirectlyAndAreNotCaptured)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(Strings.Settings.settingsAreAppliedByTheSystemProxyHelper)
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup(Strings.Settings.currentNetworkServiceBypassLists) {
                ForEach(services) { service in
                    Text(Strings.Settings.serviceBypassSummary(service.name, service.hosts.isEmpty ? Strings.Settings.empty : service.hosts.joined(separator: ", ")))
                        .font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let feedback { Text(feedback).font(.caption).foregroundStyle(failed ? Color.red : Color.secondary) }
            HStack {
                Button(appState.systemProxyActive ? Strings.Settings.applyToActiveSystemProxy : Strings.Settings.saveForNextCapture, action: apply)
                    .disabled(applying || appState.systemProxyBusy || appState.proxyRestarting)
                if applying { ProgressView().controlSize(.small) }
                Button(Strings.Settings.refresh) { services = SystemProxyBypass.services() }.disabled(applying)
            }
        }
        .onAppear { services = SystemProxyBypass.services() }
        .disabled(applying)
    }

    private func add() {
        let candidate = SystemProxyBypassList.normalized([newHost])
        guard !candidate.isEmpty else { return }
        if let issue = SystemProxyBypass.localizedValidationError(candidate) { feedback = issue; failed = true; return }
        hosts = SystemProxyBypassList.normalized(hosts + candidate)
        newHost = ""; feedback = nil
    }

    private func apply() {
        let desired = useCustom ? SystemProxyBypassList.normalized(hosts) : nil
        if let desired, let issue = SystemProxyBypass.localizedValidationError(desired) { feedback = issue; failed = true; return }
        if appState.systemProxyActive {
            applying = true
            SystemProxyController.shared.updateBypass(desired) { success, message in
                applying = false
                guard success else { feedback = message; failed = true; return }
                complete(desired, active: true)
            }
        } else { complete(desired, active: false) }
    }

    private func complete(_ desired: [String]?, active: Bool) {
        do {
            try SystemProxyBypass.save(desired)
            feedback = active ? Strings.Settings.bypassListAppliedThePreviousConfigurationWillBe : Strings.Settings.savedChangesWillApplyTheNextTimeThe
            failed = false; services = SystemProxyBypass.services()
        } catch { feedback = LocalizedErrorPresentation.message(for: error); failed = true }
    }
}
