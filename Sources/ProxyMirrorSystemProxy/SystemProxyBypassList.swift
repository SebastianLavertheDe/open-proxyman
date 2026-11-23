import Foundation

/// Shared validation at the app and privileged-service boundary.
package enum SystemProxyBypassList {
    package static func normalized(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        return hosts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    package static func validationError(_ hosts: [String]) -> String? {
        validationFailure(hosts)?.errorDescription
    }

    package static func validationFailure(_ hosts: [String]) -> SystemProxyError? {
        guard hosts.count <= 1024, hosts.reduce(0, { $0 + $1.utf8.count }) <= 64 * 1024 else {
            return SystemProxyError(.bypassTooLarge)
        }
        let permitted = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_*?:/%")
        for host in hosts {
            guard !host.isEmpty, host.utf8.count <= 255, !host.contains("://"),
                  host.unicodeScalars.allSatisfy({ permitted.contains($0) }) else {
                return SystemProxyError(.bypassInvalid, arguments: [String(host.prefix(255))])
            }
        }
        return nil
    }
}
