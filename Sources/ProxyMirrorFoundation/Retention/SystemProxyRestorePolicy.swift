import Foundation

/// Restore only configuration fields still owned by this proxy instance.
package enum SystemProxyRestorePolicy {
    package static func restore(_ current: [String: Any], original: [String: Any], ownedPort: UInt16,
                                ownedBypassLists: [[String]] = [], restorePrevious: Bool = true) -> [String: Any] {
        var result = current
        let groups = [["HTTPEnable", "HTTPProxy", "HTTPPort"], ["HTTPSEnable", "HTTPSProxy", "HTTPSPort"]]
        for keys in groups where (current[keys[0]] as? NSNumber)?.intValue == 1
            && current[keys[1]] as? String == "127.0.0.1"
            && (current[keys[2]] as? NSNumber)?.intValue == Int(ownedPort) {
            if restorePrevious {
                for key in keys { result[key] = original[key] }
            } else {
                result[keys[0]] = 0
                result.removeValue(forKey: keys[1])
                result.removeValue(forKey: keys[2])
            }
        }
        let exceptions = "ExceptionsList"
        if let hosts = current[exceptions] as? [String], ownedBypassLists.contains(hosts) {
            result[exceptions] = original[exceptions]
        }
        return result
    }
}
