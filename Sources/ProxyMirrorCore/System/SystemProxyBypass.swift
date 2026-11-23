import Foundation
import ProxyMirrorSystemProxy
import SystemConfiguration

/// Desired takeover configuration; the privileged helper owns all system writes and recovery.
enum SystemProxyBypass {
    static let defaultsKey = "proxy.systemBypassHosts"
    struct Service: Identifiable {
        let id: String
        let name: String
        let hosts: [String]
    }

    static var savedHosts: [String]? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let hosts = try? JSONDecoder().decode([String].self, from: data),
              SystemProxyBypassList.validationError(hosts) == nil else { return nil }
        return hosts
    }

    static func save(_ hosts: [String]?) throws {
        if let hosts {
            if let issue = SystemProxyBypassList.validationFailure(hosts) { throw issue }
            UserDefaults.standard.set(try JSONEncoder().encode(hosts), forKey: defaultsKey)
        } else { UserDefaults.standard.removeObject(forKey: defaultsKey) }
    }

    static func localizedValidationError(_ hosts: [String]) -> String? {
        SystemProxyBypassList.validationFailure(hosts).map { LocalizedErrorPresentation.message(for: $0) }
    }

    static func services() -> [Service] {
        guard let preferences = SCPreferencesCreate(nil, "ProxyMirror" as CFString, nil),
              let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else { return [] }
        return services.compactMap { service in
            guard let id = SCNetworkServiceGetServiceID(service) as String?,
                  let proxy = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { return nil }
            let config = SCNetworkProtocolGetConfiguration(proxy) as? [String: Any] ?? [:]
            return Service(id: id, name: SCNetworkServiceGetName(service) as String? ?? id,
                           hosts: config["ExceptionsList"] as? [String] ?? [])
        }
    }
}
