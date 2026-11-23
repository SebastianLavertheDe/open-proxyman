import Foundation

/// Shared validation at the app and privileged-service boundary.
package enum SystemProxyBypassList {
    package static func normalized(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        return hosts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    package static func validationError(_ hosts: [String]) -> String? {
        guard hosts.count <= 1024, hosts.reduce(0, { $0 + $1.utf8.count }) <= 64 * 1024 else {
            return "系统代理旁路列表最多 1024 项、合计 64 KiB。"
        }
        let permitted = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_*?:/%")
        for host in hosts {
            guard !host.isEmpty, host.utf8.count <= 255, !host.contains("://"),
                  host.unicodeScalars.allSatisfy({ permitted.contains($0) }) else {
                return "旁路条目无效：\(host)。请填写主机、IP、CIDR 或通配符，勿包含 URL 或空白。"
            }
        }
        return nil
    }
}
