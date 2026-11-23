import Darwin
import Foundation
import ProxyMirrorSystemProxy

enum Installer {
    static func install(from source: URL, uid: uid_t, appHash: String) throws {
        guard uid > 0, SystemProxyService.isValidHash(appHash) else {
            throw SystemProxyError(.invalidArguments)
        }
        let lock = try SystemProxyService.acquireLock()
        defer { Darwin.close(lock) }
        let executable = SystemProxyService.executable
        let plist = SystemProxyService.plist
        try verifyDirectory(executable.deletingLastPathComponent(), create: true)
        try verifyDirectory(plist.deletingLastPathComponent(), create: false)
        try SystemProxySettings.pendingRestore(at: SystemProxyService.journal)?.restore()
        let originalExecutable = try readExisting(executable)
        let originalPlist = try readExisting(plist)
        let wasLoaded = try unload()
        let name = SystemProxyService.name
        let definition: [String: Any] = [
            "Label": name,
            "ProgramArguments": SystemProxyService.daemonArguments(uid: uid, appHash: appHash),
            "MachServices": [name: true],
            "AssociatedBundleIdentifiers": [SystemProxyService.appIdentifier],
            "ExitTimeOut": 15,
            "KeepAlive": ["SuccessfulExit": false],
        ]
        do {
            try write(Data(contentsOf: source), to: executable, permissions: 0o755)
            try write(PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0),
                      to: plist, permissions: 0o644)
            try bootstrap()
        } catch {
            do {
                try restore(originalExecutable, at: executable, permissions: 0o755)
                try restore(originalPlist, at: plist, permissions: 0o644)
                if wasLoaded { try bootstrap() }
            } catch {
                NSLog("[ProxyMirror] 回滚系统代理服务安装失败：%@", error.localizedDescription)
            }
            throw error
        }
    }

    static func uninstall() throws {
        let lock = try SystemProxyService.acquireLock()
        defer { Darwin.close(lock) }
        try SystemProxySettings.pendingRestore(at: SystemProxyService.journal)?.restore()
        _ = try unload()
        try remove(SystemProxyService.plist)
        try remove(SystemProxyService.executable)
    }

    private static func verifyDirectory(_ url: URL, create: Bool) throws {
        var info = stat()
        if lstat(url.path, &info) == -1, errno == ENOENT, create {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o755])
        }
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == 0, info.st_mode & 0o022 == 0 else {
            throw SystemProxyError(.invalidDirectory)
        }
    }

    private static func readExisting(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }

    private static func write(_ data: Data, to url: URL, permissions: mode_t) throws {
        try data.write(to: url, options: .atomic)
        guard chown(url.path, 0, 0) == 0, chmod(url.path, permissions) == 0 else {
            throw SystemProxyError(.permissionsFailed)
        }
    }

    private static func remove(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile {}
    }

    private static func restore(_ data: Data?, at url: URL, permissions: mode_t) throws {
        if let data { try write(data, to: url, permissions: permissions) }
        else { try remove(url) }
    }

    private static var target: String { "system/\(SystemProxyService.name)" }

    private static func unload() throws -> Bool {
        guard try launchctl(["print", target]) == 0 else { return false }
        guard try launchctl(["bootout", target]) == 0 else {
            throw SystemProxyError(.stopFailed)
        }
        return true
    }

    private static func bootstrap() throws {
        guard try launchctl(["bootstrap", "system", SystemProxyService.plist.path]) == 0 else {
            throw SystemProxyError(.loadFailed)
        }
    }

    private static func launchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
