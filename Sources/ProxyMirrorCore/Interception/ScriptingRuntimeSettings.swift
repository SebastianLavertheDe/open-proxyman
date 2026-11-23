import Foundation

struct ScriptEnvironmentConfig: Codable, Equatable {
    var variables: [String: String] = [:]
    var includeSystemEnvironment = false
    var networkWallTimeMilliseconds = 10_000
    var networkRequestTimeoutMilliseconds = 5_000

    init() {}
    private enum CodingKeys: String, CodingKey { case variables, includeSystemEnvironment, networkWallTimeMilliseconds, networkRequestTimeoutMilliseconds }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        variables = try values.decodeIfPresent([String: String].self, forKey: .variables) ?? [:]
        includeSystemEnvironment = try values.decodeIfPresent(Bool.self, forKey: .includeSystemEnvironment) ?? false
        networkWallTimeMilliseconds = min(30_000, max(1000, try values.decodeIfPresent(Int.self, forKey: .networkWallTimeMilliseconds) ?? 10_000))
        networkRequestTimeoutMilliseconds = min(networkWallTimeMilliseconds, max(100, try values.decodeIfPresent(Int.self, forKey: .networkRequestTimeoutMilliseconds) ?? 5_000))
    }
}

/// Configuration and shared state belong to the host, never to a disposable worker.
/// Executions are serialized around state read/commit, so concurrent flows cannot lose increments.
enum ScriptingRuntimeSettings {
    static let executionLock = NSLock()
    private static let configLock = NSLock()
    private static var config = RulesFileIO.load("script-environment.json") ?? ScriptEnvironmentConfig()
    private static var state: [String: Any] = [:]
    static let mockDirective = "// @proxymirror-mock-api\n"

    static var addonsDirectory: URL {
        let url = RulesFileIO.dir.appendingPathComponent("Addons", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return url
    }

    static func configuration() -> ScriptEnvironmentConfig {
        configLock.lock(); defer { configLock.unlock() }
        return config
    }

    static func save(_ value: ScriptEnvironmentConfig) throws {
        guard (1000...30_000).contains(value.networkWallTimeMilliseconds),
              (100...value.networkWallTimeMilliseconds).contains(value.networkRequestTimeoutMilliseconds) else {
            throw RuntimeError("脚本网络总等待需在 1–30 秒内，单请求超时需在 100 毫秒到总等待之间")
        }
        guard value.variables.count <= 256,
              value.variables.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 256 && $0.value.utf8.count <= 8192 }) else {
            throw RuntimeError("环境变量最多 256 项，名称上限 256 字节，值上限 8 KiB")
        }
        let bytes = try JSONEncoder().encode(value)
        let url = RulesFileIO.dir.appendingPathComponent("script-environment.json")
        try PrivateAppFile.write(bytes, to: url)
        configLock.lock(); config = value; configLock.unlock()
    }

    static func resetSharedState() {
        executionLock.lock(); defer { executionLock.unlock() }
        state = [:]
    }

    /// Call only while holding executionLock.
    static func input() throws -> [String: Any] {
        let settings = configuration()
        var environment = settings.includeSystemEnvironment ? ProcessInfo.processInfo.environment : [:]
        environment.merge(settings.variables) { _, replacement in replacement }
        guard (try JSONSerialization.data(withJSONObject: environment)).count <= 256 * 1024 else {
            throw RuntimeError("环境变量总量超过 256 KiB")
        }
        let settingsPort = Int(AppSettings.shared.port)
        let host = AppSettings.shared.lanAddress
        return ["environment": environment, "sharedState": state, "modules": try addons(),
                "networkEnabled": true,
                "network": ["wallTimeMs": settings.networkWallTimeMilliseconds,
                            "requestTimeoutMs": settings.networkRequestTimeoutMilliseconds,
                            "responseLimit": 1024 * 1024, "blockedProxyPort": settingsPort,
                            "blockedProxyHosts": host.isEmpty ? [] : [host]]]

    }

    /// Failed scripts never commit state, including scripts terminated for timeout.
    static func commit(_ output: [String: Any]) throws {
        guard let next = output["sharedState"] as? [String: Any] else { return }
        guard (try JSONSerialization.data(withJSONObject: next)).count <= 256 * 1024 else {
            throw RuntimeError("sharedState 超过 256 KiB")
        }
        state = next
    }

    private static func addons() throws -> [String: String] {
        let root = addonsDirectory.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return [:] }
        var result: [String: String] = [:]
        var total = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, ["js", "json"].contains(url.pathExtension.lowercased()) else { continue }
            guard url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { continue }
            let count = values.fileSize ?? Int.max
            guard result.count < 64, count <= 256 * 1024, total <= 1024 * 1024 - count else {
                throw RuntimeError("Addons 最多 64 个文件、每个 256 KiB、总计 1 MiB")
            }
            let data = try Data(contentsOf: url)
            guard data.count <= 256 * 1024, let source = String(data: data, encoding: .utf8) else {
                throw RuntimeError("Addon 必须是 UTF-8 CommonJS/JSON 文件")
            }
            total += data.count
            result[String(url.path.dropFirst(root.path.count + 1))] = source
        }
        return result
    }

    struct RuntimeError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
