import AppKit
import Combine
import Foundation
#if canImport(Sparkle)
import Sparkle
#endif

/// Build-time configuration is read from the signed app bundle, never from a remote response.
struct AppUpdateConfiguration: Equatable {
    let feedURL: URL
    let publicKey: String

    static func read(_ information: [String: Any]) throws -> AppUpdateConfiguration? {
        let feed = (information["SUFeedURL"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (information["SUPublicEDKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !feed.isEmpty || !key.isEmpty else { return nil }
        guard let components = URLComponents(string: feed), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.fragment == nil, let url = components.url else {
            throw ConfigurationError("签名更新源必须是有效的 HTTPS URL。")
        }
        guard let bytes = Data(base64Encoded: key), bytes.count == 32 else {
            throw ConfigurationError("更新公钥必须是 Base64 编码的 32 字节 Ed25519 公钥。")
        }
        return AppUpdateConfiguration(feedURL: url, publicKey: key)
    }

    struct ConfigurationError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

/// Real Sparkle checks are enabled only in a configured .app with Sparkle linked and embedded.
/// Source/debug builds retain a working, explicitly manual Releases fallback.
@MainActor
final class AppUpdateController: ObservableObject {
    static let shared = AppUpdateController()
    static let releasesURL = URL(string: "https://github.com/SebastianLavertheDe/open-proxyman/releases")!

    @Published private(set) var automaticUpdatesAvailable = false
    @Published private(set) var canCheckForUpdates = true
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var lastUpdateCheck: Date?
    @Published private(set) var status = "检查更新将打开项目 Releases，如有已发布版本，可手动下载和安装。"
    @Published private(set) var configuredFeed: URL?
    private var started = false
    private var subscriptions = Set<AnyCancellable>()
    #if canImport(Sparkle)
    private var sparkleController: SPUStandardUpdaterController?
    #endif

    var checkMenuTitle: String {
        automaticUpdatesAvailable ? "检查更新…" : "检查更新（打开 Releases）…"
    }

    /// Call once after applicationDidFinishLaunching, or let the first UI action start it.
    func startIfConfigured() {
        guard !started else { return }
        started = true
        do {
            guard let configuration = try AppUpdateConfiguration.read(Bundle.main.infoDictionary ?? [:]) else {
                status = "当前构建未配置签名更新源。检查更新会打开项目 Releases，如有已发布版本，可手动下载和安装。"
                return
            }
            configuredFeed = configuration.feedURL
            guard Bundle.main.bundleURL.pathExtension.lowercased() == "app" else {
                status = "命令行构建使用手动更新。请从已打包的 ProxyMirror.app 使用签名更新。"
                return
            }
            #if canImport(Sparkle)
            let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
            sparkleController = controller
            // SPUUpdater.start() reports configuration errors instead of silently advertising readiness.
            try controller.updater.start()
            automaticUpdatesAvailable = true
            status = "使用 Sparkle 验证签名更新。自动检查不会自动安装更新。"
            controller.updater.publisher(for: \.canCheckForUpdates)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] value in self?.canCheckForUpdates = value }
                .store(in: &subscriptions)
            controller.updater.publisher(for: \.automaticallyChecksForUpdates)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] value in self?.automaticallyChecksForUpdates = value }
                .store(in: &subscriptions)
            controller.updater.publisher(for: \.lastUpdateCheckDate)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] value in self?.lastUpdateCheck = value }
                .store(in: &subscriptions)
            canCheckForUpdates = controller.updater.canCheckForUpdates
            automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
            lastUpdateCheck = controller.updater.lastUpdateCheckDate
            #else
            status = "当前构建未包含 Sparkle。检查更新会打开项目 Releases，如有已发布版本，可手动下载和安装。"
            #endif
        } catch {
            automaticUpdatesAvailable = false
            canCheckForUpdates = true
            status = "签名更新暂不可用：\(error.localizedDescription) 检查更新会打开项目 Releases。"
        }
    }

    func checkForUpdates() {
        startIfConfigured()
        #if canImport(Sparkle)
        if automaticUpdatesAvailable, let sparkleController {
            guard canCheckForUpdates else { return }
            sparkleController.checkForUpdates(nil)
            return
        }
        #endif
        openReleaseNotes()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        startIfConfigured()
        #if canImport(Sparkle)
        guard automaticUpdatesAvailable, let sparkleController else { return }
        // Sparkle persists this preference. Do not overwrite it on every launch or add another defaults key.
        sparkleController.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = sparkleController.updater.automaticallyChecksForUpdates
        #endif
    }

    func openReleaseNotes() {
        if !NSWorkspace.shared.open(Self.releasesURL) { status = "无法打开浏览器，请访问项目 Releases 页面。" }
    }
}
