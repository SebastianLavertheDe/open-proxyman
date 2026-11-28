import Foundation

/// One service's exception list, including the exact rules this takeover inserted.
package struct SystemProxyBypassLease: Codable, Equatable {
    private let restoreHosts: [String]?
    private let plainHosts: [String]?
    private let prepended: String?
    private let appended: [String]

    package init(restoreHosts: [String]?, plainHosts: [String]?, captureLocalRequests: Bool, port: UInt16) {
        self.restoreHosts = restoreHosts
        self.plainHosts = plainHosts
        guard captureLocalRequests else {
            prepended = nil
            appended = []
            return
        }

        let hosts = plainHosts ?? []
        let subtract = "<-loopback>"
        prepended = hosts.first?.lowercased() == subtract ? nil : subtract
        // Chromium uses the last matching rule. Keep explicit user rules in order,
        // and protect the listener and non-loopback implicit exceptions after any subtraction.
        let lastSubtraction = hosts.lastIndex { $0.lowercased() == subtract }
        let direct = Set(hosts[(lastSubtraction.map { $0 + 1 } ?? 0)...].map { $0.lowercased() })
        let protected = ["169.254.0.0/16", "fe80::/10", "0.0.0.0/32", "::/128", "::ffff:0.0.0.0/128",
                         "127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"]
        appended = protected.filter { !direct.contains($0) }
    }

    package var installedHosts: [String]? {
        guard prepended != nil || !appended.isEmpty else { return plainHosts }
        return (prepended.map { [$0] } ?? []) + (plainHosts ?? []) + appended
    }

    package func removingCaptureRules(from current: [String]?) -> [String]? {
        if current == installedHosts { return plainHosts }
        guard var remaining = current else { return nil }
        // Preserve externally appended/prepended duplicates at their new position.
        if let installed = installedHosts, !installed.isEmpty, remaining.count > installed.count {
            if remaining.starts(with: installed) { return (plainHosts ?? []) + remaining.dropFirst(installed.count) }
            if remaining.suffix(installed.count).elementsEqual(installed) {
                return remaining.dropLast(installed.count) + (plainHosts ?? [])
            }
        }
        let plain = plainHosts ?? []
        // A pre-existing occurrence can have the same spelling as a generated rule.
        // Remove at most the single extra occurrence, from the side where it was added.
        func removeExtra(_ rule: String, fromStart: Bool) {
            let explicitCount = plain.filter { $0 == rule }.count
            guard remaining.filter({ $0 == rule }).count > explicitCount else { return }
            let index = fromStart ? remaining.firstIndex(of: rule) : remaining.lastIndex(of: rule)
            if let index { remaining.remove(at: index) }
        }
        if let prepended { removeExtra(prepended, fromStart: true) }
        for rule in appended { removeExtra(rule, fromStart: false) }
        return remaining
    }

    package func restoredHosts(from current: [String]?) -> [String]? {
        // A custom replacement is owned as a whole only until someone edits it.
        if current == restoreHosts || current == installedHosts { return restoreHosts }
        return removingCaptureRules(from: current)
    }
}
