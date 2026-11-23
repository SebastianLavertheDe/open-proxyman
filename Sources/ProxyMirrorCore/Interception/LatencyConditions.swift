import Foundation

struct LinkBandwidth: Equatable {
    static let maxKbps = 1_000_000

    let uploadKbps: Int?
    let downloadKbps: Int?

    private static func limit(_ rate: Int?) -> Int? {
        rate.flatMap { (1...maxKbps).contains($0) ? $0 : nil }
    }

    init(uploadKbps: Int? = nil, downloadKbps: Int? = nil) {
        self.uploadKbps = Self.limit(uploadKbps)
        self.downloadKbps = Self.limit(downloadKbps)
    }
}

struct BodyPause: Equatable {
    var percent = 0
    var intervalMs = 50

    var enabled: Bool { percent > 0 }

    func sample(using random: (ClosedRange<Int>) -> Int = { Int.random(in: $0) }) -> Int {
        guard LatencyConditions.roll(percent, using: random) else { return 0 }
        return min(intervalMs * random(1...3), 1000)
    }
}

struct LatencySimulation: Equatable {
    var requestDelay = 0
    var responseDelay = 0
    var disconnect = false
    var bandwidth = LinkBandwidth()
    var bodyPause = BodyPause()
}

struct LatencyConditions: Codable, Equatable {
    static let maxDelayMs = 5000
    static let responseSpikeMs = 500
    static let disconnectReason = "弱网模拟：随机断连"

    var enabled = false
    var milliseconds = 150
    var host = ""
    var uploadKbps: Int?
    var downloadKbps: Int?
    var jitterMilliseconds: Int?
    var disconnectPercent: Int?
    var responseSpikePercent: Int?
    var bodyPausePercent: Int?

    /// nil preserves the legacy global condition; a present list uses first matching enabled rule.
    var rules: [NetworkConditionRule]?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case enabled, milliseconds, host, uploadKbps, downloadKbps, jitterMilliseconds
        case disconnectPercent, responseSpikePercent, bodyPausePercent, rules
    }

    var validationError: String? {
        if let rules {
            guard rules.count <= 500, Set(rules.map(\.id)).count == rules.count else {
                return "弱网规则最多 500 条，且 ID 不能重复。"
            }
            for rule in rules {
                if let error = rule.validationError { return "\(rule.name)：\(error)" }
            }
        }
        if ![milliseconds, jitterMilliseconds ?? 0].allSatisfy({ (0...Self.maxDelayMs).contains($0) }) {
            return "请求延迟和抖动必须在 0 到 5000 毫秒之间。"
        }
        if ![uploadKbps ?? 0, downloadKbps ?? 0].allSatisfy({ (0...LinkBandwidth.maxKbps).contains($0) }) {
            return "上传和下载速率必须在 0 到 1,000,000 kbps 之间。"
        }
        if ![disconnectPercent ?? 0, responseSpikePercent ?? 0, bodyPausePercent ?? 0]
            .allSatisfy({ (0...100).contains($0) }) {
            return "弱网模拟概率必须在 0% 到 100% 之间。"
        }
        return nil
    }

    enum Preset: String, CaseIterable {
        case totalLoss = "100% Loss", veryBad = "Very Bad Network", twoG = "2G"
        case threeG = "3G", fourG = "4G", fiveG = "5G", lte = "LTE", wifi = "Wi-Fi"
        case wifi802 = "Wi-Fi 802.11ac", slow = "Slow", medium = "Medium", dialUp = "Dial-up"

        func settings(for host: String) -> LatencyConditions {
            let (delay, upload, download, jitter): (Int, Int, Int, Int)
            switch self {
            case .totalLoss: (delay, upload, download, jitter) = (0, 0, 0, 0)
            case .veryBad: (delay, upload, download, jitter) = (2000, 16, 32, 1000)
            case .twoG: (delay, upload, download, jitter) = (650, 64, 128, 200)
            case .fiveG: (delay, upload, download, jitter) = (10, 50_000, 100_000, 5)
            case .wifi802: (delay, upload, download, jitter) = (1, 100_000, 300_000, 0)
            case .slow: (delay, upload, download, jitter) = (500, 128, 256, 100)
            case .medium: (delay, upload, download, jitter) = (120, 1000, 2000, 30)
            case .threeG: (delay, upload, download, jitter) = (100, 400, 575, 35)
            case .fourG: (delay, upload, download, jitter) = (50, 2000, 4000, 15)
            case .lte: (delay, upload, download, jitter) = (30, 7500, 15_000, 10)
            case .wifi: (delay, upload, download, jitter) = (1, 30_000, 40_000, 0)
            case .dialUp: (delay, upload, download, jitter) = (150, 25, 40, 35)
            }
            return LatencyConditions(enabled: true, milliseconds: delay, host: host, uploadKbps: upload,
                                     downloadKbps: download, jitterMilliseconds: jitter > 0 ? jitter : nil,
                                     disconnectPercent: self == .totalLoss ? 100 : self == .veryBad ? 20 : nil)
        }
    }

    private static let current: LockedBox<LatencyConditions> = {
        let consolidated: RuleBackup? = RulesFileIO.load("rules.json")
        return LockedBox(consolidated?.latency ?? RulesFileIO.load("latency.json") ?? LatencyConditions())
    }()

    static func snapshot() -> Self { current.value }

    static func install(_ settings: Self) -> Bool {
        guard settings.validationError == nil else { return false }
        let store = RulesStore.shared
        var backup = store.backup()
        backup.latency = settings
        do {
            try store.install(backup)
            return true
        } catch {
            return false
        }
    }

    static func updateSnapshot(_ settings: Self) { current.set(settings) }

    func sample(for target: String, using random: (ClosedRange<Int>) -> Int = { Int.random(in: $0) }) -> LatencySimulation {
        guard enabled, RuleOrganizationStore.shared.isEnabled("latency") else { return LatencySimulation() }
        if let rules {
            guard let rule = rules.first(where: { $0.enabled && RuleOrganizationStore.shared.ruleIsEnabled(tool: "latency", id: $0.id) && ($0.host.isEmpty || ConnState.hostMatches(host: target, pattern: $0.host)) }) else {
                return LatencySimulation()
            }
            return rule.legacy.sample(for: target, using: random)
        }
        guard host.isEmpty || ConnState.hostMatches(host: target, pattern: host) else { return LatencySimulation() }
        let base = min(max(milliseconds, 0), Self.maxDelayMs)
        let jitter = min(max(jitterMilliseconds ?? 0, 0), Self.maxDelayMs)
        let delay = jitter == 0 ? base : random(max(0, base - jitter)...min(Self.maxDelayMs, base + jitter))
        let disconnect = Self.roll(disconnectPercent ?? 0, using: random)
        let spike = !disconnect && Self.roll(responseSpikePercent ?? 0, using: random)
        return LatencySimulation(requestDelay: delay, responseDelay: spike ? Self.responseSpikeMs : 0,
                                 disconnect: disconnect,
                                 bandwidth: LinkBandwidth(uploadKbps: uploadKbps, downloadKbps: downloadKbps),
                                 bodyPause: BodyPause(percent: bodyPausePercent ?? 0, intervalMs: min(max(50, base), 1000)))
    }

    /// Like other rule tools, merge updates by UUID, preserves existing order, and appends new rules.
    /// A legacy singleton has no stable rule identity, so crossing that format boundary replaces it.
    func resolving(with current: LatencyConditions, merge: Bool) -> LatencyConditions {
        guard merge, let incoming = rules, let existing = current.rules else { return self }
        var result = self
        let byID = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let knownIDs = Set(existing.map(\.id))
        result.rules = existing.map { byID[$0.id] ?? $0 } + incoming.filter { !knownIDs.contains($0.id) }
        return result
    }

    fileprivate static func roll(_ percent: Int, using random: (ClosedRange<Int>) -> Int) -> Bool {
        percent >= 100 || (percent > 0 && random(1...100) <= percent)
    }
}

/// One independent host condition. Order is significant: the first enabled match wins.
struct NetworkConditionRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "弱网规则"
    var enabled = true
    var host = ""
    var milliseconds = 150
    var uploadKbps: Int?
    var downloadKbps: Int?
    var jitterMilliseconds: Int?
    var disconnectPercent: Int?
    var responseSpikePercent: Int?
    var bodyPausePercent: Int?

    init(legacy: LatencyConditions = LatencyConditions(), name: String = "弱网规则") {
        self.name = name
        enabled = legacy.enabled
        host = legacy.host
        milliseconds = legacy.milliseconds
        uploadKbps = legacy.uploadKbps
        downloadKbps = legacy.downloadKbps
        jitterMilliseconds = legacy.jitterMilliseconds
        disconnectPercent = legacy.disconnectPercent
        responseSpikePercent = legacy.responseSpikePercent
        bodyPausePercent = legacy.bodyPausePercent
    }

    var legacy: LatencyConditions {
        LatencyConditions(enabled: enabled, milliseconds: milliseconds, host: host,
                          uploadKbps: uploadKbps, downloadKbps: downloadKbps,
                          jitterMilliseconds: jitterMilliseconds, disconnectPercent: disconnectPercent,
                          responseSpikePercent: responseSpikePercent, bodyPausePercent: bodyPausePercent)
    }

    var validationError: String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 512 else {
            return "请填写不超过 512 字节的规则名称。"
        }
        guard host.utf8.count <= 1024, !host.contains("/"),
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return "主机应为域名、IP 或 *.example.com 通配符。"
        }
        return legacy.validationError
    }
}
