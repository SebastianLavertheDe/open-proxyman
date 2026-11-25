import AppKit
import UniformTypeIdentifiers

/// Exports complete captured buffers, independently of the paged text/hex view.
@MainActor
enum BodyExportService {
    static func save(_ data: Data, contentType: String, filename: String? = nil) {
        let panel = NSSavePanel()
        let type = UTType(mimeType: contentType.split(separator: ";").first.map(String.init) ?? "") ?? .data
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = filename ?? "body.\(type.preferredFilenameExtension ?? "bin")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try PrivateAppFile.write(data, to: url) }
        catch { show(error.localizedDescription) }
    }

    static func temporaryFile(_ data: Data, contentType: String) throws -> URL {
        let type = UTType(mimeType: contentType.split(separator: ";").first.map(String.init) ?? "") ?? .data
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyMirror-Body-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("body.\(type.preferredFilenameExtension ?? "bin")")
        try PrivateAppFile.write(data, to: url)
        return url
    }

    static func open(_ data: Data, contentType: String, reveal: Bool) {
        do {
            let url = try temporaryFile(data, contentType: contentType)
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]); return }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let application = panel.url else { return }
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { Task { @MainActor in show(error.localizedDescription) } }
            }
        } catch { show(error.localizedDescription) }
    }

    static func show(_ message: String) {
        let alert = NSAlert()
        alert.messageText = Strings.Detail.bodyToolsUnavailable
        alert.informativeText = message
        alert.runModal()
    }
}
