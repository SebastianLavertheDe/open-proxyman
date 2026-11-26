import Foundation
import ProxyMirrorSystemProxy

struct RuleBackup: Codable {
    static let currentVersion = 2
    static let fileLimit = 16 * 1024 * 1024

    enum Section: String, Codable, CaseIterable, Identifiable, Sendable {
        case mapLocal, mapRemote, blockList, allowList, sslProxyingList, sslApplications, customCertificates
        case dns, breakpoints, rewrite, latency, noCaching, reverse, external, h2c, protobuf, organization, settings

        var id: Self { self }
        var title: String { localizedTitle }

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
        var localizedTitle: String {
            switch self {
            case .mapLocal: return Strings.Models.backupSectionMapLocal
            case .mapRemote: return Strings.Models.backupSectionMapRemote
            case .blockList: return Strings.Models.backupSectionBlockList
            case .allowList: return Strings.Models.backupSectionAllowList
            case .sslProxyingList: return Strings.Models.backupSectionSslProxyingList
            case .sslApplications: return Strings.Models.backupSectionSslApplications
            case .customCertificates: return Strings.Models.backupSectionCustomCertificates
            case .dns: return Strings.Models.backupSectionDns
            case .breakpoints: return Strings.Models.backupSectionBreakpoints
            case .rewrite: return Strings.Models.backupSectionRewrite
            case .latency: return Strings.Models.backupSectionLatency
            case .noCaching: return Strings.Models.backupSectionNoCaching
            case .reverse: return Strings.Models.backupSectionReverse
            case .external: return Strings.Models.backupSectionExternal
            case .h2c: return Strings.Models.backupSectionH2c
            case .protobuf: return Strings.Models.backupSectionProtobuf
            case .organization: return Strings.Models.backupSectionOrganization
            case .settings: return Strings.Models.backupSectionSettings
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
            var captureLocalRequests: Bool?
            var monospacedFontFamily: String?
            var codeTabWidth: Int?
            var use24HourClock: Bool?
            var showFullDate: Bool?
            var proxymanCompatibleShortcuts: Bool?
            var showAlternatingRows: Bool?
            var defaultCopyFormat: String?
            var fontSize: Double?
            var useMonospacedFont: Bool?
            var scrollBeyondLastLine: Bool?
            var contentLayout: String?
            var appIconStyle: String?
            var autoStartRecording: Bool?
            var warnBeforeQuit: Bool?
            var showUpdateNotifications: Bool?
            var applicationLanguage: String?
            var mcpEnabled: Bool?
            var mcpRedactSensitiveData: Bool?
            var preserveOriginalHeaders: Bool?
            var restorePreviousSystemProxy: Bool?
            var automaticTrafficCleanup: Bool?
            var cleanupMemoryLimitMB: Int?
            var cleanupIntervalMinutes: Int?
            var appearance: String?

            var valid: Bool {
                (truncationStyle.map { ["head", "middle", "tail"].contains($0) } ?? true)
                    && NetworkAccessPolicy.validationError(for: allowedPeerRanges ?? []) == nil
                    && SystemProxyBypassList.validationError(systemBypassHosts ?? []) == nil
                    && (codeTabWidth.map { (1...16).contains($0) } ?? true)
                    && (monospacedFontFamily.map { $0.utf8.count <= 256 && !$0.contains("\0") } ?? true)
                    && (defaultCopyFormat.map { RequestCode.Format(rawValue: $0) != nil } ?? true)
                    && (fontSize.map { $0.isFinite && (8...32).contains($0) } ?? true)
                    && (contentLayout.map { ["vertical", "horizontal"].contains($0) } ?? true)
                    && (appIconStyle.map { ["earth", "mars", "candy", "classic"].contains($0) } ?? true)
                    && (applicationLanguage.map { (["system"] + AppLanguage.allCases.map(\.rawValue)).contains($0) } ?? true)
                    && (appearance.map { ["system", "light", "dark"].contains($0) } ?? true)
                    && (cleanupMemoryLimitMB.map { (64...65536).contains($0) } ?? true)
                    && (cleanupIntervalMinutes.map { (1...60).contains($0) } ?? true)
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
                captureLocalRequests = settings.captureLocalRequests
                monospacedFontFamily = settings.monospacedFontFamily
                codeTabWidth = settings.codeTabWidth
                use24HourClock = settings.use24HourClock
                showFullDate = settings.showFullDate
                proxymanCompatibleShortcuts = settings.proxymanCompatibleShortcuts
                showAlternatingRows = settings.showAlternatingRows
                defaultCopyFormat = settings.defaultCopyFormat.rawValue
                fontSize = settings.fontSize
                useMonospacedFont = settings.useMonospacedFont
                scrollBeyondLastLine = settings.scrollBeyondLastLine
                contentLayout = settings.contentLayout
                appIconStyle = settings.appIconStyle
                autoStartRecording = settings.autoStartRecording
                warnBeforeQuit = settings.warnBeforeQuit
                showUpdateNotifications = settings.showUpdateNotifications
                applicationLanguage = settings.applicationLanguage
                mcpEnabled = settings.mcpEnabled
                mcpRedactSensitiveData = settings.mcpRedactSensitiveData
                preserveOriginalHeaders = settings.preserveOriginalHeaders
                restorePreviousSystemProxy = settings.restorePreviousSystemProxy
                automaticTrafficCleanup = settings.automaticTrafficCleanup
                cleanupMemoryLimitMB = settings.cleanupMemoryLimitMB
                cleanupIntervalMinutes = settings.cleanupIntervalMinutes
                appearance = settings.appearance
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
                if let captureLocalRequests { settings.captureLocalRequests = captureLocalRequests }
                if let monospacedFontFamily { settings.monospacedFontFamily = monospacedFontFamily }
                if let codeTabWidth { settings.codeTabWidth = codeTabWidth }
                if let use24HourClock { settings.use24HourClock = use24HourClock }
                if let showFullDate { settings.showFullDate = showFullDate }
                if let proxymanCompatibleShortcuts { settings.proxymanCompatibleShortcuts = proxymanCompatibleShortcuts }
                if let showAlternatingRows { settings.showAlternatingRows = showAlternatingRows }
                if let raw = defaultCopyFormat, let format = RequestCode.Format(rawValue: raw) { settings.defaultCopyFormat = format }
                if let fontSize { settings.fontSize = fontSize }
                if let useMonospacedFont { settings.useMonospacedFont = useMonospacedFont }
                if let scrollBeyondLastLine { settings.scrollBeyondLastLine = scrollBeyondLastLine }
                if let contentLayout { settings.contentLayout = contentLayout }
                if let appIconStyle { settings.appIconStyle = appIconStyle }
                if let autoStartRecording { settings.autoStartRecording = autoStartRecording }
                if let warnBeforeQuit { settings.warnBeforeQuit = warnBeforeQuit }
                if let showUpdateNotifications { settings.showUpdateNotifications = showUpdateNotifications }
                if let applicationLanguage { settings.applicationLanguage = applicationLanguage }
                if let mcpEnabled { settings.mcpEnabled = mcpEnabled }
                if let mcpRedactSensitiveData { settings.mcpRedactSensitiveData = mcpRedactSensitiveData }
                if let preserveOriginalHeaders { settings.preserveOriginalHeaders = preserveOriginalHeaders }
                if let restorePreviousSystemProxy { settings.restorePreviousSystemProxy = restorePreviousSystemProxy }
                if let automaticTrafficCleanup { settings.automaticTrafficCleanup = automaticTrafficCleanup }
                if let cleanupMemoryLimitMB { settings.cleanupMemoryLimitMB = cleanupMemoryLimitMB }
                if let cleanupIntervalMinutes { settings.cleanupIntervalMinutes = cleanupIntervalMinutes }
                if let appearance { settings.appearance = appearance }
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

    var version: Int? = Self.currentVersion
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
        guard data.count <= Self.fileLimit else { throw BackupError(OperationIssue.modelBackupExportLimit) }
        return data
    }

    static func contents(of url: URL) throws -> Data {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw BackupError(OperationIssue.modelBackupRegularFileRequired)
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: fileLimit + 1) ?? Data()
        guard data.count <= fileLimit else { throw BackupError(OperationIssue.modelBackupImportLimit) }
        return data
    }

    static func read(_ data: Data) throws -> (RuleBackup, [String]) {
        guard data.count <= fileLimit else { throw BackupError(OperationIssue.modelBackupImportLimit) }
        let sections = Set(Section.allCases.map(\.rawValue))
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              !sections.isDisjoint(with: object.keys) else {
            throw BackupError(OperationIssue.modelBackupFileRequired)
        }
        guard object["version"] as? Int == Self.currentVersion else { throw BackupError(OperationIssue.modelBackupUnsupportedVersion) }
        let backup = try JSONDecoder().decode(Self.self, from: data)
        guard backup.version == Self.currentVersion else { throw BackupError(OperationIssue.modelBackupUnsupportedVersion) }
        guard backup.settings?.valid != false else { throw BackupError(OperationIssue.modelBackupSettingsInvalid) }
        guard !backup.changes(from: RuleBackup(), mode: .merge).isEmpty else {
            throw BackupError(OperationIssue.modelBackupEmpty)
        }

        var unknown = Set(object.keys).subtracting(sections.union(["version", "organization"]))
        if let preferences = object["settings"] as? [String: Any] {
            let names = ["port", "mitmEnabled", "mitmExcluded", "autoStart", "autoTakeOverSystemProxy", "maxBodyMB", "maxTransactions", "followLatest", "extras"]
            unknown.formUnion(Set(preferences.keys).subtracting(names).map { "settings.\($0)" })
        }
        if let error = backup.organization?.validationIssue { throw BackupError(error) }
        if let error = backup.protobuf?.validationIssue { throw BackupError(error) }
        try backup.validateRules(object)
        return (backup, unknown.sorted())
    }

    /// Validates typed edits too, before RulesStore commits the canonical configuration.
    /// Raw-key validation remains in read(_:), where original imported JSON is available.
    func validate() throws {
        guard version == Self.currentVersion else { throw BackupError(OperationIssue.modelBackupUnsupportedVersion) }
        guard settings?.valid != false else { throw BackupError(OperationIssue.modelBackupSettingsInvalid) }
        if let issue = organization?.validationIssue { throw BackupError(issue) }
        if let issue = protobuf?.validationIssue { throw BackupError(issue) }
        try validateRules([:])
    }

    private func validateRules(_ object: [String: Any]) throws {
        let classicKeys: Set<String> = ["id", "enabled", "pattern", "target", "comment", "responseStatus", "responseHeaders", "urlRegex", "blockAction"]
        for section in Section.allCases {
            guard let path = section.classicRules else { continue }
            try Self.validateIDs(self[keyPath: path], section: section)
            try Self.validateKeys(object, section: section, allowed: classicKeys)
            for rule in self[keyPath: path] ?? [] {
                if let regex = rule.urlRegex,
                   regex.isEmpty || regex.utf8.count > 8192 || URLRule.regexCache(regex) == nil {
                    throw BackupError(OperationIssue.modelBackupSectionRegexInvalid(section))
                }
            }
        }
        try Self.validateIDs(sslApplications, section: .sslApplications)
        try Self.validateKeys(object, section: .sslApplications, allowed: ["enabled", "bundleID", "name", "action"])
        if let sslApplications, !sslApplications.allSatisfy({ SSLApplicationRule.isValid($0.id) }) {
            throw BackupError(OperationIssue.modelBackupSslBundleInvalid)
        }
        try Self.validateIDs(customCertificates, section: .customCertificates)
        try Self.validateKeys(object, section: .customCertificates,
                              allowed: ["id", "enabled", "name", "hostPattern", "certificatePath", "privateKeyPath"])
        for rule in customCertificates ?? [] {
            let host = rule.hostPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            let domain = host.hasPrefix("*.") ? String(host.dropFirst(2)) : host
            guard !domain.isEmpty, !domain.contains("*"), !domain.contains("/"),
                  !domain.contains(":") || URLParser.isIPAddress(URLParser.bareHost(domain)),
                  domain.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  !host.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !rule.certificatePath.isEmpty, !rule.privateKeyPath.isEmpty,
                  !rule.certificatePath.contains("\0"), !rule.privateKeyPath.contains("\0") else {
                throw BackupError(OperationIssue.modelBackupCertificateInvalid)
            }
        }
        try Self.validateIDs(dns, section: .dns)
        try Self.validateKeys(object, section: .dns, allowed: ["id", "enabled", "name", "hostPattern", "ip"])
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
                    throw BackupError(OperationIssue.modelBackupRewriteRegexInvalid)
                }
                for action in rule.actions {
                    switch action {
                    case .requestHeader(_, let name, let value), .responseHeader(_, let name, let value):
                        if name.isEmpty || !name.utf8.allSatisfy(Self.isTokenByte)
                            || value.utf8.contains(where: { $0 < 32 && $0 != 9 || $0 == 127 }) {
                            throw BackupError(OperationIssue.modelBackupRewriteHeaderInvalid)
                        }
                    case .script(_, let source):
                        guard source.utf8.count <= ScriptingService.sourceLimit else {
                            throw BackupError(OperationIssue.modelBackupScriptSize(ScriptingService.sourceLimit / 1024))
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
        if let error = latency?.validationIssue { throw BackupError(error) }
        try Self.validateIDs(reverse, section: .reverse)
        var reversePorts = Set<UInt16>()
        for rule in reverse ?? [] where rule.enabled {
            do { _ = try ReverseProxyRoute(rule) }
            catch { throw BackupError(error.localizedDescription) }
            guard reversePorts.insert(rule.listenPort).inserted else { throw BackupError(OperationIssue.modelBackupReverseDuplicatePort) }
        }
        if let external, external.enabled, let error = external.validationIssue { throw BackupError(error) }
        if let h2c {
            guard h2c.hosts.count <= 1000, h2c.hosts.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 && !$0.contains("/") }) else {
                throw BackupError(OperationIssue.modelBackupH2cHostInvalid)
            }
        }
        for (index, rule) in (mapLocal ?? []).enumerated() {
            if let status = rule.responseStatus, !(200...599).contains(status) {
                throw BackupError(OperationIssue.modelBackupMapLocalStatusInvalid(index + 1))
            }
            if rule.responseHeaders?.pairs.contains(where: { field in
                field.name.isEmpty || !field.name.utf8.allSatisfy(Self.isTokenByte) ||
                    field.value.utf8.contains { $0 < 32 && $0 != 9 || $0 == 127 }
            }) == true {
                throw BackupError(OperationIssue.modelBackupMapLocalHeadersInvalid(index + 1))
            }
        }
        for (index, rule) in (mapRemote ?? []).enumerated() where rule.enabled && !rule.target.isEmpty {
            guard let url = URLComponents(string: rule.target), let host = url.host, !host.isEmpty,
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  url.user == nil, url.password == nil, url.fragment == nil,
                  url.port.map({ (1...65535).contains($0) }) ?? true else {
                throw BackupError(OperationIssue.modelBackupMapRemoteUrlInvalid(index + 1))
            }
        }
        for (index, rule) in (dns ?? []).enumerated() where rule.enabled {
            guard !rule.hostPattern.isEmpty, URLParser.isIPAddress(rule.ip) else {
                throw BackupError(OperationIssue.modelBackupDnsTargetInvalid(index + 1))
            }
        }
        for (index, rule) in (breakpoints ?? []).enumerated() where rule.enabled && rule.rule.matchMode == .regex {
            guard !rule.rule.regexPattern.isEmpty,
                  (try? NSRegularExpression(pattern: rule.rule.regexPattern)) != nil else {
                throw BackupError(OperationIssue.modelBackupBreakpointRegexInvalid(index + 1))
            }
        }
    }

    private static func validateIDs<T: Identifiable>(_ records: [T]?, section: Section) throws {
        guard let records else { return }
        guard Set(records.map(\.id)).count == records.count else {
            throw BackupError(OperationIssue.modelBackupDuplicateRuleIds(section))
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
            throw BackupError(OperationIssue.modelBackupUnknownFields(location, unknown.joined(separator: ", ")))
        }
    }

    private static func isTokenByte(_ value: UInt8) -> Bool {
        (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
            || "!#$%&'*+-.^_`|~".utf8.contains(value)
    }

    func migrationNotes() -> [String] {
        let local = (mapLocal ?? []).enumerated().compactMap { index, rule -> String? in
            guard rule.enabled, !rule.target.isEmpty, !FileManager.default.isReadableFile(atPath: rule.target) else { return nil }
            return Strings.Models.backupMapLocalPathUnavailable(index + 1)
        }
        let certificates = (customCertificates ?? []).enumerated().compactMap { index, rule -> String? in
            guard rule.enabled, !FileManager.default.isReadableFile(atPath: rule.certificatePath)
                || !FileManager.default.isReadableFile(atPath: rule.privateKeyPath) else { return nil }
            return Strings.Models.backupCertificatePathUnavailable(index + 1)
        }
        return local + certificates
    }

    func subset(_ section: Section?) -> RuleBackup {
        guard let section else {
            var copy = self
            copy.version = Self.currentVersion
            return copy
        }
        var result = RuleBackup(version: Self.currentVersion)
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

    struct BackupError: LocalizedError, OperationIssueProviding {
        let operationIssue: OperationIssue
        init(_ issue: OperationIssue) { operationIssue = issue }
        init(_ diagnostic: String) { operationIssue = .technical(diagnostic) }
        var errorDescription: String? { operationIssue.diagnostic }
    }
}

// 诊断使用稳定 section ID；界面才读取该 section 的本地化标题。
extension OperationIssue {
    static func modelBackupSectionRegexInvalid(_ section: RuleBackup.Section) -> Self {
        let issue = Self.modelBackupSectionRegexInvalid(section.rawValue)
        return Self(code: issue.code, diagnostic: issue.diagnostic,
                    render: { Strings.Models.backupSectionRegexInvalid(section.localizedTitle) })
    }
    static func modelBackupDuplicateRuleIds(_ section: RuleBackup.Section) -> Self {
        let issue = Self.modelBackupDuplicateRuleIds(section.rawValue)
        return Self(code: issue.code, diagnostic: issue.diagnostic,
                    render: { Strings.Models.backupDuplicateRuleIds(section.localizedTitle) })
    }
}
