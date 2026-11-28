import AppKit
import Foundation
import ProxyMirrorFoundation

/// The progress window owns the cancellation token until the writer has either
/// committed its atomic replacement or removed its private temporary file.
@MainActor
final class CSVExportJob: NSObject {
    private static var active: [UUID: CSVExportJob] = [:]
    private let id = UUID()
    private let cancellation = WorkCancellation()
    private let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 130),
                                 styleMask: [.titled], backing: .buffered, defer: false)
    private let progress = NSProgressIndicator()
    private let count = NSTextField(labelWithString: "")
    private let cancel = NSButton()

    static func start(_ rows: [CSVExportRecord], to url: URL, dateStyle: AtomicCSVWriter.DateStyle) {
        let job = CSVExportJob(total: rows.count)
        active[job.id] = job
        job.window.center(); job.window.makeKeyAndOrderFront(nil)
        let cancellation = job.cancellation
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try AtomicCSVWriter.write(rows, to: url, dateStyle: dateStyle, cancellation: cancellation) { completed in
                    DispatchQueue.main.async { job.update(completed, total: rows.count) }
                }
            }
            DispatchQueue.main.async { job.complete(result, url: url) }
        }
    }

    private init(total: Int) {
        super.init()
        window.title = Strings.Tools.csvExporting
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 130))
        window.contentView = content
        progress.frame = NSRect(x: 20, y: 76, width: 380, height: 18)
        progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = Double(max(1, total))
        count.frame = NSRect(x: 20, y: 46, width: 250, height: 20)
        count.stringValue = "\(PresentationNumbers.integer(0)) / \(PresentationNumbers.integer(total))"
        cancel.frame = NSRect(x: 304, y: 12, width: 96, height: 30)
        cancel.title = Strings.Tools.cancel; cancel.bezelStyle = .rounded
        cancel.target = self; cancel.action = #selector(cancelExport)
        for view in [progress, count, cancel] as [NSView] { content.addSubview(view) }
    }

    @objc private func cancelExport() { cancellation.cancel(); cancel.isEnabled = false }
    private func update(_ completed: Int, total: Int) {
        progress.doubleValue = Double(completed); count.stringValue = "\(PresentationNumbers.integer(completed)) / \(PresentationNumbers.integer(total))"
    }
    private func complete(_ result: Result<Void, Error>, url: URL) {
        window.close(); Self.active[id] = nil
        switch result {
        case .success: AppState.shared.systemProxyMessage = Strings.Tools.exportedTo1(url.path)
        case .failure(is CancellationError): AppState.shared.systemProxyMessage = Strings.Tools.exportCancelled
        case .failure(let error):
            AppState.shared.systemProxyMessage = Strings.Errors.exportServiceExportFailed("CSV", LocalizedErrorPresentation.message(for: error))
        }
    }
}
