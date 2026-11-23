import AppKit
import Darwin
import Foundation
import CryptoKit
@testable import ProxyMirrorCore

@main
enum ProxyMirrorEntryPoint {
    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if let first = args.first, !first.hasPrefix("-") || first.hasPrefix("--") || first == "-h" {
            exit(LocalControl.run(args))
        }
        ProxyMirrorMainApp.main()
    }
}

enum LocalControlError: LocalizedError {
    case usage(String)
    case offline
    case failed(String)
    case noMatches(String)
    case stalePreview

    var code: UInt8 {
        switch self {
        case .usage: return 2
        case .offline: return 3
        case .failed: return 4
        case .noMatches: return 5
        case .stalePreview: return 6
        }
    }

    var errorDescription: String? {
        switch self {
        case .usage(let message), .failed(let message), .noMatches(let message): return message
        case .offline: return "无法连接 ProxyMirror。请启动 ProxyMirror.app 并重试。"
        case .stalePreview: return "规则预览已失效。请使用相同的输入文件和导入方式重新预览。"
        }
    }

    var encoded: Data {
        var result = Data([code])
        result.append(contentsOf: (errorDescription ?? "").utf8)
        return result
    }
}

enum LocalControl {
    private static let usage = """
    用法
      ProxyMirror status
      ProxyMirror traffic [筛选选项]
      ProxyMirror export-har --output 路径 [筛选选项]
      ProxyMirror rules export --output 路径 [--tool 工具]
      ProxyMirror rules preview --input 路径 [--mode merge|replace]
      ProxyMirror rules apply --input 路径 --preview-token 令牌 [--mode merge|replace]
      ProxyMirror rules 工具 list|get|add|update|delete|enable|disable [--id ID] [--input JSON文件]
      ProxyMirror export flows|logs --format har|json|csv|session [筛选选项] [--output 路径]
      ProxyMirror flow --id UUID
      ProxyMirror code --id UUID --language curl|httpie|python|javascript|…
      ProxyMirror tools list|enable|disable [--tool 工具]
      ProxyMirror external-proxy get|set|disable [--input JSON文件]
      ProxyMirror proxy-address
      ProxyMirror factory-reset --confirm-reset [--delete-rules]
      ProxyMirror install-path
      ProxyMirror mcp config|stdio

    筛选选项
      --selected       只查当前视图选中的流量
      --url 字符串     按 URL 子串查找
      --method 方法    按 HTTP 方法查找
      --status 状态码  按状态码查找，0 表示暂无状态
      --id UUID        按流量 ID 查找
      --after-id UUID  只查该流量之后捕获的记录
      --limit 数量     返回最近的 N 条，默认 100，最大 1000

    将 --output 设为 - 可将结果写入标准输出。
    规则导出工具支持 mapLocal、mapRemote、blockList、allowList、sslProxyingList、sslApplications、customCertificates、dns、breakpoints、rewrite、latency、noCaching、reverse、external、h2c、protobuf、settings、organization。
    """

    private struct Request: Codable {
        enum Command: String, Codable {
            case status, traffic, exportHAR = "export-har", automation
            case ruleExport = "rules-export", rulePreview = "rules-preview", ruleApply = "rules-apply"
        }

        let version: Int
        let command: Command
        var selected = false
        var url: String?
        var method: String?
        var status: Int?
        var id: UUID?
        var limit = 100
        var ruleTool: RuleBackup.Section?
        var ruleMode: RuleBackup.ImportMode?
        var ruleData: Data?
        var previewToken: String?
        var automationData: Data?
        var afterID: UUID?

        func validate() throws {
            guard version == 1 else { throw LocalControlError.failed("本机命令协议版本不兼容。请使用运行中的应用内的二进制文件。") }
            switch command {
            case .automation:
                guard let automationData, automationData.count <= RuleBackup.fileLimit,
                      (try? JSONSerialization.jsonObject(with: automationData)) is [String: Any] else {
                    throw LocalControlError.usage("自动化命令必须为 \(RuleBackup.fileLimit / 1024 / 1024) MiB 以内的 JSON 对象。")
                }
                return
            case .rulePreview, .ruleApply:
                guard let ruleData, ruleData.count <= RuleBackup.fileLimit, ruleMode != nil else {
                    throw LocalControlError.usage("规则导入需要不超过 \(RuleBackup.fileLimit / 1024 / 1024) MiB 的备份和导入方式。")
                }
                if command == .ruleApply {
                    guard let token = previewToken, token.utf8.count == 64,
                          token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                        throw LocalControlError.usage("rules apply 需要预览结果中的 --preview-token。")
                    }
                }
                return
            case .ruleExport: return
            case .status, .traffic, .exportHAR: break
            }
            guard (1...1000).contains(limit) else { throw LocalControlError.usage("--limit 必须为 1 到 1000。") }
            if let status, status != 0, !(100...599).contains(status) {
                throw LocalControlError.usage("--status 必须为 0 或 100 到 599。")
            }
            if let method, method.isEmpty || !method.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || "!#$%&'*+-.^_`|~".utf8.contains($0)
            }) {
                throw LocalControlError.usage("--method 必须为有效的 HTTP 方法。")
            }
            if let url, url.isEmpty { throw LocalControlError.usage("--url 需要非空字符串。") }
        }

        func matches(_ tx: Transaction) -> Bool {
            guard !tx.hideFromList,
                  id.map({ $0 == tx.id }) ?? true,
                  method.map({ $0.caseInsensitiveCompare(tx.method) == .orderedSame }) ?? true,
                  status.map({ $0 == tx.statusCode }) ?? true else { return false }
            return url.map { substring in
                tx.fullURL.localizedCaseInsensitiveContains(substring) ||
                    tx.originalURL?.localizedCaseInsensitiveContains(substring) == true
            } ?? true
        }
    }

    private struct RuleChanges: Encodable {
        let mode: RuleBackup.ImportMode
        let changes: [RuleBackup.Change]
        let unmappedFields: [String]
        let notes: [String]
        let previewToken: String?
        let applied: Bool
    }

    private struct PreparedImport {
        let backup: RuleBackup
        let unmappedFields: [String]
        let notes: [String]

        init(data: Data) throws {
            do {
                (backup, unmappedFields) = try RuleBackup.read(data)
                notes = backup.migrationNotes()
            } catch {
                throw LocalControlError.usage("规则文件无效（\(error.localizedDescription)）。")
            }
        }
    }

    private static let previewNonce = UUID().uuidString

    private struct Status: Encodable {
        let appRunning = true
        let listening: Bool
        let recording: Bool
        let systemProxyActive: Bool
        let listenAddress: String?
        let liveCount: Int
        let selectedCount: Int

        @MainActor init(_ app: AppState) {
            listening = app.proxyRunning
            recording = app.proxyRunning && app.recordingEnabled
            systemProxyActive = app.systemProxyActive
            listenAddress = app.proxyRunning ? ProxyEngine.shared.listenAddress : nil
            liveCount = app.store.transactions.lazy.filter { !$0.hideFromList }.count
            selectedCount = app.activeStore.selectedTransactions.count
        }
    }

    private struct TrafficRow: Encodable {
        let id: UUID
        let sequence: Int
        let startedAt: Date
        let method: String
        let url: String
        let originalURL: String?
        let status: Int
        let state: String
        let durationMS: Double
        let requestBytes: Int
        let responseBytes: Int
        let requestTruncated: Bool
        let responseTruncated: Bool
        let rules: [String]

        init(_ tx: Transaction) {
            id = tx.id
            sequence = tx.seq
            startedAt = tx.startedAt
            method = tx.method
            url = tx.fullURL
            originalURL = tx.originalURL
            status = tx.statusCode
            state = tx.state.rawValue
            durationMS = tx.duration * 1000
            requestBytes = max(tx.requestBytes, tx.requestBody.count)
            responseBytes = max(tx.responseBytes, tx.responseBody.count)
            requestTruncated = tx.requestTruncated
            responseTruncated = tx.responseTruncated
            rules = tx.ruleMatches
        }
    }

    private enum Snapshot {
        case status(Status)
        case traffic([TrafficRow])
        case har([SessionRecord])
        case ruleBackup(RuleBackup)
        case ruleChanges(RuleChanges)
        case raw(Data)

        func encode() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            switch self {
            case .raw(let data): return data
            case .status(let status): return try encoder.encode(status)
            case .traffic(let rows): return try encoder.encode(rows)
            case .ruleBackup(let backup): return try backup.exportData()
            case .ruleChanges(let changes): return try encoder.encode(changes)
            case .har(let records):
                let har = ExportService.buildHAR(records.map { $0.transaction() })
                return try JSONSerialization.data(withJSONObject: har, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            }
        }
    }

    private static var mcpServer: MCPServer?

    static func start() throws -> DispatchSourceRead {
        let source = try LocalControlSocket.start(handler: handle)
        if UserDefaults.standard.object(forKey: "automation.mcpEnabled") as? Bool != false {
            do { mcpServer = try MCPServer.start() }
            catch { NSLog("[ProxyMirror] MCP 服务启动失败：%@", error.localizedDescription) }
        }
        return source
    }

    static func stopAutomation() {
        mcpServer?.stop()
        mcpServer = nil
    }

    /// Shared dispatch path for the Unix CLI and authenticated HTTP MCP tools.
    static func handle(_ data: Data) -> Data {
        do {
            let request = try JSONDecoder().decode(Request.self, from: data)
            try request.validate()
            let prepared: PreparedImport?
            switch request.command {
            case .ruleApply, .rulePreview:
                prepared = try request.ruleData.map(PreparedImport.init)
            default: prepared = nil
            }
            let snapshot = try DispatchQueue.main.sync {
                try MainActor.assumeIsolated { try capture(request, prepared: prepared) }
            }
            let payload = try snapshot.encode()
            guard payload.count < LocalControlSocket.responseLimit else {
                throw LocalControlError.failed("结果超出 64 MiB，请缩小筛选范围。")
            }
            var reply = Data([0])
            reply.append(payload)
            return reply
        } catch let error as LocalControlError {
            return error.encoded
        } catch {
            return LocalControlError.failed(error.localizedDescription).encoded
        }
    }

    static func automationRequest(_ object: [String: Any]) throws -> Data {
        var request = Request(version: 1, command: .automation)
        request.automationData = try JSONSerialization.data(withJSONObject: object)
        return try JSONEncoder().encode(request)
    }

    @MainActor
    static func installCLI() {
        do { AppState.shared.systemProxyMessage = "命令行已安装：\(try AutomationControl.installCLI().path)；重新打开终端后可使用 proxymirror-cli。" }
        catch { AppState.shared.systemProxyMessage = error.localizedDescription }
    }

    @MainActor
    static func showMCPConfiguration() {
        let alert = NSAlert()
        alert.messageText = "ProxyMirror MCP"
        if let configuration = MCPServer.configuration,
           let data = try? AutomationControl.json(configuration) {
            let text = String(decoding: data, as: UTF8.self)
            alert.informativeText = "HTTP MCP 仅监听本机，连接令牌每次启动更新。也可使用 proxymirror-cli mcp stdio，无需保存令牌。"
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 220))
            let content = NSTextView(frame: scroll.bounds)
            content.string = text
            content.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            content.isEditable = false
            scroll.documentView = content
            scroll.hasVerticalScroller = true
            alert.accessoryView = scroll
            alert.addButton(withTitle: "复制配置")
            alert.addButton(withTitle: "关闭")
            if alert.runModal() == .alertFirstButtonReturn { CopyPaste.copy(text) }
        } else {
            alert.informativeText = "MCP 服务未启动。检查 automation.mcpEnabled 设置后重新启动应用。"
            alert.runModal()
        }
    }

    @MainActor
    private static func capture(_ request: Request, prepared: PreparedImport?) throws -> Snapshot {
        let app = AppState.shared
        switch request.command {
        case .automation:
            guard let data = request.automationData,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LocalControlError.usage("无效的自动化命令。")
            }
            return .raw(try AutomationControl.execute(object, app: app))
        case .status: return .status(Status(app))
        case .ruleExport: return .ruleBackup(RuleBackup.snapshot(settings: app.settings).subset(request.ruleTool))
        case .rulePreview, .ruleApply:
            guard let prepared, let mode = request.ruleMode, let ruleData = request.ruleData else {
                throw LocalControlError.usage("规则导入需要备份和导入方式。")
            }
            let current = RuleBackup.snapshot(settings: app.settings)
            let previewToken = try token(for: ruleData, mode: mode, current: current)
            let applying = request.command == .ruleApply
            if applying {
                guard request.previewToken == previewToken else { throw LocalControlError.stalePreview }
                try RulesStore.shared.install(prepared.backup.resolve(with: current, merge: mode == .merge))
                prepared.backup.settings?.apply(to: app.settings)
            }
            return .ruleChanges(RuleChanges(mode: mode, changes: prepared.backup.changes(from: current, mode: mode),
                                           unmappedFields: prepared.unmappedFields, notes: prepared.notes,
                                           previewToken: applying ? nil : previewToken, applied: applying))
        case .traffic, .exportHAR: break
        }

        let scope = request.selected ? app.activeStore.selectedTransactions : app.store.transactions
        if request.selected, scope.isEmpty { throw LocalControlError.noMatches("当前视图没有选中的流量。") }
        let afterSequence: Int?
        if let afterID = request.afterID {
            guard let reference = app.store.transactions.first(where: { $0.id == afterID }) else {
                throw LocalControlError.noMatches("--after-id 引用的流量已不存在。")
            }
            afterSequence = reference.seq
        } else { afterSequence = nil }
        let eligible = scope.lazy.filter { tx in
            request.matches(tx) && (afterSequence.map { tx.seq > $0 } ?? true)
        }
        let matched = afterSequence == nil
            ? Array(eligible.reversed().prefix(request.limit).reversed())
            : Array(eligible.prefix(request.limit))
        if request.command == .traffic {
            return .traffic(matched.map(TrafficRow.init))
        }
        guard !matched.isEmpty else { throw LocalControlError.noMatches("没有符合筛选条件的流量可导出。") }

        // Snapshot on the main thread and serialize off it. Bound the size before encoding.
        let bodySize = matched.reduce(0) { $0 + $1.requestBody.count + $1.responseBody.count }
        guard bodySize <= 24 * 1024 * 1024 else {
            throw LocalControlError.failed("本次导出的正文超出 24 MiB，请缩小筛选范围。")
        }
        return .har(matched.map(SessionRecord.init))
    }

    private static func token(for data: Data, mode: RuleBackup.ImportMode, current: RuleBackup) throws -> String {
        var hash = SHA256()
        hash.update(data: Data((previewNonce + mode.rawValue).utf8))
        hash.update(data: Data(SHA256.hash(data: data)))
        hash.update(data: Data(SHA256.hash(data: try current.encoded())))
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func run(_ arguments: [String]) -> Int32 {
        if arguments.count == 1, ["help", "--help", "-h"].contains(arguments[0]) {
            print(usage)
            return 0
        }
        do {
            if arguments.first == "install-path" {
                guard arguments.count == 1 else { throw LocalControlError.usage("install-path 无需参数。") }
                print(try AutomationControl.installCLI().path)
                return 0
            }
            if arguments == ["mcp", "stdio"] { return MCPProtocol.runStandardIO() }
            let (request, output) = try parse(arguments)
            let requestBytes = try JSONEncoder().encode(request)
            guard requestBytes.count <= LocalControlSocket.requestLimit else {
                throw LocalControlError.usage("命令数据超出本机接口限制。")
            }
            let reply = try LocalControlSocket.request(requestBytes)
            guard let code = reply.first else { throw LocalControlError.failed("本机控制接口未返回结果。") }
            let payload = reply.dropFirst()
            if code != 0 {
                writeError(String(decoding: payload, as: UTF8.self))
                return Int32(code)
            }
            if let output, output != "-" {
                let kind = request.command == .ruleExport ? "规则备份" : "HAR"
                do { try writePrivateFile(payload, to: URL(fileURLWithPath: output)) }
                catch { throw LocalControlError.failed("无法导出 \(kind)（\(error.localizedDescription)）。") }
            } else {
                try FileHandle.standardOutput.write(contentsOf: payload)
                try FileHandle.standardOutput.write(contentsOf: Data([0x0A]))
            }
            return 0
        } catch let error as LocalControlError {
            writeError(error.localizedDescription)
            return Int32(error.code)
        } catch {
            writeError(error.localizedDescription)
            return 4
        }
    }

    private static func parse(_ arguments: [String]) throws -> (Request, String?) {
        if let (object, output) = try AutomationControl.parseCLI(arguments) {
            var request = Request(version: 1, command: .automation)
            request.automationData = try JSONSerialization.data(withJSONObject: object)
            try request.validate()
            return (request, output)
        }
        if arguments.first == "rules" { return try parseRules(arguments.dropFirst()) }
        guard let name = arguments.first, let command = Request.Command(rawValue: name) else {
            throw LocalControlError.usage("未知命令。运行 ProxyMirror --help 查看用法。")
        }
        guard command == .status || command == .traffic || command == .exportHAR else {
            throw LocalControlError.usage("请通过 rules 子命令管理规则。")
        }
        if command == .status, arguments.count != 1 {
            throw LocalControlError.usage("status 无需参数。")
        }
        var request = Request(version: 1, command: command)
        var output: String?
        var seen = Set<String>()
        var remaining = arguments.dropFirst().makeIterator()
        while let flag = remaining.next() {
            guard seen.insert(flag).inserted else { throw LocalControlError.usage("参数 \(flag) 只能出现一次。") }
            if flag == "--selected" {
                request.selected = true
                continue
            }
            guard ["--url", "--method", "--status", "--id", "--after-id", "--limit", "--output"].contains(flag) else {
                throw LocalControlError.usage("未知参数 \(flag)。")
            }
            guard let value = remaining.next(), !value.isEmpty, !value.hasPrefix("--") else {
                throw LocalControlError.usage("参数 \(flag) 缺少值。")
            }
            switch flag {
            case "--url": request.url = value
            case "--method": request.method = value
            case "--status":
                guard let status = Int(value) else { throw LocalControlError.usage("--status 需要整数。") }
                request.status = status
            case "--after-id":
                guard let id = UUID(uuidString: value) else { throw LocalControlError.usage("--after-id 需要有效的 UUID。") }
                request.afterID = id
            case "--id":
                guard let id = UUID(uuidString: value) else { throw LocalControlError.usage("--id 需要有效的 UUID。") }
                request.id = id
            case "--limit":
                guard let limit = Int(value) else { throw LocalControlError.usage("--limit 需要整数。") }
                request.limit = limit
            case "--output": output = value
            default: break
            }
        }
        if command == .exportHAR, output == nil { throw LocalControlError.usage("export-har 需要 --output。") }
        if command != .exportHAR, output != nil { throw LocalControlError.usage("--output 只适用于 export-har。") }
        try request.validate()
        return (request, output)
    }

    private static func parseRules(_ arguments: ArraySlice<String>) throws -> (Request, String?) {
        let command: Request.Command
        let options: Set<String>
        switch arguments.first {
        case "export": command = .ruleExport; options = ["--output", "--tool"]
        case "preview": command = .rulePreview; options = ["--input", "--mode"]
        case "apply": command = .ruleApply; options = ["--input", "--mode", "--preview-token"]
        default: throw LocalControlError.usage("rules 需要 export、preview 或 apply 子命令。")
        }
        var values = [String: String]()
        var remaining = arguments.dropFirst().makeIterator()
        while let option = remaining.next() {
            guard options.contains(option) else { throw LocalControlError.usage("未知参数 \(option)。") }
            guard values[option] == nil else { throw LocalControlError.usage("参数 \(option) 只能出现一次。") }
            guard let value = remaining.next(), !value.isEmpty, !value.hasPrefix("--") else {
                throw LocalControlError.usage("参数 \(option) 缺少值。")
            }
            values[option] = value
        }
        var request = Request(version: 1, command: command)
        if command == .ruleExport {
            guard let output = values["--output"] else { throw LocalControlError.usage("rules export 需要 --output。") }
            if let value = values["--tool"] {
                guard let tool = RuleBackup.Section(rawValue: value) else { throw LocalControlError.usage("未知规则工具 \(value)。") }
                request.ruleTool = tool
            }
            return (request, output)
        }
        guard let input = values["--input"], input != "-" else {
            throw LocalControlError.usage("请用 --input 指定本地规则备份文件。")
        }
        guard let mode = RuleBackup.ImportMode(rawValue: values["--mode"] ?? "merge") else {
            throw LocalControlError.usage("--mode 必须为 merge 或 replace。")
        }
        request.ruleMode = mode
        request.previewToken = values["--preview-token"]
        do { request.ruleData = try RuleBackup.contents(of: URL(fileURLWithPath: input)) }
        catch { throw LocalControlError.usage("无法读取规则文件（\(error.localizedDescription)）。") }
        try request.validate()
        return (request, nil)
    }

    private static func writeError(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data(("ProxyMirror: " + message + "\n").utf8))
    }

    private static func writePrivateFile(_ data: Data, to target: URL) throws {
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".pm-export-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { _ = unlink(temporary.path) }
        try handle.write(contentsOf: data)
        try handle.close()
        guard rename(temporary.path, target.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
