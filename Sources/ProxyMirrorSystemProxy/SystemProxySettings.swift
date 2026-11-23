import Foundation
import SystemConfiguration

package struct SystemProxyError: LocalizedError {
    package let errorDescription: String?
    package init(_ message: String) { errorDescription = message }
}

package final class SystemProxySettings {
    private static let http = ["HTTPEnable", "HTTPProxy", "HTTPPort"]
    private static let https = ["HTTPSEnable", "HTTPSProxy", "HTTPSPort"]
    private static let exceptions = "ExceptionsList"

    private var originals: [String: [String: Any]] = [:]
    private var needsApply = false
    private let port: UInt16
    private let journal: URL?
    private var bypassHosts: [String]?
    /// Retain old and new owned values so recovery is safe even if a commit fails midway.
    private var ownedBypassLists: [[String]] = []

    package init(port: UInt16, journal: URL? = nil, bypassHosts: [String]? = nil) {
        self.port = port; self.journal = journal; self.bypassHosts = bypassHosts
    }

    package static func pendingRestore(at journal: URL) throws -> SystemProxySettings? {
        let data: Data
        do { data = try Data(contentsOf: journal) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        guard let snapshot = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let rawPort = snapshot["port"] as? Int, let port = UInt16(exactly: rawPort), port >= 1024,
              let originals = snapshot["originals"] as? [String: [String: Any]], !originals.isEmpty else {
            throw SystemProxyError("无法读取未完成的系统代理恢复记录。")
        }
        let settings = SystemProxySettings(port: port, journal: journal, bypassHosts: snapshot["bypassHosts"] as? [String])
        settings.originals = originals
        settings.ownedBypassLists = snapshot["ownedBypassLists"] as? [[String]] ?? []
        if let hosts = settings.bypassHosts, !settings.ownedBypassLists.contains(hosts) { settings.ownedBypassLists.append(hosts) }
        guard settings.ownedBypassLists.count <= 128,
              settings.ownedBypassLists.allSatisfy({ SystemProxyBypassList.validationError($0) == nil }) else {
            throw SystemProxyError("系统代理旁路恢复记录无效。")
        }
        settings.needsApply = true
        return settings
    }

    package func enable() throws {
        if let hosts = bypassHosts, let issue = SystemProxyBypassList.validationError(hosts) { throw SystemProxyError(issue) }
        try change(recordOriginals: true, newBypass: bypassHosts, updateOwnership: true) { _, old in
            var new = old
            for keys in [Self.http, Self.https] {
                new[keys[0]] = 1; new[keys[1]] = "127.0.0.1"; new[keys[2]] = Int(self.port)
            }
            if let hosts = self.bypassHosts { new[Self.exceptions] = hosts }
            return new
        }
    }

    package func updateBypass(_ hosts: [String]?) throws {
        if let hosts, let issue = SystemProxyBypassList.validationError(hosts) { throw SystemProxyError(issue) }
        guard !originals.isEmpty else { throw SystemProxyError("请先接管系统代理。") }
        guard hosts == nil || ownedBypassLists.contains(hosts!) || ownedBypassLists.count < 128 else {
            throw SystemProxyError("本次接管已多次修改旁路列表，请先恢复后重新接管。")
        }
        try change(recordOriginals: false, newBypass: hosts, updateOwnership: true) { id, current in
            guard let original = self.originals[id], Self.ownsProxy(current, port: self.port) else { return nil }
            var new = current
            if let hosts { new[Self.exceptions] = hosts }
            else if let currentHosts = current[Self.exceptions] as? [String], self.ownedBypassLists.contains(currentHosts) {
                new[Self.exceptions] = original[Self.exceptions]
            }
            return new
        }
    }

    package func restore() throws {
        guard !originals.isEmpty else { return }
        try change(recordOriginals: false, newBypass: nil, updateOwnership: false) { id, current in
            guard let original = self.originals[id] else { return nil }
            let restored = Self.restoredConfiguration(current, original: original, ownedPort: self.port,
                                                       ownedBypassLists: self.ownedBypassLists)
            return NSDictionary(dictionary: restored).isEqual(to: current) ? nil : restored
        }
        if let journal {
            do { try FileManager.default.removeItem(at: journal) }
            catch CocoaError.fileNoSuchFile {}
        }
        originals.removeAll(); ownedBypassLists.removeAll()
    }

    private static func ownsProxy(_ current: [String: Any], port: UInt16) -> Bool {
        [http, https].contains { keys in
            (current[keys[0]] as? NSNumber)?.intValue == 1 && current[keys[1]] as? String == "127.0.0.1" &&
            (current[keys[2]] as? NSNumber)?.intValue == Int(port)
        }
    }

    package static func restoredConfiguration(_ current: [String: Any], original: [String: Any],
                                              ownedPort: UInt16, ownedBypassLists: [[String]] = []) -> [String: Any] {
        var result = current
        for keys in [http, https] where (current[keys[0]] as? NSNumber)?.intValue == 1 &&
            current[keys[1]] as? String == "127.0.0.1" && (current[keys[2]] as? NSNumber)?.intValue == Int(ownedPort) {
            for key in keys { result[key] = original[key] }
        }
        if let hosts = current[exceptions] as? [String], ownedBypassLists.contains(hosts) {
            result[exceptions] = original[exceptions]
        }
        return result
    }

    private func change(recordOriginals: Bool, newBypass: [String]?, updateOwnership: Bool,
                        edit: (String, [String: Any]) -> [String: Any]?) throws {
        guard let preferences = SCPreferencesCreate(nil, "ProxyMirror" as CFString, nil),
              SCPreferencesLock(preferences, false) else { throw Self.currentError() }
        defer { SCPreferencesUnlock(preferences) }
        guard let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else { throw Self.currentError() }
        var saved: [String: [String: Any]] = [:]
        for service in services {
            guard let id = SCNetworkServiceGetServiceID(service) as String?,
                  let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
            let old = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
            guard let new = edit(id, old) else { continue }
            guard SCNetworkProtocolSetConfiguration(proto, new as CFDictionary) else { throw Self.currentError() }
            saved[id] = old
        }
        if recordOriginals || updateOwnership {
            guard !saved.isEmpty else { throw SystemProxyError("未找到由 ProxyMirror 接管的网络服务。") }
            let retained = recordOriginals ? saved : originals
            var owned = ownedBypassLists
            if let hosts = newBypass, !owned.contains(hosts) { owned.append(hosts) }
            if let journal {
                let keys = Set(Self.http + Self.https + [Self.exceptions])
                let snapshot = retained.mapValues { $0.filter { keys.contains($0.key) } }
                var value: [String: Any] = ["port": Int(port), "originals": snapshot, "ownedBypassLists": owned]
                if let hosts = newBypass { value["bypassHosts"] = hosts }
                let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
                try data.write(to: journal, options: .atomic)
            }
            originals = retained; ownedBypassLists = owned
            if updateOwnership { bypassHosts = newBypass }
        }
        if !saved.isEmpty {
            guard SCPreferencesCommitChanges(preferences) else { throw Self.currentError() }
            needsApply = true
        }
        if needsApply {
            guard SCPreferencesApplyChanges(preferences) else { throw Self.currentError() }
            needsApply = false
        }
    }

    private static func currentError() -> SystemProxyError { SystemProxyError(String(cString: SCErrorString(SCError()))) }
}
