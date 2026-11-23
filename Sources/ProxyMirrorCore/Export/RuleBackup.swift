import Foundation
import ProxyMirrorSystemProxy

struct RuleBackup: Codable {
    static let fileLimit = 16 * 1024 * 1024

    enum Section: String, Codable, CaseIterable, Identifiable {
        case mapLocal, mapRemote, blockList, allowList, sslProxyingList, sslApplications, customCertificates
        case dns, breakpoints, rewrite, latency, noCaching, reverse, external, h2c, protobuf, organization, settings

        var id: Self { self }
        var title: String {
            switch self {
            case .mapLocal: return "Map Local"
            case .mapRemote: return "Map Remote"
            case .blockList: return "Block List"
            case .allowList: return "Allow List"
            case .sslProxyingList: return "SSL Proxying List"
            case .sslApplications: return "按应用 SSL"
            case .customCertificates: return "自定义服务端证书"
            case .dns: return "DNS 映射"
            case .breakpoints: return "断点规则"
            case .rewrite: return "Rewrite"
            case .latency: return "延迟模拟"
            case .noCaching: return "No Caching"
            case .reverse: return "反向代理"
            case .external: return "外部代理"
            case .h2c: return "HTTP/2 明文上游"
            case .protobuf: return "Protobuf"
            case .organization: return "规则文件夹与工具开关"
            case .settings: return "应用设置"
            }
        }

        fileprivate var classicRules: WritableKeyPath<RuleBackup, [ProxyRule]?>? {
            switch self {
            case .mapLocal: return \.mapLocal
            case .mapRemote: return \.mapRemote
            case .blockList: return \.blockList
            case .allowList: return \.allowList
            case .sslProxyingList: return \.sslProxyingList
            default: return nil
            }
        }
    }

    enum ImportMode: String, Codable { case merge, replace }

    struct Preferences: Codable, Equatable {
        let port: UInt16
        let mitmEnabled: Bool
        let mitmExcluded: [String]
        let autoStart: Bool
        let autoTakeOverSystemProxy: Bool?
        let maxBodyMB: Int
        let maxTransactions: Int
        let followLatest: Bool
        var extras: Extras?

        struct Extras: Codable, Equatable {
            var http2Enabled: Bool?
            var lanEnabled: Bool?
            var lanAddress: String?
            var deviceAddress: String?
            var allowedPeerRanges: [String]?
            var showResourceUsage: Bool?
            var showMenuBarIcon: Bool?
            var hideAppleTraffic: Bool?
            var redactSensitiveHeaders: Bool?
            var appendProxyToCommands: Bool?
            var noCacheOnRepeat: Bool?
            var appendDiagnosticHeaders: Bool?
            var truncationStyle: String?
            var wordWrap: Bool?
            var showInvisibles: Bool?
            var showMinimap: Bool?
            var systemBypassHosts: [String]?
            var usesCustomSystemBypass: Bool?

            var valid: Bool {
                (truncationStyle.map { ["head", "middle", "tail"].contains($0) } ?? true)
                    && NetworkAccessPolicy.validationError(for: allowedPeerRanges ?? []) == nil
                    && SystemProxyBypassList.validationError(systemBypassHosts ?? []) == nil
            }

            init(_ settings: AppSettings) {
                http2Enabled = settings.http2Enabled
                lanEnabled = settings.lanEnabled; lanAddress = settings.lanAddress; deviceAddress = settings.deviceAddress
                allowedPeerRanges = settings.allowedPeerRanges
                showResourceUsage = settings.showResourceUsage; showMenuBarIcon = settings.showMenuBarIcon
                hideAppleTraffic = settings.hideAppleTraffic; redactSensitiveHeaders = settings.redactSensitiveHeaders
                appendProxyToCommands = settings.appendProxyToCommands; noCacheOnRepeat = settings.noCacheOnRepeat
                appendDiagnosticHeaders = settings.appendDiagnosticHeaders; truncationStyle = settings.truncationStyle
                wordWrap = settings.wordWrap; showInvisibles = settings.showInvisibles; showMinimap = settings.showMinimap
                systemBypassHosts = settings.systemBypassHosts
                usesCustomSystemBypass = systemBypassHosts != nil
            }

            func apply(to settings: AppSettings) {
                if let http2Enabled { settings.http2Enabled = http2Enabled }
                if let lanEnabled { settings.lanEnabled = lanEnabled }
                if let lanAddress { settings.lanAddress = lanAddress }
                if let deviceAddress { settings.deviceAddress = deviceAddress }
                if let allowedPeerRanges { settings.allowedPeerRanges = allowedPeerRanges }
                if let showResourceUsage { settings.showResourceUsage = showResourceUsage }
                if let showMenuBarIcon { settings.showMenuBarIcon = showMenuBarIcon }
                if let hideAppleTraffic { settings.hideAppleTraffic = hideAppleTraffic }
                if let redactSensitiveHeaders { settings.redactSensitiveHeaders = redactSensitiveHeaders }
                if let appendProxyToCommands { settings.appendProxyToCommands = appendProxyToCommands }
                if let noCacheOnRepeat { settings.noCacheOnRepeat = noCacheOnRepeat }
                if let appendDiagnosticHeaders { settings.appendDiagnosticHeaders = appendDiagnosticHeaders }
                if let truncationStyle { settings.truncationStyle = truncationStyle }
                if let wordWrap { settings.wordWrap = wordWrap }
                if let showInvisibles { settings.showInvisibles = showInvisibles }
                if let showMinimap { settings.showMinimap = showMinimap }
                if let usesCustomSystemBypass {
                    settings.systemBypassHosts = usesCustomSystemBypass ? systemBypassHosts ?? [] : nil
                }
            }
        }

        init(_ settings: AppSettings) {
            port = settings.port
            mitmEnabled = settings.mitmEnabled
            mitmExcluded = settings.mitmExcludedHosts
            autoStart = settings.autoStartProxy
            autoTakeOverSystemProxy = settings.autoTakeOverSystemProxy
            maxBodyMB = settings.maxBodyMB
            maxTransactions = settings.maxTransactions
            followLatest = settings.followLatest
            extras = Extras(settings)
        }

        func apply(to settings: AppSettings) {
            settings.port = port
            settings.mitmEnabled = mitmEnabled
            settings.mitmExcludedHosts = mitmExcluded
            settings.autoStartProxy = autoStart
            if let autoTakeOverSystemProxy { settings.autoTakeOverSystemProxy = autoTakeOverSystemProxy }
            settings.maxBodyMB = maxBodyMB
            settings.maxTransactions = maxTransactions
            settings.followLatest = followLatest
            extras?.apply(to: settings)
        }

        var valid: Bool {
            (1024...65535).contains(port) && (1...100).contains(maxBodyMB) && (100...50000).contains(maxTransactions) && extras?.valid != false
        }
    }

    struct Change: Encodable, Identifiable {
        let section: Section
        var added = 0
        var updated = 0
        var removed = 0
        var unchanged = 0
        var reordered = false
        /// Global condition switch changed in addition to the per-rule counts.
        var configurationChanged: Bool?

        var id: Section { section }
    }

    var version: Int?
    var mapLocal: [ProxyRule]?
    var mapRemote: [ProxyRule]?
    var blockList: [ProxyRule]?
    var allowList: [ProxyRule]?
    var sslProxyingList: [ProxyRule]?
    var sslApplications: [SSLApplicationRule]?
    var customCertificates: [CustomCertificateRule]?
    var noCaching: Bool?
    var settings: Preferences?
    var dns: [DNSSpoofRule]?
    var breakpoints: [BreakpointRule]?
    var rewrite: [RewriteRuleSet]?
    var latency: LatencyConditions?
    var organization: RuleOrganization?
    var reverse: [ReverseProxyRule]?
    var external: ExternalProxyConfig?
    var h2c: H2CUpstreamConfig?
    var protobuf: ProtobufConfiguration?

    static func snapshot(settings: AppSettings) -> Self {
        var backup = RulesStore.shared.backup()
        backup.settings = Preferences(settings)
        return backup
    }

    func encoded(pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return try encoder.encode(self)
    }

    func exportData() throws -> Data {
        let data = try encoded(pretty: true)
        guard data.count <= Self.fileLimit else { throw BackupError("规则备份超过 16 MiB。请按工具导出。") }
        return data
    }

    static func contents(of url: URL) throws -> Data {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw BackupError("请选择普通文件。")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: fileLimit + 1) ?? Data()
        guard data.count <= fileLimit else { throw BackupError("规则备份超过 16 MiB。请按工具拆分。") }
        return data
    }

    static func read(_ data: Data) throws -> (RuleBackup, [String]) {
        guard data.count <= fileLimit else { throw BackupError("规则备份超过 16 MiB。请按工具拆分。") }
        let sections = Set(Section.allCases.map(\.rawValue))
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              !sections.isDisjoint(with: object.keys) else {
            throw BackupError("请选择 ProxyMirror 备份或旧版 rules.json。")
        }
        let backup = try JSONDecoder().decode(Self.self, from: data)
        guard backup.version == nil || backup.version == 1 else { throw BackupError("此规则备份版本暂不支持。") }
        guard backup.settings?.valid != false else { throw BackupError("备份中的设置值超出支持范围。") }
        guard !backup.changes(from: RuleBackup(), mode: .merge).isEmpty else {
            throw BackupError("备份中没有可导入的规则或设置。")
        }

        var unknown = Set(object.keys).subtracting(sections.union(["version", "organization"]))
        if let preferences = object["settings"] as? [String: Any] {
            let names = ["port", "mitmEnabled", "mitmExcluded", "autoStart", "autoTakeOverSystemProxy", "maxBodyMB", "maxTransactions", "followLatest", "extras"]
            unknown.formUnion(Set(preferences.keys).subtracting(names).map { "settings.\($0)" })
        }
        if let error = backup.organization?.validationError { throw BackupError(error) }
        if let error = backup.protobuf?.validationError { throw BackupError(error) }
        try backup.validateRules(object)
        return (backup, unknown.sorted())
    }

    /// Validates typed edits too, before RulesStore commits the canonical configuration.
    /// Raw-key validation remains in read(_:), where original imported JSON is available.
    func validate() throws {
        guard version == nil || version == 1 else { throw BackupError("此规则备份版本暂不支持。") }
        guard settings?.valid != false else { throw BackupError("备份中的设置值超出支持范围。") }
        if let issue = organization?.validationError { throw BackupError(issue) }
        if let issue = protobuf?.validationError { throw BackupError(issue) }
        try validateRules([:])
    }

    private func validateRules(_ object: [String: Any]) throws {
        let classicKeys: Set<String> = ["id", "enabled", "pattern", "target", "comment", "responseStatus", "responseHeaders", "urlRegex"]
        for section in Section.allCases {
            guard let path = section.classicRules else { continue }
            try Self.validateIDs(self[keyPath: path], section: section)
            try Self.validateKeys(object, section: section, allowed: classicKeys)
            for rule in self[keyPath: path] ?? [] {
                if let regex = rule.urlRegex,
                   regex.isEmpty || regex.utf8.count > 8192 || URLRule.regexCache(regex) == nil {
                    throw BackupError("\(section.title) 包含无效的 URL 正则。")
                }
            }
        }
        try Self.validateIDs(sslApplications, section: .sslApplications)
        try Self.validateKeys(object, section: .sslApplications, allowed: ["enabled", "bundleID", "name", "action"])
        if let sslApplications, !sslApplications.allSatisfy({ SSLApplicationRule.isValid($0.id) }) {
            throw BackupError("按应用 SSL 规则需要有效的 Bundle ID。")
        }
        try Self.validateIDs(customCertificates, section: .customCertificates)
        try Self.validateKeys(object, section: .customCertificates,
                              allowed: ["id", "enabled", "hostPattern", "certificatePath", "privateKeyPath"])
        for rule in customCertificates ?? [] {
            let host = rule.hostPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            let domain = host.hasPrefix("*.") ? String(host.dropFirst(2)) : host
            guard !domain.isEmpty, !domain.contains("*"), !domain.contains("/"),
                  !domain.contains(":") || URLParser.isIPAddress(URLParser.bareHost(domain)),
                  domain.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  !host.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !rule.certificatePath.isEmpty, !rule.privateKeyPath.isEmpty,
                  !rule.certificatePath.contains("\0"), !rule.privateKeyPath.contains("\0") else {
                throw BackupError("自定义服务端证书需要有效域名、证书链和私钥路径。")
            }
        }
        try Self.validateIDs(dns, section: .dns)
        try Self.validateKeys(object, section: .dns, allowed: ["id", "enabled", "hostPattern", "ip"])
        try Self.validateIDs(breakpoints, section: .breakpoints)
        try Self.validateKeys(object, section: .breakpoints, allowed: ["id", "enabled", "rule", "phase"])
        if let rawRules = object[Section.breakpoints.rawValue] as? [[String: Any]] {
            let urlKeys: Set<String> = ["id", "enabled", "name", "method", "scheme", "host", "path", "query",
                                        "includeSubpaths", "matchMode", "regexPattern", "graphqlQueryName"]
            for (index, raw) in rawRules.enumerated() {
                if let rule = raw["rule"] as? [String: Any] {
                    try Self.rejectUnknown(rule, allowed: urlKeys, location: "breakpoints[\(index + 1)].rule")
                }
            }
        }
        try Self.validateIDs(rewrite, section: .rewrite)
        try Self.validateKeys(object, section: .rewrite, allowed: ["id", "enabled", "name", "rules"])
        for group in rewrite ?? [] {
            try Self.validateIDs(group.rules, section: .rewrite)
            for rule in group.rules {
                if rule.rule.matchMode == .regex,
                   rule.rule.regexPattern.isEmpty || rule.rule.regexPattern.utf8.count > 8192
                    || URLRule.regexCache(rule.rule.regexPattern) == nil {
                    throw BackupError("Rewrite 包含无效的 URL 正则。")
                }
                for action in rule.actions {
                    switch action {
                    case .requestHeader(_, let name, let value), .responseHeader(_, let name, let value):
                        if name.isEmpty || !name.utf8.allSatisfy(Self.isTokenByte)
                            || value.utf8.contains(where: { $0 < 32 && $0 != 9 || $0 == 127 }) {
                            throw BackupError("Rewrite 包含无效的 HTTP 头。")
                        }
                    case .script(_, let source):
                        guard source.utf8.count <= ScriptingService.sourceLimit else {
                            throw BackupError("Rewrite 单个脚本超过 \(ScriptingService.sourceLimit / 1024) KiB。")
                        }
                    default: break
                    }
                }
            }
        }
        if let rawLatency = object[Section.latency.rawValue] as? [String: Any] {
            let keys = Set(LatencyConditions.CodingKeys.allCases.map(\.rawValue))
            try Self.rejectUnknown(rawLatency, allowed: keys, location: "latency")
        }
        if let error = latency?.validationError { throw BackupError(error) }
        try Self.validateIDs(reverse, section: .reverse)
        var reversePorts = Set<UInt16>()
        for rule in reverse ?? [] where rule.enabled {
            do { _ = try ReverseProxyRoute(rule) }
            catch { throw BackupError(error.localizedDescription) }
            guard reversePorts.insert(rule.listenPort).inserted else { throw BackupError("反向代理包含重复监听端口。") }
        }
        if let external, external.enabled, let error = external.validationError { throw BackupError(error) }
        if let h2c {
            guard h2c.hosts.count <= 1000, h2c.hosts.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 && !$0.contains("/") }) else {
                throw BackupError("HTTP/2 明文上游主机规则无效。")
            }
        }
        for (index, rule) in (mapLocal ?? []).enumerated() {
            if let status = rule.responseStatus, !(200...599).contains(status) {
                throw BackupError("Map Local 第 \(index + 1) 条规则的响应状态码无效。")
            }
            if rule.responseHeaders?.pairs.contains(where: { field in
                field.name.isEmpty || !field.name.utf8.allSatisfy(Self.isTokenByte) ||
                    field.value.utf8.contains { $0 < 32 && $0 != 9 || $0 == 127 }
            }) == true {
                throw BackupError("Map Local 第 \(index + 1) 条规则包含无效响应头。")
            }
        }
        for (index, rule) in (mapRemote ?? []).enumerated() where rule.enabled && !rule.target.isEmpty {
            guard let url = URLComponents(string: rule.target), let host = url.host, !host.isEmpty,
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  url.user == nil, url.password == nil, url.fragment == nil,
                  url.port.map({ (1...65535).contains($0) }) ?? true else {
                throw BackupError("Map Remote 第 \(index + 1) 条规则的目标 URL 无效。")
            }
        }
        for (index, rule) in (dns ?? []).enumerated() where rule.enabled {
            guard !rule.hostPattern.isEmpty, URLParser.isIPAddress(rule.ip) else {
                throw BackupError("DNS 映射第 \(index + 1) 条规则需要主机和有效的 IP 地址。")
            }
        }
        for (index, rule) in (breakpoints ?? []).enumerated() where rule.enabled && rule.rule.matchMode == .regex {
            guard !rule.rule.regexPattern.isEmpty,
                  (try? NSRegularExpression(pattern: rule.rule.regexPattern)) != nil else {
                throw BackupError("断点第 \(index + 1) 条规则的 URL 正则无效。")
            }
        }
    }

    private static func validateIDs<T: Identifiable>(_ records: [T]?, section: Section) throws {
        guard let records else { return }
        guard Set(records.map(\.id)).count == records.count else {
            throw BackupError("\(section.title) 包含重复的规则 ID。")
        }
    }

    private static func validateKeys(_ object: [String: Any], section: Section, allowed: Set<String>) throws {
        guard let records = object[section.rawValue] as? [[String: Any]] else { return }
        for (index, record) in records.enumerated() {
            try rejectUnknown(record, allowed: allowed, location: "\(section.rawValue)[\(index + 1)]")
        }
    }

    private static func rejectUnknown(_ object: [String: Any], allowed: Set<String>, location: String) throws {
        let unknown = Set(object.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            throw BackupError("\(location) 包含无法映射的规则字段 \(unknown.joined(separator: "、"))。")
        }
    }

    private static func isTokenByte(_ value: UInt8) -> Bool {
        (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
            || "!#$%&'*+-.^_`|~".utf8.contains(value)
    }

    func migrationNotes() -> [String] {
        let local = (mapLocal ?? []).enumerated().compactMap { index, rule -> String? in
            guard rule.enabled, !rule.target.isEmpty, !FileManager.default.isReadableFile(atPath: rule.target) else { return nil }
            return "Map Local 第 \(index + 1) 条规则的目标在此 Mac 上不可读取，导入后需要更新路径。"
        }
        let certificates = (customCertificates ?? []).enumerated().compactMap { index, rule -> String? in
            guard rule.enabled, !FileManager.default.isReadableFile(atPath: rule.certificatePath)
                || !FileManager.default.isReadableFile(atPath: rule.privateKeyPath) else { return nil }
            return "自定义服务端证书第 \(index + 1) 条规则的证书链或私钥在此 Mac 上不可读取，导入后需要更新路径。"
        }
        return local + certificates
    }

    func subset(_ section: Section?) -> RuleBackup {
        guard let section else {
            var copy = self
            copy.version = 1
            return copy
        }
        var result = RuleBackup(version: 1)
        if let organization {
            result.organization = RuleOrganization(
                folders: organization.folders.filter { $0.tool == section.rawValue },
                assignments: organization.assignments.filter { $0.key.hasPrefix(section.rawValue + ":") },
                disabledTools: organization.disabledTools.filter { $0 == section.rawValue },
                includedTools: [section.rawValue])
        }
        if let path = section.classicRules { result[keyPath: path] = self[keyPath: path] }
        switch section {
        case .sslApplications: result.sslApplications = sslApplications
        case .customCertificates: result.customCertificates = customCertificates
        case .dns: result.dns = dns
        case .breakpoints: result.breakpoints = breakpoints
        case .rewrite: result.rewrite = rewrite
        case .latency: result.latency = latency
        case .noCaching: result.noCaching = noCaching
        case .reverse: result.reverse = reverse
        case .external: result.external = external
        case .h2c: result.h2c = h2c
        case .protobuf: result.protobuf = protobuf
        case .organization: result.organization = organization
        case .settings: result.settings = settings
        default: break
        }
        return result
    }

    func resolve(with current: RuleBackup, merge: Bool) -> RuleBackup {
        var result = current
        for section in Section.allCases {
            guard let path = section.classicRules, let incoming = self[keyPath: path] else { continue }
            result[keyPath: path] = Self.resolve(incoming, current: current[keyPath: path] ?? [], merge: merge)
        }
        if let sslApplications {
            result.sslApplications = Self.resolve(sslApplications, current: current.sslApplications ?? [], merge: merge)
        }
        if let customCertificates {
            result.customCertificates = Self.resolve(customCertificates, current: current.customCertificates ?? [], merge: merge)
        }
        if let dns { result.dns = Self.resolve(dns, current: current.dns ?? [], merge: merge) }
        if let breakpoints { result.breakpoints = Self.resolve(breakpoints, current: current.breakpoints ?? [], merge: merge) }
        if let rewrite { result.rewrite = Self.resolve(rewrite, current: current.rewrite ?? [], merge: merge) }
        if let reverse { result.reverse = Self.resolve(reverse, current: current.reverse ?? [], merge: merge) }
        result.external = external ?? current.external
        result.h2c = h2c ?? current.h2c
        if let protobuf { result.protobuf = protobuf.resolving(with: current.protobuf ?? ProtobufConfiguration(), merge: merge) }
        result.noCaching = noCaching ?? current.noCaching
        if let latency { result.latency = latency.resolving(with: current.latency ?? LatencyConditions(), merge: merge) }
        result.settings = settings ?? current.settings
        if let organization { result.organization = organization.resolving(with: current.organization ?? RuleOrganization(), merge: merge) }
        return result
    }

    private static func resolve<T: Identifiable>(_ incoming: [T], current: [T], merge: Bool) -> [T] {
        guard merge else { return incoming }
        let imported = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        let existing = Set(current.map(\.id))
        return current.map { imported[$0.id] ?? $0 } + incoming.filter { !existing.contains($0.id) }
    }

    func changes(from current: RuleBackup, mode: ImportMode) -> [Change] {
        Section.allCases.compactMap { section in
            if let path = section.classicRules, let incoming = self[keyPath: path] {
                return Self.changes(section, incoming: incoming, current: current[keyPath: path] ?? [], mode: mode)
            }
            switch section {
            case .sslApplications:
                return sslApplications.map {
                    Self.changes(section, incoming: $0, current: current.sslApplications ?? [], mode: mode)
                }
            case .customCertificates:
                return customCertificates.map {
                    Self.changes(section, incoming: $0, current: current.customCertificates ?? [], mode: mode)
                }
            case .dns:
                return dns.map { Self.changes(section, incoming: $0, current: current.dns ?? [], mode: mode) }
            case .breakpoints:
                return breakpoints.map { Self.changes(section, incoming: $0, current: current.breakpoints ?? [], mode: mode) }
            case .rewrite:
                return rewrite.map { Self.changes(section, incoming: $0, current: current.rewrite ?? [], mode: mode) }
            case .latency:
                return latency.map { incoming in
                    guard let rules = incoming.rules else { return Self.change(section, incoming: incoming, current: current.latency) }
                    var change = Self.changes(section, incoming: rules, current: current.latency?.rules ?? [], mode: mode)
                    if current.latency?.enabled != incoming.enabled || current.latency?.rules == nil {
                        change.configurationChanged = true
                    }
                    return change
                }
            case .noCaching:
                return noCaching.map { Self.change(section, incoming: $0, current: current.noCaching) }
            case .reverse:
                return reverse.map { Self.changes(section, incoming: $0, current: current.reverse ?? [], mode: mode) }
            case .external:
                return external.map { Self.change(section, incoming: $0, current: current.external) }
            case .h2c:
                return h2c.map { Self.change(section, incoming: $0, current: current.h2c) }
            case .protobuf:
                return protobuf.map { Self.change(section, incoming: $0, current: current.protobuf) }
            case .organization:
                return organization.map { Self.change(section, incoming: $0, current: current.organization) }
            case .settings:
                return settings.map { Self.change(section, incoming: $0, current: current.settings) }
            default: return nil
            }
        }
    }

    private static func changes<T: Identifiable & Equatable>(_ section: Section, incoming: [T],
                                                             current: [T], mode: ImportMode) -> Change {
        let byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        let incomingIDs = Set(incoming.map(\.id))
        var change = Change(section: section)
        for record in incoming {
            if let old = byID[record.id] {
                if old == record { change.unchanged += 1 } else { change.updated += 1 }
            } else { change.added += 1 }
        }
        if mode == .replace {
            change.removed = current.filter { !incomingIDs.contains($0.id) }.count
            change.reordered = current.filter { incomingIDs.contains($0.id) }.map(\.id)
                != incoming.filter { byID[$0.id] != nil }.map(\.id)
        }
        return change
    }

    private static func change<T: Equatable>(_ section: Section, incoming: T, current: T?) -> Change {
        guard let current else { return Change(section: section, added: 1) }
        return incoming == current ? Change(section: section, unchanged: 1) : Change(section: section, updated: 1)
    }

    struct BackupError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
