import AppKit
import ProxyMirrorFoundation

@MainActor
enum SessionImportGuide {
    /// Return before attempting to read a Proxyman directory package as a file.
    static func presentIfNeeded(_ url: URL) -> Bool {
        guard SessionImportCompatibility.needsProxymanConversion(url) else { return false }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = Strings.Compatibility.importTitle
        alert.informativeText = Strings.Compatibility.importInstructions + "\n\n" +
            SessionImportCompatibility.exportCommand + "\n\n" + url.lastPathComponent
        alert.addButton(withTitle: Strings.Common.close)
        alert.addButton(withTitle: Strings.Compatibility.copyExportCommand)
        alert.addButton(withTitle: Strings.Compatibility.openDocumentation)
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(SessionImportCompatibility.exportCommand, forType: .string)
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(SessionImportCompatibility.documentationURL)
        default: break
        }
        return true
    }
}
