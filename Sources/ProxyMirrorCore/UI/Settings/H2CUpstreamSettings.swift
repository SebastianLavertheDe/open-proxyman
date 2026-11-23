import SwiftUI

struct H2CUpstreamSettings: View {
    @State private var draft = InterceptionConfig.shared.h2cUpstream.value
    @State private var hosts = InterceptionConfig.shared.h2cUpstream.value.hosts.joined(separator: ", ")
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(Strings.Settings.useCleartextHttp2UpstreamH2c, isOn: $draft.enabled)
            if draft.enabled {
                TextField(Strings.Settings.targetHostsSeparatedByCommas, text: $hosts)
                Text(Strings.Settings.enterHostsThatSupportH2cUsedWhenForwarding)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(Strings.Settings.applyH2cSettings) {
                draft.hosts = hosts.components(separatedBy: CharacterSet(charactersIn: ",，\n")).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }.filter { !$0.isEmpty }
                var backup = RulesStore.shared.backup()
                backup.h2c = draft
                do { try RulesStore.shared.install(backup); failed = false }
                catch { failed = true }
                message = failed ? Strings.Settings.saveFailed : Strings.Settings.h2cSettingsAppliedToNewTraffic
            }
            .disabled(draft.enabled && hosts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let message { Text(message).font(.caption).foregroundStyle(failed ? .red : .secondary) }
        }
    }
}
