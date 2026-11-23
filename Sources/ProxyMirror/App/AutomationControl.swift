import AppKit
import Darwin
import Foundation
@testable import ProxyMirrorCore

/// The application service shared by the CLI and MCP. Mutations run on the main
/// actor so a rule update cannot race a UI edit or a backup preview transaction.
enum AutomationControl {
    private static let arrayTools: Set<String> = [
        "mapLocal", "mapRemote", "blockList", "allowList", "sslProxyingList", "sslApplications",
        "customCertificates", "dns", "breakpoints", "rewrite", "latency", "protobuf", "reverse"
    ]

    @MainActor
    static func execute(_ arguments: [String: Any], app: AppState) throws -> Data {
        let operation = try string(arguments, "operation")
        let result: Any
        switch operation {
        case "proxy_address":
            result = ["host": "127.0.0.1", "port": Int(app.settings.port), "listening": app.proxyRunning,
                      "url": "http://127.0.0.1:\(app.settings.port)"]
        case "mcp_config":
            guard let config = MCPServer.configuration else { throw LocalControlError.failed("MCP 服务未启用。") }
            result = config
        case "status":
            result = ["listening": app.proxyRunning, "recording": app.recordingEnabled,
                      "systemProxyActive": app.systemProxyActive, "count": app.store.transactions.count,
                      "port": Int(app.settings.port), "http2": app.settings.http2Enabled]
        case "query_flows", "get_flow", "export_flows", "copy_as_code":
            let flows = try matching(arguments, app: app)
            switch operation {
            case "query_flows":
                result = flows.map { tx -> [String: Any] in
                    var row: [String: Any] = ["id": tx.id.uuidString, "sequence": tx.seq, "method": tx.method,
                        "url": tx.fullURL, "status": tx.statusCode, "state": tx.state.rawValue,
                        "durationMS": tx.duration * 1000, "requestBytes": max(tx.requestBytes, tx.requestBody.count),
                        "responseBytes": max(tx.responseBytes, tx.responseBody.count), "comment": tx.comment,
                        "rules": tx.ruleMatches, "startedAt": ISO8601DateFormatter().string(from: tx.startedAt)]
                    if let name = tx.graphqlOperationName { row["graphqlOperation"] = name }
                    if let pid = tx.clientPID { row["clientPID"] = Int(pid) }
                    if let alpn = tx.upstreamProtocol { row["upstreamProtocol"] = alpn }
                    return row
                }
            case "get_flow":
                guard arguments["id"] != nil, let tx = flows.first else { throw LocalControlError.noMatches("找不到指定流量。") }
                try checkBodyBudget([tx])
                return try encode(SessionRecord(tx))
            case "copy_as_code":
                guard arguments["id"] != nil, let tx = flows.first else { throw LocalControlError.noMatches("找不到指定流量。") }
                let language = (arguments["language"] as? String ?? "curl").lowercased()
                let code: String
                if language == "curl", tx.isTunnel { code = ExportService.curlCommand(tx) }
                else { code = try generatedCode(tx, language: language) }
                result = ["language": language, "code": code]
            default:
                guard !flows.isEmpty else { throw LocalControlError.noMatches("没有符合筛选条件的流量。") }
                try checkBodyBudget(flows)
                let format = arguments["format"] as? String ?? "har"
                switch format {
                case "har": result = ExportService.buildHAR(flows)
                case "json":
                    let data = try encode(flows.map(SessionRecord.init))
                    if app.settings.redactSensitiveHeaders { return try ExportRedaction.jsonData(data) }
                    return data
                case "session":
                    return try SessionFile(transactions: flows, pinnedDomains: [], selected: []).exportData(redactSensitiveHeaders: app.settings.redactSensitiveHeaders)
                case "csv":
                    let header = ["Sequence", "ID", "Method", "Status", "URL", "Duration(ms)", "Request Bytes", "Response Bytes"]
                    let rows = [header] + flows.map { tx in [String(tx.seq), tx.id.uuidString, tx.method,
                        String(tx.statusCode), tx.fullURL, String(tx.duration * 1000),
                        String(max(tx.requestBytes, tx.requestBody.count)), String(max(tx.responseBytes, tx.responseBody.count))] }
                    return Data(rows.map { $0.map(csv).joined(separator: ",") }.joined(separator: "\r\n").utf8)
                default: throw LocalControlError.usage("format 必须为 har、json、csv 或 session。")
                }
            }
        case "rules": result = try rules(arguments)
        case "folders": result = try folders(arguments)
        case "tools":
            let action = arguments["action"] as? String ?? "list"
            let organization = RuleOrganizationStore.shared
            if action != "list" {
                guard ["enable", "disable"].contains(action) else { throw LocalControlError.usage("工具动作支持 list、enable、disable。") }
                let tool = canonicalTool(try string(arguments, "tool"))
                guard toolNames.contains(tool) else { throw LocalControlError.usage("未知工具 \(tool)。") }
                try organization.setEnabled(action == "enable", tool: tool)
            }
            result = toolNames.sorted().map { ["tool": $0, "enabled": organization.isEnabled($0)] as [String: Any] }
        case "external_proxy": result = try externalProxy(arguments, app: app)
        case "set_recording":
            guard let enabled = arguments["enabled"] as? Bool else { throw LocalControlError.usage("enabled 需要布尔值。") }
            app.recordingEnabled = enabled
            result = ["recording": app.recordingEnabled, "listening": app.proxyRunning]
        case "http_version":
            if let enabled = arguments["http2"] as? Bool {
                app.settings.http2Enabled = enabled
                ProxyEngine.shared.http2Enabled = enabled
            }
            result = ["http2": app.settings.http2Enabled, "scope": "new connections"]
        case "launch":
            guard app.proxyRunning else { throw LocalControlError.failed("请先启动代理监听。") }
            let name = try string(arguments, "target").lowercased()
            let aliases: [String: ProxyAutomation.Target] = ["terminal": .terminal, "iterm": .iTerm, "ghostty": .ghostty,
                "chrome": .chrome, "firefox": .firefox, "electron": .electron, "custom": .customTerminal]
            guard let target = aliases[name] else { throw LocalControlError.usage("target 支持 terminal/iterm/ghostty/chrome/firefox/electron/custom。") }
            let application: URL?
            if let path = arguments["application"] as? String {
                guard path.hasPrefix("/"), path.hasSuffix(".app"), FileManager.default.fileExists(atPath: path) else {
                    throw LocalControlError.usage("application 必须为已安装 .app 的绝对路径。")
                }
                application = URL(fileURLWithPath: path)
            } else { application = nil }
            result = ["message": try ProxyAutomation.launch(target, port: app.settings.port,
                certificate: CertificateAuthority.shared.caCertPath, application: application)]
        case "factory_reset": result = try factoryReset(arguments, app: app)
        case "script_help":
            result = ["worker": "JavaScriptCore", "stages": ["onRequest", "onResponse", "onWebSocket"],
                      "example": "async function onRequest(request) { console.info(request.url); return request; }",
                      "note": "Scripts execute in an isolated worker. Review generated code before activation."]
        default: throw LocalControlError.usage("未知自动化操作 \(operation)。")
        }
        return try json(result)
    }

    // Kept separate so code-generator expansion remains a core concern. This
    // adapter is updated alongside RequestCode.Format by the code-tool module.
    private static func generatedCode(_ tx: Transaction, language: String) throws -> String {
        let aliases = ["javascript": "fetch", "javascript-fetch": "fetch", "python-requests": "python", "node": "nodeHTTP", "objc": "objectiveC"]
        let target = aliases[language] ?? language
        guard let format = RequestCode.Format.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(target) == .orderedSame }),
              RequestCode.supported(format, for: tx) else {
            throw LocalControlError.usage("此请求不支持代码目标 \(language)。可用目标：\(RequestCode.Format.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return RequestCode.generate(tx, format: format)
    }

    private static var toolNames: Set<String> {
        arrayTools.union(["noCaching", "external"])
    }

    @MainActor
    private static func matching(_ arguments: [String: Any], app: AppState) throws -> [Transaction] {
        let limit = arguments["limit"] as? Int ?? 100
        guard (1...1000).contains(limit) else { throw LocalControlError.usage("limit 必须为 1 到 1000。") }
        let selected = arguments["selected"] as? Bool ?? false
        let scope = selected ? app.activeStore.selectedTransactions : app.store.transactions
        if selected, scope.isEmpty { throw LocalControlError.noMatches("当前视图没有选中的流量。") }
        let id = try optionalUUID(arguments, "id")
        let afterID = try optionalUUID(arguments, "afterId")
        let after: Int?
        if let afterID {
            guard let flow = app.store.transactions.first(where: { $0.id == afterID }) else {
                throw LocalControlError.noMatches("afterId 引用的流量已不存在。")
            }
            after = flow.seq
        } else { after = nil }
        if let status = arguments["status"] as? Int, status != 0, !(100...599).contains(status) {
            throw LocalControlError.usage("status 必须为 0 或 100 到 599。")
        }
        let matching = scope.lazy.filter { tx in
            !tx.hideFromList && (id.map { tx.id == $0 } ?? true)
                && (after.map { tx.seq > $0 } ?? true)
                && ((arguments["url"] as? String).map { tx.fullURL.localizedCaseInsensitiveContains($0)
                    || tx.originalURL?.localizedCaseInsensitiveContains($0) == true } ?? true)
                && ((arguments["domain"] as? String).map { tx.host.caseInsensitiveCompare($0) == .orderedSame } ?? true)
                && ((arguments["method"] as? String).map { tx.method.caseInsensitiveCompare($0) == .orderedSame } ?? true)
                && ((arguments["status"] as? Int).map { tx.statusCode == $0 } ?? true)
        }
        // Incremental polling must return the earliest unseen page. Returning
        // the latest page here would permanently skip flows when a burst exceeds limit.
        if after != nil { return Array(matching.prefix(limit)) }
        return Array(matching.reversed().prefix(limit).reversed())
    }

    @MainActor
    private static func rules(_ arguments: [String: Any]) throws -> Any {
        let tool = canonicalTool(try string(arguments, "tool"))
        guard arrayTools.contains(tool) else { throw LocalControlError.usage("此规则工具暂不支持逐条操作，请使用 rules export/preview/apply：\(tool)。") }
        let action = arguments["action"] as? String ?? "list"
        var backup = try object(RulesStore.shared.backup())
        var rows: [[String: Any]]
        switch tool {
        case "protobuf": rows = try ProtobufRuntimeStore.shared.snapshot().rules.map(object)
        case "reverse": rows = try ReverseProxyController.shared.rules.map(object)
        case "latency":
            let latency = LatencyConditions.snapshot()
            let rules: [NetworkConditionRule]
            if let existing = latency.rules { rules = existing }
            else if latency.enabled {
                var legacy = NetworkConditionRule(legacy: latency, name: "旧版弱网设置")
                legacy.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
                rules = [legacy]
            } else { rules = [] }
            rows = try rules.map(object)
        default: rows = backup[tool] as? [[String: Any]] ?? []
        }
        let identifier = arguments["id"] as? String
        let index = identifier.flatMap { id in rows.firstIndex { ruleID($0, tool: tool).caseInsensitiveCompare(id) == .orderedSame } }
        if action == "list" {
            if let folder = try optionalUUID(arguments, "folderId") {
                rows = rows.filter { RuleOrganizationStore.shared.folderID(ruleID: ruleID($0, tool: tool), tool: tool) == folder }
            }
            return rows
        }
        if action == "get" || action == "read" {
            guard let index else { throw LocalControlError.noMatches("找不到规则。") }
            return rows[index]
        }
        var affected: [String: Any]?
        switch action {
        case "add", "create":
            guard var row = arguments["rule"] as? [String: Any] else { throw LocalControlError.usage("新增需要 rule JSON 对象。") }
            let requestedEnabled = row["enabled"] ?? true
            let defaults: [String: Any]
            switch tool {
            case "sslApplications": defaults = try object(SSLApplicationRule(bundleID: row["bundleID"] as? String ?? ""))
            case "protobuf": defaults = try object(ProtobufMappingRule())
            case "reverse": defaults = try object(ReverseProxyRule())
            case "latency": defaults = try object(NetworkConditionRule())
            case "dns": defaults = try object(DNSSpoofRule())
            case "breakpoints": defaults = try object(BreakpointRule())
            case "rewrite": defaults = try object(RewriteRuleSet())
            case "customCertificates": defaults = try object(CustomCertificateRule())
            default: defaults = [:]
            }
            for (key, value) in defaults where row[key] == nil { row[key] = value }
            if tool != "sslApplications", row["id"] == nil { row["id"] = UUID().uuidString }
            row["enabled"] = requestedEnabled
            if ["mapLocal", "mapRemote", "blockList", "allowList", "sslProxyingList"].contains(tool) {
                if row["target"] == nil { row["target"] = "" }
                if row["comment"] == nil { row["comment"] = "" }
            }
            let id = ruleID(row, tool: tool)
            guard !id.isEmpty, !rows.contains(where: { ruleID($0, tool: tool).caseInsensitiveCompare(id) == .orderedSame }) else {
                throw LocalControlError.usage("规则 ID 为空或已存在。")
            }
            rows.append(row)
            affected = row
        case "update":
            guard let index, let fields = arguments["rule"] as? [String: Any] else { throw LocalControlError.noMatches("更新需要已有规则 ID 和 rule 对象。") }
            let originalID = ruleID(rows[index], tool: tool)
            rows[index].merge(fields) { _, new in new }
            guard ruleID(rows[index], tool: tool).caseInsensitiveCompare(originalID) == .orderedSame else {
                throw LocalControlError.usage("更新不能更改规则 ID。")
            }
            affected = rows[index]
        case "delete", "remove":
            guard let index else { throw LocalControlError.noMatches("找不到要删除的规则。") }
            affected = rows.remove(at: index)
        case "enable", "disable":
            guard let index else { throw LocalControlError.noMatches("找不到要切换的规则。") }
            rows[index]["enabled"] = action == "enable"
            affected = rows[index]
        default: throw LocalControlError.usage("规则动作支持 list/get/add/update/delete/enable/disable。")
        }
        switch tool {
        case "reverse":
            try ReverseProxyController.shared.save(JSONDecoder().decode([ReverseProxyRule].self, from: json(rows)))
        default:
            if tool == "protobuf" {
                var configuration = ProtobufRuntimeStore.shared.snapshot()
                configuration.rules = try JSONDecoder().decode([ProtobufMappingRule].self, from: json(rows))
                backup[tool] = try object(configuration)
            } else if tool == "latency" {
                var latency = LatencyConditions.snapshot()
                latency.rules = try JSONDecoder().decode([NetworkConditionRule].self, from: json(rows))
                if action == "add" || action == "create" { latency.enabled = true }
                backup[tool] = try object(latency)
            } else { backup[tool] = rows }
            if action == "delete" || action == "remove", let affected,
               var organization = backup["organization"] as? [String: Any],
               var assignments = organization["assignments"] as? [String: String] {
                assignments.removeValue(forKey: tool + ":" + ruleID(affected, tool: tool))
                organization["assignments"] = assignments
                backup["organization"] = organization
            }
            // Validate the same strict schema used by backup previews before touching disk.
            let (validated, _) = try RuleBackup.read(json(backup))
            try RulesStore.shared.install(validated)
        }
        return ["tool": tool, "action": action, "rule": affected ?? [:], "count": rows.count]
    }

    private static func ruleID(_ row: [String: Any], tool: String) -> String {
        tool == "sslApplications" ? SSLApplicationRule.normalize(row["bundleID"] as? String ?? "") : row["id"] as? String ?? ""
    }

    @MainActor
    private static func folders(_ arguments: [String: Any]) throws -> Any {
        let tool = canonicalTool(try string(arguments, "tool"))
        guard toolNames.contains(tool) else { throw LocalControlError.usage("未知工具。") }
        let store = RuleOrganizationStore.shared
        let action = arguments["action"] as? String ?? "list"
        switch action {
        case "list": return try JSONSerialization.jsonObject(with: encode(store.folders(tool: tool)))
        case "create":
            return try object(store.createFolder(tool: tool, name: try string(arguments, "name"), parentID: try optionalUUID(arguments, "parentId")))
        case "rename", "move", "delete", "enable", "disable":
            guard let id = try optionalUUID(arguments, "id"), store.folders(tool: tool).contains(where: { $0.id == id }) else {
                throw LocalControlError.noMatches("找不到文件夹。")
            }
            if action == "rename" { try store.renameFolder(id: id, name: try string(arguments, "name")) }
            if action == "move" { try store.moveFolder(id: id, parentID: try optionalUUID(arguments, "parentId")) }
            if action == "delete" { try store.deleteFolder(id: id) }
            if action == "enable" || action == "disable" { try store.setFolderEnabled(id: id, enabled: action == "enable") }
        case "assign":
            try store.assign(ruleID: try string(arguments, "ruleId"), tool: tool, folderID: try optionalUUID(arguments, "folderId"))
        default: throw LocalControlError.usage("文件夹动作支持 list/create/rename/move/delete/enable/disable/assign。")
        }
        return ["tool": tool, "action": action, "success": true]
    }

    @MainActor
    private static func externalProxy(_ arguments: [String: Any], app: AppState) throws -> Any {
        let action = arguments["action"] as? String ?? "get"
        var config = InterceptionConfig.shared.externalProxy.value
        if action == "set" {
            guard let raw = arguments["config"] as? [String: Any] else { throw LocalControlError.usage("set 需要完整 config 对象。") }
            var merged = try object(config)
            merged.merge(raw) { _, new in new }
            config = try JSONDecoder().decode(ExternalProxyConfig.self, from: json(merged))
            if let error = config.validationError { throw LocalControlError.usage(error) }
            guard !config.targetsLoopback(port: Int(app.settings.port)) else { throw LocalControlError.usage("外部代理不能指向 ProxyMirror。") }
        } else if action == "disable" { config.enabled = false }
        else if action != "get" { throw LocalControlError.usage("external-proxy 支持 get/set/disable。") }
        if action != "get" {
            var backup = RulesStore.shared.backup()
            backup.external = config
            try RulesStore.shared.install(backup)
        }
        var result = try object(config)
        result["password"] = config.password.isEmpty ? "" : "<redacted>"
        return result
    }

    @MainActor
    private static func factoryReset(_ arguments: [String: Any], app: AppState) throws -> Any {
        guard arguments["confirmReset"] as? Bool == true else { throw LocalControlError.usage("恢复出厂设置需要 --confirm-reset。") }
        guard !app.proxyRunning, !app.systemProxyActive, !app.systemProxyBusy, !app.transparentProxyNeedsStop else {
            throw LocalControlError.failed("恢复出厂设置前请停止代理监听、系统代理和透明抓包。")
        }
        let deleteRules = arguments["deleteRules"] as? Bool ?? false
        try AppDiagnostics.factoryReset(keepRules: !deleteRules)
        return ["reset": true, "rulesDeleted": deleteRules, "backupDirectory": AppDiagnostics.backupDirectory.path,
                "restartRequired": true]
    }

    private static func canonicalTool(_ name: String) -> String {
        ["scripting": "rewrite", "reverseProxy": "reverse", "externalProxy": "external"][name] ?? name
    }

    static func parseCLI(_ arguments: [String]) throws -> ([String: Any], String?)? {
        guard let command = arguments.first else { return nil }
        var operation: String
        var action: String?
        var tool: String?
        var offset = 1
        switch command {
        case "export":
            guard arguments.count > 1, ["flows", "logs"].contains(arguments[1]) else { throw LocalControlError.usage("export 需要 flows 或 logs。") }
            operation = "export_flows"; offset = 2
        case "flow": operation = "get_flow"
        case "code": operation = "copy_as_code"
        case "proxy-address": operation = "proxy_address"
        case "factory-reset": operation = "factory_reset"
        case "mcp":
            guard arguments == ["mcp", "config"] else { throw LocalControlError.usage("mcp 支持 config 和 stdio。") }
            return (["operation": "mcp_config"], nil)
        case "tools", "external-proxy":
            operation = command == "tools" ? "tools" : "external_proxy"
            guard arguments.count > 1 else { throw LocalControlError.usage("\(command) 缺少动作。") }
            action = arguments[1]; offset = 2
        case "rules", "folders":
            if command == "rules", arguments.count <= 1 || ["export", "preview", "apply"].contains(arguments[1]) { return nil }
            guard arguments.count > 2 else { throw LocalControlError.usage("\(command) 需要工具名和动作。") }
            operation = command; tool = arguments[1]; action = arguments[2]; offset = 3
        default: return nil
        }
        var object: [String: Any] = ["operation": operation]
        if let action { object["action"] = action }
        if let tool { object["tool"] = tool }
        var output: String?
        var seen = Set<String>()
        var remaining = arguments.dropFirst(offset).makeIterator()
        let valueOptions: [String: String] = ["--url": "url", "--domain": "domain", "--method": "method", "--status": "status",
            "--id": "id", "--after-id": "afterId", "--limit": "limit", "--format": "format", "--language": "language",
            "--tool": "tool", "--name": "name", "--parent-id": "parentId", "--folder-id": "folderId", "--rule-id": "ruleId"]
        while let flag = remaining.next() {
            guard seen.insert(flag).inserted else { throw LocalControlError.usage("参数 \(flag) 只能出现一次。") }
            if let key = ["--selected": "selected", "--confirm-reset": "confirmReset", "--delete-rules": "deleteRules"][flag] {
                object[key] = true; continue
            }
            guard flag == "--input" || flag == "--output" || valueOptions[flag] != nil else { throw LocalControlError.usage("未知参数 \(flag)。") }
            guard let value = remaining.next(), !value.isEmpty, !value.hasPrefix("--") else { throw LocalControlError.usage("\(flag) 缺少值。") }
            if flag == "--output" { output = value; continue }
            if flag == "--input" {
                let data = try RuleBackup.contents(of: URL(fileURLWithPath: value))
                guard let input = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LocalControlError.usage("input 必须为 JSON 对象。") }
                object[operation == "external_proxy" ? "config" : "rule"] = input
            } else if let key = valueOptions[flag] {
                if key == "status" || key == "limit" {
                    guard let number = Int(value) else { throw LocalControlError.usage("\(flag) 需要整数。") }
                    object[key] = number
                } else { object[key] = value }
            }
        }
        if operation != "export_flows", output != nil { throw LocalControlError.usage("此命令不接受 --output。") }
        return (object, output)
    }

    static func installCLI() throws -> URL {
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
            .resolvingSymlinksInPath()
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("proxymirror-cli")
        if FileManager.default.fileExists(atPath: target.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil {
            guard let old = try? FileManager.default.destinationOfSymbolicLink(atPath: target.path),
                  URL(fileURLWithPath: old).lastPathComponent == "ProxyMirror" else {
                throw LocalControlError.failed("\(target.path) 已存在且不是 ProxyMirror 链接，请先选择其他安装位置。")
            }
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: executable)
        try ensureCommandDirectoryInPATH(directory)
        return target
    }

    /// PATH installation is explicit user intent (Help menu / install-path).
    /// Append one marked line, preserving the profile and its existing permissions.
    private static func ensureCommandDirectoryInPATH(_ directory: URL) throws {
        let environment = ProcessInfo.processInfo.environment
        if (environment["PATH"] ?? "").split(separator: ":").contains(Substring(directory.path)) { return }
        let shell = URL(fileURLWithPath: environment["SHELL"] ?? "/bin/zsh").lastPathComponent
        let profileName: String
        switch shell {
        case "zsh": profileName = ".zprofile"
        case "bash": profileName = ".bash_profile"
        case "sh": profileName = ".profile"
        default: throw LocalControlError.failed("已安装 CLI 到 \(directory.path)，请将此目录加入 \(shell) 的 PATH。")
        }
        let profile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(profileName)
        let fd = open(profile.path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LocalControlError.failed("无法更新 \(profile.path)。请将 \(directory.path) 加入 PATH。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_size <= 1024 * 1024 else {
            throw LocalControlError.failed("Shell 配置必须为当前用户的普通文件且不超过 1 MiB。")
        }
        let current = try handle.read(upToCount: 1024 * 1024 + 1) ?? Data()
        let marker = "# ProxyMirror CLI PATH"
        if String(decoding: current, as: UTF8.self).components(separatedBy: "\n").contains(marker) { return }
        let path = "'" + directory.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let addition = "\n\(marker)\nexport PATH=\(path):\"$PATH\"\n"
        try handle.write(contentsOf: Data(addition.utf8))
    }

    private static func string(_ arguments: [String: Any], _ name: String) throws -> String {
        guard let value = arguments[name] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalControlError.usage("\(name) 需要非空字符串。")
        }
        return value
    }

    private static func optionalUUID(_ arguments: [String: Any], _ name: String) throws -> UUID? {
        guard let value = arguments[name] else { return nil }
        if value is NSNull { return nil }
        guard let text = value as? String, let id = UUID(uuidString: text) else { throw LocalControlError.usage("\(name) 需要有效的 UUID。") }
        return id
    }

    private static func checkBodyBudget(_ transactions: [Transaction]) throws {
        let size = transactions.reduce(0) { $0 + $1.requestBody.count + $1.responseBody.count }
        guard size <= 24 * 1024 * 1024 else { throw LocalControlError.failed("正文总量超过 24 MiB，请缩小导出范围。") }
    }

    private static func csv(_ text: String) -> String {
        let safe = text.first.map { "=+-@\t\r".contains($0) } == true ? "'" + text : text
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes, .fragmentsAllowed])
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: encode(value)) as? [String: Any] else { throw LocalControlError.failed("无法编码对象。") }
        return result
    }
}
