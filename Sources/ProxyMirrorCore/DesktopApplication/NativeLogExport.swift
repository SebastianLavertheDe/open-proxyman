import Foundation

/// Traffic logs are complete retained native sessions. They do not share the
/// flow query's latest-N limit or incremental cursor. Grouped logs contain one
/// independently decodable native session per domain.
enum NativeLogExport {
    @MainActor
    static func data(_ arguments: [String: Any], app: AppState) throws -> Data {
        let scope = arguments["scope"] as? String ?? "all"
        guard ["all", "domains"].contains(scope) else { throw LocalControlError.usage("logs scope 必须为 all 或 domains。") }
        if let format = arguments["format"] as? String, !["session", "json"].contains(format) {
            throw LocalControlError.usage("export logs 使用原生 session/json 格式。")
        }
        guard arguments["limit"] == nil, arguments["afterId"] == nil else {
            throw LocalControlError.usage("日志会话导出不接受 limit/afterId；使用 from/to 或 domains 筛选。")
        }
        guard arguments["domains"] == nil || arguments["domains"] is [String] else {
            throw LocalControlError.usage("domains 需要域名字符串数组。")
        }
        let rawDomains = arguments["domains"] as? [String] ?? []
        guard rawDomains.count <= 256 else { throw LocalControlError.usage("域名筛选最多 256 项。") }
        let targets = try rawDomains.map { raw -> ExternalProxyTarget in
            guard let target = ExternalProxyTarget(raw), !target.isURL else { throw LocalControlError.usage("日志域名筛选需要主机名或主机通配：\(raw)") }
            return target
        }
        let from = try date(arguments["from"], key: "from")
        let through = try date(arguments["to"], key: "to")
        if let from, let through, from > through { throw LocalControlError.usage("from 不能晚于 to。") }
        let selected = app.activeStore.selectedTransactions
        let source = arguments["selected"] as? Bool == true ? selected : app.store.transactions
        let transactions = source.filter { tx in
            !tx.hideFromList && (from.map { tx.startedAt >= $0 } ?? true)
                && (through.map { tx.startedAt <= $0 } ?? true)
                && (targets.isEmpty || targets.contains { $0.matches(host: tx.host, url: nil) })
        }
        guard !transactions.isEmpty else { throw LocalControlError.noMatches("没有符合时间或域名筛选条件的日志。") }
        let bodyBytes = transactions.reduce(0) { $0 + $1.requestBody.count + $1.responseBody.count }
        guard bodyBytes <= 24 * 1024 * 1024 else { throw LocalControlError.failed("日志正文超过 24 MiB，请用域名或时间范围拆分。") }
        let selectedIDs = Set(selected.map(\.id))
        @MainActor func session(_ rows: [Transaction]) -> SessionFile {
            SessionFile(transactions: rows, pinnedDomains: app.pinnedDomains, selected: selectedIDs)
        }
        if scope == "all" {
            return try session(transactions).exportData(redactSensitiveHeaders: app.settings.redactSensitiveHeaders)
        }
        let grouped = Dictionary(grouping: transactions, by: { $0.host.lowercased() })
        let groups = grouped.keys.sorted().map { DomainSession(domain: $0, session: session(grouped[$0] ?? [])) }
        let bundle = DomainLogBundle(version: 1, format: "proxymirror-domain-logs", exportedAt: Date(),
                                     from: from, to: through, domains: rawDomains, sessions: groups)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(bundle)
        return app.settings.redactSensitiveHeaders ? try ExportRedaction.jsonData(data) : data
    }

    private struct DomainSession: Encodable {
        let domain: String
        let session: SessionFile
    }
    private struct DomainLogBundle: Encodable {
        let version: Int
        let format: String
        let exportedAt: Date
        let from: Date?
        let to: Date?
        let domains: [String]
        let sessions: [DomainSession]
    }

    private static func date(_ value: Any?, key: String) throws -> Date? {
        guard let value else { return nil }
        guard let text = value as? String else { throw LocalControlError.usage("\(key) 需要 ISO 8601 时间。") }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) else {
            throw LocalControlError.usage("\(key) 需要带时区的 ISO 8601 时间，例如 2026-11-23T08:00:00Z。")
        }
        return date
    }
}
