import Foundation
import Combine

/// 应用设置（UserDefaults 持久化）
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let d: UserDefaults

    init(defaults: UserDefaults = .standard) {
        d = defaults
    }

    enum Keys {
        static let port = "proxy.port"
        static let mitmEnabled = "proxy.mitmEnabled"
        static let http2 = "proxy.http2"
        static let mitmExcluded = "proxy.mitmExcludedHosts"
        static let autoStart = "proxy.autoStart"
        static let autoTakeOver = "proxy.autoTakeOverSystemProxy"
        static let maxBodyMB = "capture.maxBodyMB"
        static let maxTransactions = "capture.maxTransactions"
        static let followLatest = "ui.followLatest"
        static let lanEnabled = "proxy.lanEnabled"
        static let lanAddress = "proxy.lanAddress"
        static let deviceAddress = "proxy.deviceAddress"
        static let fontSize = "ui.fontSize"
        static let useMonospacedFont = "ui.useMonospacedFont"
        static let scrollBeyondLastLine = "ui.scrollBeyondLastLine"
        static let contentLayout = "ui.contentLayout"
        static let appIconStyle = "ui.appIconStyle"
        static let autoStartRecording = "capture.autoStartRecording"
        static let warnBeforeQuit = "ui.warnBeforeQuit"
        static let showUpdateNotifications = "updates.showNotifications"
        static let applicationLanguage = "ui.applicationLanguage"
        static let mcpEnabled = "automation.mcpEnabled"
        static let mcpRedactSensitiveData = "automation.mcpRedactSensitiveData"
        static let preserveOriginalHeaders = "export.preserveOriginalHeaders"
        static let restorePreviousSystemProxy = "proxy.restorePreviousSystemProxy"
        static let automaticTrafficCleanup = "capture.automaticTrafficCleanup"
        static let cleanupMemoryLimitMB = "capture.cleanupMemoryLimitMB"
        static let cleanupIntervalMinutes = "capture.cleanupIntervalMinutes"
    }

    var port: UInt16 {
        get { (d.object(forKey: Keys.port) as? Int).flatMap(UInt16.init(exactly:)).flatMap { $0 >= 1024 ? $0 : nil } ?? 9090 }
        set { d.set(Int(newValue), forKey: Keys.port); notifyChange() }
    }

    var mitmEnabled: Bool {
        get { d.object(forKey: Keys.mitmEnabled) as? Bool ?? true }
        set { d.set(newValue, forKey: Keys.mitmEnabled); notifyChange() }
    }

    var http2Enabled: Bool {
        get { d.object(forKey: Keys.http2) as? Bool ?? true }
        set { d.set(newValue, forKey: Keys.http2); notifyChange() }
    }

    var mitmExcludedHosts: [String] {
        get { d.stringArray(forKey: Keys.mitmExcluded) ?? [] }
        set { d.set(newValue, forKey: Keys.mitmExcluded); notifyChange() }
    }

    var autoStartProxy: Bool {
        get { d.bool(forKey: Keys.autoStart) }
        set { d.set(newValue, forKey: Keys.autoStart); notifyChange() }
    }

    var autoTakeOverSystemProxy: Bool {
        get { d.object(forKey: Keys.autoTakeOver) as? Bool ?? true }
        set { d.set(newValue, forKey: Keys.autoTakeOver); notifyChange() }
    }

    var maxBodyMB: Int {
        get { min(max(d.object(forKey: Keys.maxBodyMB) as? Int ?? 20, 1), 100) }
        set { d.set(newValue, forKey: Keys.maxBodyMB); notifyChange() }
    }

    var maxTransactions: Int {
        get { min(max(d.object(forKey: Keys.maxTransactions) as? Int ?? 5000, 100), 50_000) }
        set { d.set(newValue, forKey: Keys.maxTransactions); notifyChange() }
    }

    var followLatest: Bool {
        get { d.object(forKey: Keys.followLatest) as? Bool ?? false }
        set { d.set(newValue, forKey: Keys.followLatest); notifyChange() }
    }

    var lanEnabled: Bool {
        get { d.bool(forKey: Keys.lanEnabled) }
        set { d.set(newValue, forKey: Keys.lanEnabled); notifyChange() }
    }

    var lanAddress: String {
        get { d.string(forKey: Keys.lanAddress) ?? "" }
        set { d.set(newValue, forKey: Keys.lanAddress); notifyChange() }
    }

    var deviceAddress: String {
        get { d.string(forKey: Keys.deviceAddress) ?? "" }
        set { d.set(newValue, forKey: Keys.deviceAddress); notifyChange() }
    }

    var lanAccess: LANAccess? {
        lanEnabled ? LANAccess(address: lanAddress, device: deviceAddress, allowedPeerRanges: allowedPeerRanges) : nil
    }
    var allowedPeerRanges: [String] {
        get { d.stringArray(forKey: "proxy.allowedPeerRanges") ?? [] }
        set { d.set(newValue, forKey: "proxy.allowedPeerRanges"); notifyChange() }
    }
    var systemBypassHosts: [String]? {
        get {
            guard let data = d.data(forKey: "proxy.systemBypassHosts") else { return nil }
            return try? JSONDecoder().decode([String].self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) { d.set(data, forKey: "proxy.systemBypassHosts") }
            else { d.removeObject(forKey: "proxy.systemBypassHosts") }
            notifyChange()
        }
    }

    var showResourceUsage: Bool {
        get { d.object(forKey: "ui.showResourceUsage") as? Bool ?? true }
        set { d.set(newValue, forKey: "ui.showResourceUsage"); notifyChange() }
    }
    var showMenuBarIcon: Bool {
        get { d.object(forKey: "ui.showMenuBarIcon") as? Bool ?? false }
        set { d.set(newValue, forKey: "ui.showMenuBarIcon"); notifyChange() }
    }
    var hideAppleTraffic: Bool {
        get { d.bool(forKey: "ui.hideAppleTraffic") }
        set { d.set(newValue, forKey: "ui.hideAppleTraffic"); notifyChange() }
    }
    var redactSensitiveHeaders: Bool {
        get { d.bool(forKey: "export.redactSensitiveHeaders") }
        set { d.set(newValue, forKey: "export.redactSensitiveHeaders"); notifyChange() }
    }
    var appendProxyToCommands: Bool {
        get { d.bool(forKey: "export.appendProxyToCommands") }
        set { d.set(newValue, forKey: "export.appendProxyToCommands"); notifyChange() }
    }
    var noCacheOnRepeat: Bool {
        get { d.bool(forKey: "repeat.noCache") }
        set { d.set(newValue, forKey: "repeat.noCache"); notifyChange() }
    }
    var appendDiagnosticHeaders: Bool {
        get { d.bool(forKey: "proxy.appendDiagnosticHeaders") }
        set { d.set(newValue, forKey: "proxy.appendDiagnosticHeaders"); notifyChange() }
    }
    var truncationStyle: String {
        get { d.string(forKey: "ui.truncationStyle") ?? "middle" }
        set { d.set(newValue, forKey: "ui.truncationStyle"); notifyChange() }
    }
    var wordWrap: Bool {
        get { d.object(forKey: "ui.wordWrap") as? Bool ?? true }
        set { d.set(newValue, forKey: "ui.wordWrap"); notifyChange() }
    }
    var showInvisibles: Bool {
        get { d.bool(forKey: "ui.showInvisibles") }
        set { d.set(newValue, forKey: "ui.showInvisibles"); notifyChange() }
    }
    var showMinimap: Bool {
        get { d.bool(forKey: "ui.showMinimap") }
        set { d.set(newValue, forKey: "ui.showMinimap"); notifyChange() }
    }

    var monospacedFontFamily: String {
        get { d.string(forKey: "ui.monospacedFontFamily") ?? "" }
        set { d.set(newValue, forKey: "ui.monospacedFontFamily"); notifyChange() }
    }
    var codeTabWidth: Int {
        get { min(16, max(1, d.object(forKey: "ui.codeTabWidth") as? Int ?? 4)) }
        set { d.set(min(16, max(1, newValue)), forKey: "ui.codeTabWidth"); notifyChange() }
    }
    var use24HourClock: Bool {
        get { d.object(forKey: "ui.use24HourClock") as? Bool ?? true }
        set { d.set(newValue, forKey: "ui.use24HourClock"); notifyChange() }
    }
    var showFullDate: Bool {
        get { d.bool(forKey: "ui.showFullDate") }
        set { d.set(newValue, forKey: "ui.showFullDate"); notifyChange() }
    }
    var showAlternatingRows: Bool {
        get { d.object(forKey: "ui.showAlternatingRows") as? Bool ?? true }
        set { d.set(newValue, forKey: "ui.showAlternatingRows"); notifyChange() }
    }
    var defaultCopyFormat: RequestCode.Format {
        get { d.string(forKey: "export.defaultCopyFormat").flatMap(RequestCode.Format.init(rawValue:)) ?? .curl }
        set { d.set(newValue.rawValue, forKey: "export.defaultCopyFormat"); notifyChange() }
    }

    var appearance: String {
        get { Self.choice(d.string(forKey: "ui.appearance"), in: ["system", "light", "dark"], fallback: "system") }
        set { d.set(Self.choice(newValue, in: ["system", "light", "dark"], fallback: "system"), forKey: "ui.appearance"); notifyChange() }
    }

    var fontSize: Double {
        get { Self.boundedFontSize(d.object(forKey: Keys.fontSize) as? Double ?? 12) }
        set { d.set(Self.boundedFontSize(newValue), forKey: Keys.fontSize); notifyChange() }
    }
    private static func boundedFontSize(_ value: Double) -> Double {
        value.isFinite ? min(32, max(8, value)) : 12
    }
    var useMonospacedFont: Bool {
        get { d.object(forKey: Keys.useMonospacedFont) as? Bool ?? true }
        set { d.set(newValue, forKey: Keys.useMonospacedFont); notifyChange() }
    }
    var scrollBeyondLastLine: Bool {
        get { d.bool(forKey: Keys.scrollBeyondLastLine) }
        set { d.set(newValue, forKey: Keys.scrollBeyondLastLine); notifyChange() }
    }
    var contentLayout: String {
        get { Self.choice(d.string(forKey: Keys.contentLayout), in: ["vertical", "horizontal"], fallback: "vertical") }
        set { d.set(Self.choice(newValue, in: ["vertical", "horizontal"], fallback: "vertical"), forKey: Keys.contentLayout); notifyChange() }
    }
    var appIconStyle: String {
        get { Self.choice(d.string(forKey: Keys.appIconStyle), in: ["earth", "mars", "candy", "classic"], fallback: "earth") }
        set { d.set(Self.choice(newValue, in: ["earth", "mars", "candy", "classic"], fallback: "earth"), forKey: Keys.appIconStyle); notifyChange() }
    }
    var autoStartRecording: Bool {
        get { d.object(forKey: Keys.autoStartRecording) as? Bool ?? true }
        set { d.set(newValue, forKey: Keys.autoStartRecording); notifyChange() }
    }
    var warnBeforeQuit: Bool {
        get { d.bool(forKey: Keys.warnBeforeQuit) }
        set { d.set(newValue, forKey: Keys.warnBeforeQuit); notifyChange() }
    }
    var showUpdateNotifications: Bool {
        get { d.object(forKey: Keys.showUpdateNotifications) as? Bool ?? true }
        set { d.set(newValue, forKey: Keys.showUpdateNotifications); notifyChange() }
    }
    var applicationLanguage: String {
        get { Self.choice(d.string(forKey: Keys.applicationLanguage), in: ["system", "zh-Hans", "en"], fallback: "system") }
        set { d.set(Self.choice(newValue, in: ["system", "zh-Hans", "en"], fallback: "system"), forKey: Keys.applicationLanguage); notifyChange() }
    }
    var mcpEnabled: Bool {
        get { d.object(forKey: Keys.mcpEnabled) as? Bool ?? true }
        set { d.set(newValue, forKey: Keys.mcpEnabled); notifyChange() }
    }
    var mcpRedactSensitiveData: Bool {
        get { d.object(forKey: Keys.mcpRedactSensitiveData) as? Bool ?? true }
        set { d.set(newValue, forKey: Keys.mcpRedactSensitiveData); notifyChange() }
    }
    var preserveOriginalHeaders: Bool {
        get { d.bool(forKey: Keys.preserveOriginalHeaders) }
        set { d.set(newValue, forKey: Keys.preserveOriginalHeaders); notifyChange() }
    }
    var restorePreviousSystemProxy: Bool {
        get { d.object(forKey: Keys.restorePreviousSystemProxy) as? Bool ?? true }
        set { d.set(newValue, forKey: Keys.restorePreviousSystemProxy); notifyChange() }
    }
    var automaticTrafficCleanup: Bool {
        get { d.object(forKey: Keys.automaticTrafficCleanup) as? Bool ?? true }
        set { d.set(newValue, forKey: Keys.automaticTrafficCleanup); notifyChange() }
    }
    var cleanupMemoryLimitMB: Int {
        get { min(65536, max(64, d.object(forKey: Keys.cleanupMemoryLimitMB) as? Int ?? 3072)) }
        set { d.set(min(65536, max(64, newValue)), forKey: Keys.cleanupMemoryLimitMB); notifyChange() }
    }
    var cleanupIntervalMinutes: Int {
        get { min(60, max(1, d.object(forKey: Keys.cleanupIntervalMinutes) as? Int ?? 5)) }
        set { d.set(min(60, max(1, newValue)), forKey: Keys.cleanupIntervalMinutes); notifyChange() }
    }

    /// Resets only the Appearance page, preserving capture, proxy, language and export preferences.
    func resetAppearanceDefaults() {
        let keys = [Keys.fontSize, Keys.useMonospacedFont, Keys.scrollBeyondLastLine, Keys.appIconStyle,
                    "ui.monospacedFontFamily", "ui.codeTabWidth", "ui.wordWrap", "ui.showInvisibles",
                    "ui.showMinimap", "ui.showAlternatingRows", "ui.showResourceUsage", "ui.use24HourClock",
                    "ui.showFullDate", "ui.appearance"]
        keys.forEach { d.removeObject(forKey: $0) }
        notifyChange()
    }

    private func notifyChange() {
        objectWillChange.send()
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: d)
    }

    private static func choice(_ value: String?, in choices: [String], fallback: String) -> String {
        value.flatMap { choices.contains($0) ? $0 : nil } ?? fallback
    }

}
