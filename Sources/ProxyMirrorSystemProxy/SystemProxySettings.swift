import Foundation
import SystemConfiguration

package struct SystemProxyError: LocalizedError {
    package let errorDescription: String?

    package init(_ message: String) { errorDescription = message }
}

package final class SystemProxySettings {
    private static let http = ["HTTPEnable", "HTTPProxy", "HTTPPort"]
    private static let https = ["HTTPSEnable", "HTTPSProxy", "HTTPSPort"]

    private var originals: [String: [String: Any]] = [:]
    private var needsApply = false
    private let port: UInt16
    private let journal: URL?

    package init(port: UInt16, journal: URL? = nil) {
        self.port = port
        self.journal = journal
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
        let settings = SystemProxySettings(port: port, journal: journal)
        settings.originals = originals
        // The previous process may have committed the change without applying it.
        settings.needsApply = true
        return settings
    }

    package func enable() throws {
        try change(recordOriginals: true) { _, old in
            var new = old
            for keys in [Self.http, Self.https] {
                new[keys[0]] = 1
                new[keys[1]] = "127.0.0.1"
                new[keys[2]] = Int(self.port)
            }
            return new
        }
    }

    package func restore() throws {
        guard !originals.isEmpty else { return }
        try change(recordOriginals: false) { id, current in
            guard let original = self.originals[id] else { return nil }
            let restored = Self.restoredConfiguration(current, original: original, ownedPort: self.port)
            return NSDictionary(dictionary: restored).isEqual(to: current) ? nil : restored
        }
        if let journal {
            do { try FileManager.default.removeItem(at: journal) }
            catch CocoaError.fileNoSuchFile {}
        }
        originals.removeAll()
    }

    package static func restoredConfiguration(_ current: [String: Any], original: [String: Any],
                                              ownedPort: UInt16) -> [String: Any] {
        var result = current
        for keys in [http, https] where (current[keys[0]] as? NSNumber)?.intValue == 1 &&
            current[keys[1]] as? String == "127.0.0.1" &&
            (current[keys[2]] as? NSNumber)?.intValue == Int(ownedPort) {
            for key in keys { result[key] = original[key] }
        }
        return result
    }

    private func change(recordOriginals: Bool,
                        edit: (String, [String: Any]) -> [String: Any]?) throws {
        guard let preferences = SCPreferencesCreate(nil, "ProxyMirror" as CFString, nil),
              SCPreferencesLock(preferences, false) else { throw Self.currentError() }
        defer { SCPreferencesUnlock(preferences) }

        guard let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else {
            throw Self.currentError()
        }
        var saved: [String: [String: Any]] = [:]
        for service in services {
            guard let id = SCNetworkServiceGetServiceID(service) as String?,
                  let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
            let old = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
            guard let new = edit(id, old) else { continue }
            guard SCNetworkProtocolSetConfiguration(proto, new as CFDictionary) else { throw Self.currentError() }
            saved[id] = old
        }
        if recordOriginals {
            guard !saved.isEmpty else { throw SystemProxyError("未找到可配置的网络服务。") }
            if let journal {
                let keys = Set(Self.http + Self.https)
                let snapshot = saved.mapValues { $0.filter { keys.contains($0.key) } }
                let data = try PropertyListSerialization.data(
                    fromPropertyList: ["port": Int(port), "originals": snapshot], format: .binary, options: 0)
                try data.write(to: journal, options: .atomic)
            }
            originals = saved
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

    private static func currentError() -> SystemProxyError {
        SystemProxyError(String(cString: SCErrorString(SCError())))
    }
}
