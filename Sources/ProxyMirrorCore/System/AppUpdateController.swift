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
            throw ConfigurationError(OperationIssue.appUpdateControllerTheSignedUpdateFeedMustUseAValid)
        }
        guard let bytes = Data(base64Encoded: key), bytes.count == 32 else {
            throw ConfigurationError(OperationIssue.appUpdateControllerTheUpdatePublicKeyMustBeABase64)
        }
        return AppUpdateConfiguration(feedURL: url, publicKey: key)
    }

    struct ConfigurationError: LocalizedError, OperationIssueProviding {
        let operationIssue: OperationIssue
        init(_ issue: OperationIssue) { operationIssue = issue }
        init(_ message: String) { operationIssue = .technical(message) }
        var message: String { operationIssue.diagnostic }
        var text: String { operationIssue.diagnostic }
        var errorDescription: String? { operationIssue.diagnostic }
    }
}

/// Distribution builds use Sparkle; other builds check public release metadata and
/// let the user open its download page. Neither path installs without user action.
@MainActor
final class AppUpdateController: ObservableObject {
    static let shared = AppUpdateController()
    static let releasesURL = URL(string: "https://github.com/SebastianLavertheDe/open-proxyman/releases")!

    @Published private(set) var automaticUpdatesAvailable = false
    @Published private(set) var canCheckForUpdates = true
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var lastUpdateCheck: Date?
    @Published private(set) var status = Strings.Errors.appUpdateControllerCheckProjectReleasesForNewVersions
    @Published private(set) var configuredFeed: URL?
    @Published private(set) var availableRelease: ReleaseUpdate?
    private var started = false
    private var publicCheck: Task<Void, Never>?
    private var checkTimer: Timer?
    private var lastNotificationPreference: Bool?
    var supportsAutomaticChecks: Bool { started }
    private var subscriptions = Set<AnyCancellable>()
    #if canImport(Sparkle)
    private var sparkleController: SPUStandardUpdaterController?
    #endif

    var checkMenuTitle: String {
        Strings.Errors.appUpdateControllerCheckForUpdates
    }

    /// Call once after applicationDidFinishLaunching, or let the first UI action start it.
    func startIfConfigured() {
        guard !started else { return }
        started = true
        do {
            guard let configuration = try AppUpdateConfiguration.read(Bundle.main.infoDictionary ?? [:]) else {
                startPublicChecks()
                return
            }
            configuredFeed = configuration.feedURL
            guard Bundle.main.bundleURL.pathExtension.lowercased() == "app" else {
                startPublicChecks()
                return
            }
            #if canImport(Sparkle)
            let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
            sparkleController = controller
            // SPUUpdater.start() reports configuration errors instead of silently advertising readiness.
            try controller.updater.start()
            automaticUpdatesAvailable = true
            status = Strings.Errors.appUpdateControllerSparkleVerifiesSignedUpdatesAutomaticChecksDoNot
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
            startPublicChecks()
            #endif
            updateNotificationPreference()
        } catch {
            automaticUpdatesAvailable = false
            canCheckForUpdates = true
            status = Strings.Errors.appUpdateControllerSignedUpdatesAreCurrentlyUnavailable(LocalizedErrorPresentation.message(for: error))
            startPublicChecks()
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
        checkPublicReleases(manual: true)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        startIfConfigured()
        #if canImport(Sparkle)
        if automaticUpdatesAvailable, let sparkleController {
            sparkleController.updater.automaticallyChecksForUpdates = enabled
            automaticallyChecksForUpdates = sparkleController.updater.automaticallyChecksForUpdates
        }
        #endif
        if AppSettings.shared.showUpdateNotifications != enabled { AppSettings.shared.showUpdateNotifications = enabled }
        updateNotificationPreference()
    }

    func updateNotificationPreference() {
        guard started else { return }
        let enabled = AppSettings.shared.showUpdateNotifications
        guard lastNotificationPreference != enabled else { return }
        lastNotificationPreference = enabled
        #if canImport(Sparkle)
        if automaticUpdatesAvailable, let sparkleController {
            sparkleController.updater.automaticallyChecksForUpdates = enabled
            automaticallyChecksForUpdates = enabled
            return
        }
        #endif
        automaticallyChecksForUpdates = enabled
        checkTimer?.invalidate()
        checkTimer = nil
        guard enabled else { return }
        checkPublicReleases(manual: false)
        checkTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in AppUpdateController.shared.checkPublicReleases(manual: false) }
        }
    }

    func stop() {
        checkTimer?.invalidate()
        checkTimer = nil
        publicCheck?.cancel()
        publicCheck = nil
    }

    private func startPublicChecks() {
        status = Strings.Errors.appUpdateControllerCheckProjectReleasesAndNotifyYouAboutNew
        updateNotificationPreference()
    }

    private func checkPublicReleases(manual: Bool) {
        guard publicCheck == nil, ProcessInfo.processInfo.environment["PM_SETTINGS_SNAPSHOT"] == nil else { return }
        let defaults = UserDefaults.standard
        if !manual, let last = defaults.object(forKey: "updates.lastPublicAttempt") as? Date,
           Date().timeIntervalSince(last) < 6 * 3600 { return }
        defaults.set(Date(), forKey: "updates.lastPublicAttempt")
        canCheckForUpdates = false
        status = Strings.Errors.appUpdateControllerCheckingForUpdates
        publicCheck = Task { @MainActor in
            defer { canCheckForUpdates = true; publicCheck = nil }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            do {
                let (data, response) = try await session.data(for: ReleaseUpdate.request())
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw ReleaseUpdate.Failure.invalidResponse }
                lastUpdateCheck = Date()
                if http.statusCode == 404 {
                    status = Strings.Errors.appUpdateControllerThereAreNoDownloadableReleasesYet
                    if manual { showPublicResult(nil) }
                    return
                }
                guard http.statusCode == 200 else { throw ReleaseUpdate.Failure.http(http.statusCode) }
                let release = try ReleaseUpdate.decode(data)
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                availableRelease = release.isNewer(than: current) ? release : nil
                status = availableRelease == nil ? Strings.Errors.appUpdateControllerYouAreUpToDate : Strings.Errors.appUpdateControllerVersionIsAvailable(release.tag)
                if manual || (availableRelease != nil && AppSettings.shared.showUpdateNotifications
                    && defaults.string(forKey: "updates.lastNotifiedRelease") != release.tag) {
                    showPublicResult(availableRelease)
                    if availableRelease != nil { defaults.set(release.tag, forKey: "updates.lastNotifiedRelease") }
                }
            } catch is CancellationError {
                return
            } catch {
                status = Strings.Errors.appUpdateControllerUpdateCheckFailed(LocalizedErrorPresentation.message(for: error))
                if manual { showPublicResult(nil) }
            }
        }
    }

    private func showPublicResult(_ release: ReleaseUpdate?) {
        let alert = NSAlert()
        alert.messageText = release.map { Strings.Errors.appUpdateControllerVersionIsAvailable($0.tag) } ?? (Strings.Errors.appUpdateControllerSoftwareUpdates)
        alert.informativeText = (status)
        alert.addButton(withTitle: (release == nil ? Strings.Errors.appUpdateControllerOk : Strings.Errors.appUpdateControllerDownload))
        if release != nil { alert.addButton(withTitle: (Strings.Errors.appUpdateControllerLater)) }
        if alert.runModal() == .alertFirstButtonReturn, let release { NSWorkspace.shared.open(release.page) }
    }

    func openReleaseNotes() {
        if !NSWorkspace.shared.open(Self.releasesURL) { status = Strings.Errors.appUpdateControllerUnableToOpenTheBrowserVisitTheProject }
    }
}
