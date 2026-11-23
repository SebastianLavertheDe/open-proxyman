import Foundation

/// Per-message diagnostic metadata. The preference is captured when a request
/// starts, so toggling it cannot change the second half of an in-flight exchange.
/// Both protocol adapters use the same policy and preserve user-supplied fields.
struct DiagnosticHeaders {
    enum Source: String {
        case mapLocal = "Map Local"
        case mapRemote = "Map Remote"
        case scripting = "Scripting"
        case breakpoint = "Breakpoint"
        case block = "Block / Allow"
    }

    let requestID: UUID
    let enabled: Bool
    let version: String
    private(set) var sources: [Source] = []

    init(requestID: UUID = UUID(), enabled: Bool? = nil,
         version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development") {
        self.requestID = requestID
        self.enabled = enabled ?? UserDefaults.standard.bool(forKey: "proxy.appendDiagnosticHeaders")
        self.version = version.utf8.contains(where: { $0 == 10 || $0 == 13 }) ? "development" : version
    }

    mutating func record(_ source: Source) {
        if !sources.contains(source) { sources.append(source) }
    }

    func appending(to original: HTTPHeaders) -> HTTPHeaders {
        guard enabled, !sources.isEmpty else { return original }
        var headers = original
        let fields = [
            ("X-ProxyMirror", "Rule"),
            ("X-ProxyMirror-Rule", sources.map(\.rawValue).joined(separator: ", ")),
            ("X-ProxyMirror-Request-ID", requestID.uuidString),
            ("X-ProxyMirror-Version", version),
        ]
        for (name, value) in fields where !headers.contains(name) {
            headers.append(name, value)
        }
        return headers
    }
}
