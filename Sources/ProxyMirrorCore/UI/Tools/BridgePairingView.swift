import SwiftUI

struct BridgePairingView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("应用内捕获配对").font(.headline)
            Text("将配对码粘贴到集成 ProxyMirrorBridgeKit 的调试应用。配对码在本次监听期间有效。")
                .fixedSize(horizontal: false, vertical: true)
            if let code = appState.bridgePairingCode {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Button("复制配对码") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                    Spacer()
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}
