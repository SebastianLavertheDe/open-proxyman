import Foundation

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
    }

    var port: UInt16 {
        get { (d.object(forKey: Keys.port) as? Int).flatMap(UInt16.init(exactly:)).flatMap { $0 >= 1024 ? $0 : nil } ?? 9090 }
        set { d.set(Int(newValue), forKey: Keys.port); objectWillChange.send() }
    }

    var mitmEnabled: Bool {
        get { d.object(forKey: Keys.mitmEnabled) as? Bool ?? true }
        set { d.set(newValue, forKey: Keys.mitmEnabled); objectWillChange.send() }
    }

    var http2Enabled: Bool {
        get { d.object(forKey: Keys.http2) as? Bool ?? true }
        set { d.set(newValue, forKey: Keys.http2); objectWillChange.send() }
    }

    var mitmExcludedHosts: [String] {
        get { d.stringArray(forKey: Keys.mitmExcluded) ?? [] }
        set { d.set(newValue, forKey: Keys.mitmExcluded); objectWillChange.send() }
    }

    var autoStartProxy: Bool {
        get { d.bool(forKey: Keys.autoStart) }
        set { d.set(newValue, forKey: Keys.autoStart); objectWillChange.send() }
    }

    var autoTakeOverSystemProxy: Bool {
        get { d.object(forKey: Keys.autoTakeOver) as? Bool ?? true }
        set { d.set(newValue, forKey: Keys.autoTakeOver); objectWillChange.send() }
    }

    var maxBodyMB: Int {
        get { min(max(d.object(forKey: Keys.maxBodyMB) as? Int ?? 20, 1), 100) }
        set { d.set(newValue, forKey: Keys.maxBodyMB); objectWillChange.send() }
    }

    var maxTransactions: Int {
        get { min(max(d.object(forKey: Keys.maxTransactions) as? Int ?? 5000, 100), 50_000) }
        set { d.set(newValue, forKey: Keys.maxTransactions); objectWillChange.send() }
    }

    var followLatest: Bool {
        get { d.object(forKey: Keys.followLatest) as? Bool ?? false }
        set { d.set(newValue, forKey: Keys.followLatest); objectWillChange.send() }
    }

    var lanEnabled: Bool {
        get { d.bool(forKey: Keys.lanEnabled) }
        set { d.set(newValue, forKey: Keys.lanEnabled); objectWillChange.send() }
    }

    var lanAddress: String {
        get { d.string(forKey: Keys.lanAddress) ?? "" }
        set { d.set(newValue, forKey: Keys.lanAddress); objectWillChange.send() }
    }

    var deviceAddress: String {
        get { d.string(forKey: Keys.deviceAddress) ?? "" }
        set { d.set(newValue, forKey: Keys.deviceAddress); objectWillChange.send() }
    }

    var lanAccess: LANAccess? {
        lanEnabled ? LANAccess(address: lanAddress, device: deviceAddress) : nil
    }
}
