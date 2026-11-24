import Foundation
import ProxyMirrorFoundation
import SystemConfiguration

package struct SystemProxyError: LocalizedError {
    package enum Code: String, Codable, CaseIterable, Sendable {
        case invalidPort
        case busy
        case notOwner
        case authorizationRequired
        case invalidArguments
        case signatureInvalid
        case lockUnavailable
        case restoreRecordInvalid
        case bypassRecordInvalid
        case takeoverRequired
        case bypassUpdateLimit
        case noOwnedServices
        case installationFailed
        case invalidDirectory
        case permissionsFailed
        case stopFailed
        case loadFailed
        case bypassTooLarge
        case bypassInvalid
    }
    package let code: Code?
    package let arguments: [String]
    private let detail: String
    package init(_ message: String) { code = nil; arguments = []; detail = message }
    package init(_ code: Code, arguments: [String] = []) {
        self.code = code; self.arguments = arguments
        let format: String
        switch code {
        case .invalidPort: format = "The system proxy port is invalid."
        case .busy: format = "Another ProxyMirror instance is enabling or restoring the system proxy."
        case .notOwner: format = "The current connection does not own the system proxy."
        case .authorizationRequired: format = "The system proxy service requires administrator authorization."
        case .invalidArguments: format = "The system proxy service arguments are invalid."
        case .signatureInvalid: format = "Unable to verify the ProxyMirror or system proxy service signature. Use a complete .app build."
        case .lockUnavailable: format = "Unable to open the system proxy lock."
        case .restoreRecordInvalid: format = "Unable to read the pending system proxy recovery record."
        case .bypassRecordInvalid: format = "The system proxy bypass recovery record is invalid."
        case .takeoverRequired: format = "Enable the system proxy first."
        case .bypassUpdateLimit: format = "The bypass list was changed too many times during this takeover. Restore the proxy and enable it again."
        case .noOwnedServices: format = "No network services owned by ProxyMirror were found."
        case .installationFailed: format = "Unable to start the authorized system proxy installer."
        case .invalidDirectory: format = "The system proxy service directory has an invalid owner or permissions."
        case .permissionsFailed: format = "Unable to set system proxy service file permissions."
        case .stopFailed: format = "Unable to stop the installed system proxy service."
        case .loadFailed: format = "macOS could not load the system proxy service. Check background item permissions in System Settings."
        case .bypassTooLarge: format = "The system proxy bypass list supports up to 1,024 entries and 64 KiB in total."
        case .bypassInvalid: format = "Invalid bypass entry: %@. Enter a host, IP address, CIDR or wildcard without a URL or whitespace."
        }
        detail = String(format: format, locale: Locale(identifier: "en_US_POSIX"), arguments: arguments)
    }
    package var errorDescription: String? { detail }

    /// XPC keeps its String reply ABI, but known errors carry stable codes.
    package var wireValue: String {
        guard let code else { return detail }
        let value = ["version": 1, "domain": "ProxyMirror.SystemProxy", "code": code.rawValue,
                     "arguments": arguments, "detail": detail] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return detail }
        return "pm-error-v1:" + json
    }
    package static func fromWire(_ value: String) -> Self {
        let prefix = "pm-error-v1:"
        guard value.hasPrefix(prefix), value.utf8.count <= 64 * 1024,
              let data = value.dropFirst(prefix.count).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["version"] as? Int == 1, object["domain"] as? String == "ProxyMirror.SystemProxy",
              let raw = object["code"] as? String, let code = Code(rawValue: raw),
              let args = object["arguments"] as? [String], args.count <= 8,
              args.allSatisfy({ $0.utf8.count <= 4096 }),
              (code == .bypassInvalid ? args.count == 1 : args.isEmpty) else { return Self(value) }
        return Self(code, arguments: args)
    }
    package static func wireValue(for error: Error) -> String {
        (error as? Self)?.wireValue ?? error.localizedDescription
    }
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
            throw SystemProxyError(.restoreRecordInvalid)
        }
        let settings = SystemProxySettings(port: port, journal: journal, bypassHosts: snapshot["bypassHosts"] as? [String])
        settings.originals = originals
        settings.ownedBypassLists = snapshot["ownedBypassLists"] as? [[String]] ?? []
        if let hosts = settings.bypassHosts, !settings.ownedBypassLists.contains(hosts) { settings.ownedBypassLists.append(hosts) }
        guard settings.ownedBypassLists.count <= 128,
              settings.ownedBypassLists.allSatisfy({ SystemProxyBypassList.validationError($0) == nil }) else {
            throw SystemProxyError(.bypassRecordInvalid)
        }
        settings.needsApply = true
        return settings
    }

    package func enable() throws {
        if let hosts = bypassHosts, let issue = SystemProxyBypassList.validationFailure(hosts) { throw issue }
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
        if let hosts, let issue = SystemProxyBypassList.validationFailure(hosts) { throw issue }
        guard !originals.isEmpty else { throw SystemProxyError(.takeoverRequired) }
        guard hosts == nil || ownedBypassLists.contains(hosts!) || ownedBypassLists.count < 128 else {
            throw SystemProxyError(.bypassUpdateLimit)
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

    package func restore(previousConfiguration: Bool = true) throws {
        guard !originals.isEmpty else { return }
        try change(recordOriginals: false, newBypass: nil, updateOwnership: false) { id, current in
            guard let original = self.originals[id] else { return nil }
            let restored = Self.restoredConfiguration(current, original: original, ownedPort: self.port,
                                                       ownedBypassLists: self.ownedBypassLists,
                                                       restorePrevious: previousConfiguration)
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
                                              ownedPort: UInt16, ownedBypassLists: [[String]] = [],
                                              restorePrevious: Bool = true) -> [String: Any] {
        SystemProxyRestorePolicy.restore(current, original: original, ownedPort: ownedPort,
                                         ownedBypassLists: ownedBypassLists, restorePrevious: restorePrevious)
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
            guard !saved.isEmpty else { throw SystemProxyError(.noOwnedServices) }
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
