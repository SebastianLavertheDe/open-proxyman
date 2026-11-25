import Foundation

/// Tracks only changes owned by this setup, so recovery also works after a failed command or app restart.
public final class AndroidEmulatorSetup {
    public struct Device: Identifiable, Equatable, Sendable {
        public let serial: String
        public let api: Int
        public let playStore: Bool
        public let rootable: Bool
        public let proxy: String
        public let certificatePresent: Bool
        public var id: String { serial }
        public var supported: Bool { serial.hasPrefix("emulator-") && api > 0 && api < 34 && !playStore && rootable }
    }

    public struct Entry: Codable, Equatable, Sendable {
        public let serial: String
        public let originalProxy: String
        public let appliedProxy: String
        public let certificatePath: String
        public let stagingPath: String
        public let expectedCertificate: String
        public var proxyPending: Bool
        public var certificatePending: Bool
    }

    public enum Failure: LocalizedError, Equatable {
        case invalidInput
        case unsupportedDevice(String)
        case certificateConflict(String)
        case proxyChanged(String)
        case rootUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .invalidInput: return "The Android setup journal or proxy address is invalid."
            case .unsupportedDevice(let serial): return "Unsupported Android emulator: " + serial
            case .certificateConflict(let serial): return "The existing certificate must be preserved on " + serial
            case .proxyChanged(let serial): return "The proxy changed after takeover on " + serial
            case .rootUnavailable(let serial): return "adb root is unavailable on " + serial
            }
        }
    }

    public typealias Command = ([String]) throws -> String
    private let journal: URL
    private let command: Command
    private let lock = NSLock()
    private static let certificatesDirectory = "/system/etc/security/cacerts/"

    public init(journal: URL, command: @escaping Command) {
        self.journal = journal
        self.command = command
    }

    public func entries() throws -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return try load()
    }

    public func devices(certificateHash: String) throws -> [Device] {
        let path = try certificatePath(certificateHash)
        return try command(["devices"]).split(separator: "\n").dropFirst().compactMap { line -> String? in
            let parts = line.split(whereSeparator: \.isWhitespace)
            return parts.count > 1 && parts[1] == "device" ? String(parts[0]) : nil
        }.sorted().map { serial in
            let api = Int(try run(serial, ["shell", "getprop", "ro.build.version.sdk"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let fingerprint = try run(serial, ["shell", "getprop", "ro.build.fingerprint"])
            let flavor = try run(serial, ["shell", "getprop", "ro.build.flavor"])
            let debuggable = try run(serial, ["shell", "getprop", "ro.debuggable"]).trimmingCharacters(in: .whitespacesAndNewlines)
            return Device(serial: serial, api: api,
                          playStore: (fingerprint + flavor).localizedCaseInsensitiveContains("playstore"),
                          rootable: debuggable != "0", proxy: try currentProxy(serial),
                          certificatePresent: try exists(serial, path))
        }
    }

    /// Rechecks current values and persists intent before changing each device.
    /// A hidden staging file plus a non-overwriting hard link keeps partial pushes out of the trust store.
    public func override(_ devices: [Device], certificate: URL, certificateHash: String,
                         proxy: String, installCertificate: Bool = true, setProxy: Bool = true,
                         reboot: Bool = false) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !setProxy || (safeProxy(proxy) && !proxy.isEmpty) else { throw Failure.invalidInput }
        let destination = try certificatePath(certificateHash)
        let supplied = try String(contentsOf: certificate, encoding: .utf8)
        guard !supplied.isEmpty, supplied.utf8.count <= 128 * 1024 else { throw Failure.invalidInput }
        let snapshotDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyMirror-Android-CA-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: snapshotDirectory) }
        let snapshot = snapshotDirectory.appendingPathComponent("certificate.pem")
        try supplied.write(to: snapshot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
        var entries = try load()
        var changed: [String] = []
        for device in devices where device.supported {
            guard !entries.contains(where: { $0.serial == device.serial }) else { continue }
            let previousProxy = try currentProxy(device.serial)
            guard safeProxy(previousProxy) else { throw Failure.invalidInput }
            let present = try exists(device.serial, destination)
            if installCertificate && present {
                let existing = try run(device.serial, ["shell", "cat", destination])
                guard normalized(existing) == normalized(supplied) else { throw Failure.certificateConflict(device.serial) }
            }
            let entry = Entry(serial: device.serial, originalProxy: previousProxy,
                              appliedProxy: setProxy ? proxy : previousProxy,
                              certificatePath: destination,
                              stagingPath: Self.certificatesDirectory + ".proxymirror-" + UUID().uuidString + ".tmp",
                              expectedCertificate: supplied, proxyPending: setProxy && previousProxy != proxy,
                              certificatePending: installCertificate && !present)
            guard entry.proxyPending || entry.certificatePending else { continue }
            entries.append(entry)
            try save(entries)
            if entry.proxyPending {
                _ = try run(device.serial, ["shell", "settings", "put", "global", "http_proxy", proxy])
            }
            if entry.certificatePending {
                try root(device.serial)
                _ = try run(device.serial, ["remount"])
                _ = try run(device.serial, ["push", snapshot.path, entry.stagingPath])
                _ = try run(device.serial, ["shell", "chmod", "644", entry.stagingPath])
                // ln fails if another certificate appeared after our preflight; it never overwrites it.
                _ = try run(device.serial, ["shell", "ln", entry.stagingPath, destination])
            }
            if reboot { _ = try run(device.serial, ["reboot"]) }
            changed.append(device.serial)
        }
        return changed
    }

    /// Each completed recovery step is saved, so later failures do not replay it.
    public func revert(reboot: Bool = false) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        var entries = try load()
        var restored: [String] = []
        while let first = entries.first {
            var entry = first
            try validate(entry)
            if entry.proxyPending {
                let current = try currentProxy(entry.serial)
                guard current == entry.appliedProxy || equivalentProxy(current, entry.originalProxy) else { throw Failure.proxyChanged(entry.serial) }
                if current == entry.appliedProxy {
                    if entry.originalProxy.isEmpty || entry.originalProxy == "null" {
                        _ = try run(entry.serial, ["shell", "settings", "delete", "global", "http_proxy"])
                    } else {
                        _ = try run(entry.serial, ["shell", "settings", "put", "global", "http_proxy", entry.originalProxy])
                    }
                }
                entry.proxyPending = false
                entries[0] = entry
                try save(entries)
            }
            if entry.certificatePending {
                let staged = try exists(entry.serial, entry.stagingPath)
                let installed = try exists(entry.serial, entry.certificatePath)
                if staged {
                    if installed {
                        let ownership = try run(entry.serial, ["shell", "if [ \(entry.stagingPath) -ef \(entry.certificatePath) ]; then echo owned; else echo foreign; fi"])
                        if ownership.trimmingCharacters(in: .whitespacesAndNewlines) == "owned" {
                            let current = try run(entry.serial, ["shell", "cat", entry.certificatePath])
                            guard normalized(current) == normalized(entry.expectedCertificate) else { throw Failure.certificateConflict(entry.serial) }
                            try root(entry.serial)
                            _ = try run(entry.serial, ["remount"])
                            _ = try run(entry.serial, ["shell", "rm", "-f", entry.certificatePath])
                        }
                        // A replacement at the final path belongs to someone else and is preserved.
                    }
                    try root(entry.serial)
                    _ = try run(entry.serial, ["remount"])
                    _ = try run(entry.serial, ["shell", "rm", "-f", entry.stagingPath])
                } else if installed {
                    // Without the staging inode, ownership can no longer be established.
                    throw Failure.certificateConflict(entry.serial)
                }
                entry.certificatePending = false
                entries[0] = entry
                try save(entries)
            }
            if reboot { _ = try run(entry.serial, ["reboot"]) }
            entries.removeFirst()
            try save(entries)
            restored.append(entry.serial)
        }
        return restored
    }

    private func normalized(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func equivalentProxy(_ first: String, _ second: String) -> Bool {
        first == second || (["", "null"].contains(first) && ["", "null"].contains(second))
    }
    private func currentProxy(_ serial: String) throws -> String {
        normalized(try run(serial, ["shell", "settings", "get", "global", "http_proxy"]))
    }
    private func exists(_ serial: String, _ path: String) throws -> Bool {
        normalized(try run(serial, ["shell", "if [ -f \(path) ]; then echo present; fi"])) == "present"
    }
    private func root(_ serial: String) throws {
        _ = try run(serial, ["root"])
        _ = try run(serial, ["wait-for-device"])
        guard normalized(try run(serial, ["shell", "id", "-u"])) == "0" else { throw Failure.rootUnavailable(serial) }
    }
    private func run(_ serial: String, _ arguments: [String]) throws -> String {
        guard !serial.isEmpty, serial.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 95].contains($0) }) else {
            throw Failure.invalidInput
        }
        return try command(["-s", serial] + arguments)
    }
    private func certificatePath(_ hash: String) throws -> String {
        guard hash.count == 8, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.invalidInput }
        return Self.certificatesDirectory + hash + ".0"
    }
    private func safeProxy(_ value: String) -> Bool {
        value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 91, 93, 95].contains($0) }
    }
    private func validate(_ entry: Entry) throws {
        let stagingName = String(entry.stagingPath.dropFirst(Self.certificatesDirectory.count))
        guard safeProxy(entry.originalProxy), safeProxy(entry.appliedProxy),
              entry.certificatePath == (try certificatePath(String(entry.certificatePath.split(separator: "/").last?.prefix(8) ?? ""))),
              entry.stagingPath.hasPrefix(Self.certificatesDirectory), stagingName.hasPrefix(".proxymirror-"),
              stagingName.hasSuffix(".tmp"), UUID(uuidString: String(stagingName.dropFirst(13).dropLast(4))) != nil,
              entry.expectedCertificate.utf8.count <= 128 * 1024 else { throw Failure.invalidInput }
    }
    private func load() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: journal.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: journal.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 256 * 1024 else { throw Failure.invalidInput }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: journal))
        guard entries.count <= 128 else { throw Failure.invalidInput }
        for entry in entries { try validate(entry) }
        return entries
    }
    private func save(_ entries: [Entry]) throws {
        guard entries.count <= 128 else { throw Failure.invalidInput }
        for entry in entries { try validate(entry) }
        let data = try JSONEncoder().encode(entries)
        guard data.count <= 256 * 1024 else { throw Failure.invalidInput }
        let directory = journal.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try data.write(to: journal, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
    }
}
