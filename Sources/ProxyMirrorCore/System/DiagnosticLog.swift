import Foundation

/// Opt-in operational events; payloads, credentials and complete URLs are never logged here.
enum DiagnosticLog {
    private static let queue = DispatchQueue(label: "ProxyMirror.diagnostics", qos: .utility)
    static var fileURL: URL { CertificateAuthority.applicationSupport.appendingPathComponent("Logs/debug.log") }
    static func record(_ event: String) {
        guard UserDefaults.standard.bool(forKey: "diagnostics.debugMode") else { return }
        let line = "\(Date().ISO8601Format()) \(event.replacingOccurrences(of: "\n", with: " "))\n"
        queue.async {
            do {
                let url = fileURL
                let manager = FileManager.default
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
                let count = (try? manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                if count >= 512 * 1024 {
                    let previous = url.deletingLastPathComponent().appendingPathComponent("debug.previous.log")
                    if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
                    try manager.moveItem(at: url, to: previous)
                }
                if !manager.fileExists(atPath: url.path) {
                    guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
                }
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                try file.seekToEnd()
                try file.write(contentsOf: Data(line.utf8))
            } catch { NSLog("[ProxyMirror] 无法写入诊断日志") }
        }
    }
}
