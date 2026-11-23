import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// 在创建设置、规则和 Saved 单例之前升级自有存储；不迁移旧版中文编码。
enum LocalizationStorage {
    static let currentVersion = 2
    static let defaultsVersionKey = "storage.localizationVersion"
    static let markerName = ".localization-storage-version"

    /// 只清理由本应用拥有且不涉及系统代理恢复、凭证和 CA 的数据。
    static let resetEntries = [
        "rules.json", "rewrite.json", "breakpoint.json", "dns.json", "reverse.json",
        "external.json", "h2c.json", "latency.json", "protobuf.json", "rule-organization.json",
        "breakpoint-templates.json", "script-environment.json", "Saved.proxymirror",
        "Saved.folders.json", "SourceFolders.json", "ProtobufSchemas", "Addons", "Backups",
        "Cache", "Caches", "Sessions", "Automation"
    ]

    private static let preferencePrefixes = [
        "ui.", "proxy.", "capture.", "export.", "repeat.", "automation.", "breakpoints.", "updates."
    ]
    private static let preferenceNames: Set<String> = ["pinnedDomains", "caBannerDismissed"]

    static func prepareForApplicationLaunch() throws {
        let directory: URL
        let environment = ProcessInfo.processInfo.environment
        let snapshot = environment["PM_SETTINGS_SNAPSHOT"] != nil
        if let path = environment["PM_SUPPORT_DIR"], path.hasPrefix("/") {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            guard !snapshot else { throw failure("Snapshot mode requires an isolated PM_SUPPORT_DIR.") }
            guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw failure("Application Support directory is unavailable.")
            }
            directory = base.appendingPathComponent("ProxyMirror", isDirectory: true)
        }
        try prepare(defaults: .standard, supportDirectory: directory)
    }

    /// 测试传入隔离的偏好域和目录；失败时不记录完成版本，允许下次重试。
    static func prepare(defaults: UserDefaults, supportDirectory: URL) throws {
        let fm = FileManager.default
        let directory = supportDirectory.standardizedFileURL
        guard directory.isFileURL, directory.path != "/", directory.path != fm.homeDirectoryForCurrentUser.path else {
            throw failure("Refusing to reset a non-application storage directory.")
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let lockURL = directory.appendingPathComponent(".localization-storage.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = flock(descriptor, LOCK_UN) }

        let marker = directory.appendingPathComponent(markerName)
        let storedVersion: Int
        if fm.fileExists(atPath: marker.path) {
            let contents = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = Int(contents) else { throw failure("Invalid application storage version marker.") }
            storedVersion = parsed
        } else { storedVersion = 0 }
        let preferencesVersion = defaults.integer(forKey: defaultsVersionKey)
        guard storedVersion <= currentVersion, preferencesVersion <= currentVersion else {
            throw failure("This application storage was created by a newer version of ProxyMirror.")
        }

        if storedVersion < currentVersion {
            for name in resetEntries {
                let entry = directory.appendingPathComponent(name)
                // 不展开符号链接；removeItem 删除链接本身，不遍历其目标。
                if (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true || fm.fileExists(atPath: entry.path) {
                    try fm.removeItem(at: entry)
                }
            }
        }
        if preferencesVersion < currentVersion {
            for key in defaults.dictionaryRepresentation().keys where
                preferenceNames.contains(key) || preferencePrefixes.contains(where: key.hasPrefix) {
                defaults.removeObject(forKey: key)
            }
        }
        // 标记最后提交；正常重启、切换语言和普通读取失败都不会再次重置。
        if storedVersion != currentVersion {
            try Data("\(currentVersion)\n".utf8).write(to: marker, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        }
        defaults.set(currentVersion, forKey: defaultsVersionKey)
    }

    private static func failure(_ description: String) -> NSError {
        NSError(domain: "ProxyMirror.LocalizationStorage", code: 1,
                userInfo: [NSLocalizedDescriptionKey: description])
    }
}
