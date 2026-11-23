import SwiftUI

struct BridgePairingView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Strings.Tools.inAppCapturePairing).font(.headline)
            Text(Strings.Tools.pasteThePairingCodeIntoADebugApplicationThat)
                .fixedSize(horizontal: false, vertical: true)
            if let code = appState.bridgePairingCode {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Button(Strings.Tools.copyPairingCode) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                    Spacer()
                    Button(Strings.Tools.done) { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}
