import Darwin
import Foundation

enum ScriptingPhase: String, Codable, Hashable, CaseIterable, Sendable {
    case request, response, webSocket

    var label: String {
        switch self {
        case .request: return "请求"
        case .response: return "响应"
        case .webSocket: return "WebSocket"
        }
    }
}

struct ScriptingTarget: Sendable {
    let method: String
    let scheme: String
    let host: String
    let path: String
    let query: String
    let url: String
}

struct ScriptingPlan: Sendable {
    let target: ScriptingTarget
    let phase: ScriptingPhase
    fileprivate let entries: [ScriptingEntry]
}

struct ScriptingResult: Sendable {
    let head: BreakpointHead
    let body: Data?
    let graphqlOperationName: String?
    let logs: [String]
}

private struct ScriptingEntry: Sendable {
    let label: String
    let operation: String
    let action: ScriptingAction
}

private enum ScriptingAction: Sendable {
    case script(String)
    case header(RewriteAction.HeaderOp, name: String, value: String)
    case status(Int)

    var scriptSource: String? {
        if case .script(let source) = self { return source }
        return nil
    }

    func run(_ message: WireMessage) throws -> (message: WireMessage, logs: [String]) {
        var result = message
        switch self {
        case .script(let source):
            return try ScriptWorker.run(source: source, message: message)
        case .header(let operation, let name, let value):
            let lower = name.lowercased()
            if operation == .replaceExisting {
                result.headers = result.headers.map { field in
                    field.name.lowercased() == lower ? .init(name: field.name, value: value) : field
                }
            } else {
                if operation != .add { result.headers.removeAll { $0.name.lowercased() == lower } }
                if operation != .remove { result.headers.append(.init(name: name, value: value)) }
            }
        case .status(let status):
            result.status = status
        }
        return (result, [])
    }
}

@MainActor
final class ScriptingActivity: ObservableObject {
    static let shared = ScriptingActivity()

    struct Entry: Identifiable {
        let id = UUID()
        let date = Date()
        let url: String
        let text: String
    }

    @Published private(set) var entries: [Entry] = []
    @Published var pendingTarget: ScriptingTarget?
    @Published var pendingOperation: String?

    func record(url: String, lines: [String]) {
        entries.append(contentsOf: lines.map { Entry(url: url, text: $0) })
        if entries.count > 250 { entries.removeFirst(entries.count - 250) }
    }

    func clear() { entries.removeAll() }

    func prefill(_ tx: Transaction) {
        let original = tx.originalURL ?? tx.fullURL
        if let route = URLParser.parse(target: original) {
            let (path, query) = splitQueryPath(route.path)
            pendingTarget = ScriptingTarget(method: tx.method, scheme: route.scheme ?? tx.scheme,
                host: route.host ?? tx.host, path: path, query: query, url: original)
        } else {
            pendingTarget = ScriptingTarget(method: tx.method, scheme: tx.scheme, host: tx.host,
                path: tx.path, query: tx.query, url: original)
        }
        pendingOperation = tx.graphqlOperationName
    }
}

enum ScriptingService {
    static let sourceLimit = 16 * 1024
    static let bodyLimit = BreakpointMessage.bodyLimit
    private static let maxRules = 6
    private static let capacity = DispatchSemaphore(value: 4)
    private static let queue = DispatchQueue(label: "ProxyMirror.scripting", qos: .userInitiated, attributes: .concurrent)

    /// Preflight matching omits the operation name until bounded request bytes are available.
    static func plan(for target: ScriptingTarget, phase: ScriptingPhase) -> ScriptingPlan? {
        let rules = InterceptionConfig.shared.rewrite.value
        guard !rules.isEmpty else { return nil }
        let entries = entries(for: target, phase: phase, groups: rules)
        if !entries.isEmpty { return ScriptingPlan(target: target, phase: phase, entries: entries) }
        if phase == .request, self.entries(for: target, phase: .response, groups: rules).contains(where: { !$0.operation.isEmpty }) {
            return ScriptingPlan(target: target, phase: phase, entries: [])
        }
        return nil
    }

    private static func entries(for target: ScriptingTarget, phase: ScriptingPhase,
                                groups: [RewriteRuleSet]) -> [ScriptingEntry] {
        groups.filter(\.enabled).flatMap { group in
            group.rules.filter(\.enabled).flatMap { rule -> [ScriptingEntry] in
                var predicate = rule.rule
                let operation = predicate.graphqlQueryName
                predicate.graphqlQueryName = ""
                guard predicate.enabled, predicate.matches(method: target.method, scheme: target.scheme,
                    host: target.host, path: target.path, query: target.query, fullURL: target.url) else { return [] }
                let label = [group.name, rule.rule.name.isEmpty ? rule.rule.summary : rule.rule.name]
                    .joined(separator: " / ")
                return rule.actions.compactMap {
                    guard let action = scriptingAction(for: $0, phase: phase) else { return nil }
                    return ScriptingEntry(label: label, operation: operation, action: action)
                }
            }
        }
    }

    static func run(_ plan: ScriptingPlan, head: BreakpointHead, body: Data?,
                    graphqlName: String? = nil, completion: @escaping @Sendable (ScriptingResult) -> Void) {
        let operation: String?
        if case .request(let request) = head {
            operation = GraphQLService.detectRequest(path: plan.target.path, query: plan.target.query,
                headers: request.headers, body: body ?? Data()).flatMap { $0.operationName.isEmpty ? nil : $0.operationName }
        } else {
            operation = graphqlName ?? GraphQLService.detectRequest(path: plan.target.path, query: plan.target.query,
                headers: HTTPHeaders(), body: Data()).flatMap { $0.operationName.isEmpty ? nil : $0.operationName }
        }
        let candidates = plan.entries.filter { $0.operation.isEmpty || $0.operation == operation }
        let captured = BreakpointMessage(head: head, body: body)
        schedule(plan: plan, candidates: candidates, busy: { logs in
            completion(ScriptingResult(head: head, body: body, graphqlOperationName: operation, logs: logs))
        }) {
            var result = captured
            var logs: [String] = []
            for entry in candidates.prefix(maxRules) {
                let before = WireMessage(packet: result, plan: plan, operation: operation)
                do {
                    let output = try entry.action.run(before)
                    result = try output.message.applying(to: result)
                    logs.append("\(plan.phase.label) · \(entry.label) · 已执行")
                    logs += output.logs.map { "  \($0)" }
                } catch {
                    logs.append("\(plan.phase.label) · \(entry.label) · \(error.localizedDescription)")
                }
            }
            if candidates.count > maxRules { logs.append("此阶段按顺序执行前 \(maxRules) 条脚本") }
            report(plan: plan, logs: logs)
            completion(ScriptingResult(head: result.head, body: result.body, graphqlOperationName: operation, logs: logs))
        }
    }

    /// G6 测试/外部入口：按目标改写单帧
    static func rewriteFrame(target: ScriptingTarget, graphqlName: String?, frame: WSFrame,
                             completion: @escaping @Sendable (WSFrameAction) -> Void) {
        guard let plan = plan(for: target, phase: .webSocket) else { completion(.pass); return }
        rewriteFrame(plan: plan, frame: frame, graphqlName: graphqlName, completion: completion)
    }

    /// G6：WebSocket 帧改写。脚本返回值语义：
    /// `false` → 丢帧；字符串 → 以其替换文本帧负载；`{body: "..."}` 同字符串；
    /// `{base64: "..."}` → 替换二进制负载；其余（含 undefined）→ 原样放行。
    static func rewriteFrame(plan: ScriptingPlan, frame: WSFrame, graphqlName: String?,
                             completion: @escaping @Sendable (WSFrameAction) -> Void) {
        let candidates = plan.entries.filter { $0.operation.isEmpty || $0.operation == graphqlName }
        guard !candidates.isEmpty else { completion(.pass); return }
        schedule(plan: plan, candidates: candidates, busy: { _ in completion(.pass) }) {
            completion(Self.runFrameEntries(candidates, frame: frame, target: plan.target, graphql: graphqlName))
        }
    }

    private static func runFrameEntries(_ candidates: [ScriptingEntry], frame: WSFrame,
                                        target: ScriptingTarget, graphql: String?) -> WSFrameAction {
        let text = frame.kind == .text && frame.payload.count <= bodyLimit ? BreakpointMessage.editableText(frame.payload) : nil
        let message = WireMessage(phase: .webSocket, method: target.method, url: target.url, headers: [],
            body: text.map { String(decoding: $0, as: UTF8.self) }, graphqlOperationName: graphql,
            direction: frame.direction.rawValue, opcode: Int(frame.opcode), payloadBytes: frame.payload.count, fin: frame.fin,
            payloadBase64: (text == nil && frame.payload.count <= bodyLimit) ? frame.payload.base64EncodedString() : nil)
        var action: WSFrameAction? = nil
        var logs: [String] = []
        for entry in candidates.prefix(maxRules) {
            guard let source = entry.action.scriptSource else { continue }
            do {
                let (value, entryLogs) = try ScriptWorker.runFrame(source: source, message: message)
                logs.append("WebSocket · \(entry.label) · 已执行")
                logs += entryLogs.map { "  \($0)" }
                if let verdict = interpretFrameValue(value), verdict != .pass {
                    switch verdict {
                    case .close:
                        action = .close
                        logs.append("WebSocket · \(entry.label) · 关闭连接")
                    case .drop:
                        action = .drop
                        logs.append("WebSocket · \(entry.label) · 丢弃帧")
                    case .modify(let newPayload, let kind):
                        guard newPayload != frame.payload else { continue }
                        action = .modify(payload: newPayload, note: kind)
                        logs.append("WebSocket · \(entry.label) · 改写帧负载（\(kind)）")
                    case .pass:
                        continue
                    }
                    break
                } else {
                    continue
                }
            } catch {
                logs.append("WebSocket · \(entry.label) · \(error.localizedDescription)")
            }
        }
        report(plan: ScriptingPlan(target: target, phase: .webSocket, entries: []), logs: logs)
        return action ?? .pass
    }

    /// 返回 nil = 未给出动作（放行）
    private static func interpretFrameValue(_ value: FrameValue?) -> WSFrameAction? {
        guard let value else { return nil }
        switch value {
        case .bool(false): return .drop
        case .string(let text): return .modify(payload: Data(text.utf8), note: "文本")
        case .object(let dict):
            if case .string(let action)? = dict["action"] {
                switch action {
                case "pass": return .pass
                case "drop": return .drop
                case "close": return .close
                case "modify": break
                default: return nil
                }
            }
            if case .bool(false)? = dict["drop"] { return .drop }
            if case .string(let base64)? = dict["base64"], let data = Data(base64Encoded: base64) {
                return .modify(payload: data, note: "二进制")
            }
            if case .string(let body)? = dict["body"] {
                return .modify(payload: Data(body.utf8), note: "文本")
            }
            return nil
        case .null, .bool(true), .number, .array:
            return nil
        }
    }

    private static func schedule(plan: ScriptingPlan, candidates: [ScriptingEntry],
                                 busy: @escaping @Sendable ([String]) -> Void,
                                 work: @escaping @Sendable () -> Void) {
        guard !candidates.isEmpty else { busy([]); return }
        guard capacity.wait(timeout: .now()) == .success else {
            let logs = ["\(plan.phase.label) · 脚本执行繁忙，原报文继续处理"]
            report(plan: plan, logs: logs)
            busy(logs)
            return
        }
        queue.async {
            defer { capacity.signal() }
            work()
        }
    }

    private static func report(plan: ScriptingPlan, logs: [String]) {
        guard !logs.isEmpty else { return }
        DispatchQueue.main.async { ScriptingActivity.shared.record(url: plan.target.url, lines: logs) }
    }

    private static func scriptingAction(for action: RewriteAction, phase: ScriptingPhase) -> ScriptingAction? {
        switch action {
        case .script(let actionPhase, let source):
            return actionPhase == phase && !source.isEmpty ? .script(source) : nil
        case .requestHeader(let op, let name, let value) where phase == .request:
            return .header(op, name: name, value: value)
        case .responseHeader(let op, let name, let value) where phase == .response:
            return .header(op, name: name, value: value)
        case .replaceRequestBody(let find, let replace, let regex) where phase == .request,
             .replaceResponseBody(let find, let replace, let regex) where phase == .response:
            guard !find.isEmpty else { return nil }
            let pattern = regex ? "new RegExp(\(literal(find)), 'g')" : literal(find)
            return .script("if (typeof message.body === 'string') message.body = message.body.replaceAll(\(pattern), \(literal(replace)));")
        case .setStatus(let status) where phase == .response:
            return .status(status)
        default:
            return nil
        }
    }

    private static func literal(_ value: String) -> String {
        guard let encoded = try? JSONEncoder().encode([value]) else { return "\"\"" }
        return String(String(decoding: encoded, as: UTF8.self).dropFirst().dropLast())
    }
}

private struct WireMessage: Codable {
    struct Header: Codable {
        let name: String
        let value: String
    }

    let phase: ScriptingPhase
    let method: String
    let url: String
    var headers: [Header]
    var status: Int? = nil
    var body: String? = nil
    var graphqlOperationName: String? = nil
    var direction: String? = nil
    var opcode: Int? = nil
    var payloadBytes: Int? = nil
    var fin: Bool? = nil
    var payloadBase64: String? = nil

    init(phase: ScriptingPhase, method: String, url: String, headers: [Header], status: Int? = nil,
         body: String? = nil, graphqlOperationName: String? = nil, direction: String? = nil,
         opcode: Int? = nil, payloadBytes: Int? = nil, fin: Bool? = nil, payloadBase64: String? = nil) {
        self.phase = phase
        self.method = method
        self.url = url
        self.headers = headers
        self.status = status
        self.body = body
        self.graphqlOperationName = graphqlOperationName
        self.direction = direction
        self.opcode = opcode
        self.payloadBytes = payloadBytes
        self.fin = fin
        self.payloadBase64 = payloadBase64
    }

    init(packet: BreakpointMessage, plan: ScriptingPlan, operation: String?) {
        self.init(phase: plan.phase, method: plan.target.method, url: plan.target.url,
                  headers: packet.head.headers.pairs.map { Header(name: $0.name, value: $0.value) },
                  body: packet.body.flatMap { String(data: $0, encoding: .utf8) }, graphqlOperationName: operation)
        if case .response(let response) = packet.head { status = response.status }
    }

    func applying(to original: BreakpointMessage) throws -> BreakpointMessage {
        var firstLine = original.head.firstLine
        if let status, case .response(let head) = original.head, status != head.status {
            firstLine = "\(head.version) \(status) \(TrafficStore.reason(for: status))"
        }
        guard headers.count <= 512,
              headers.allSatisfy({ !$0.name.contains(":") && !$0.name.contains(where: \.isNewline)
                  && !$0.value.contains(where: \.isNewline) }) else {
            throw BreakpointMessage.InvalidEdit("脚本输出的头部无效")
        }
        guard original.body != nil || body == nil else {
            throw BreakpointMessage.InvalidEdit("此报文仅支持改写头部")
        }
        let lines = [firstLine] + headers.map { "\($0.name): \($0.value)" }
        let updatedBody = original.body.map { bytes in body ?? String(decoding: bytes, as: UTF8.self) }
        let raw = lines.joined(separator: "\n") + (updatedBody.map { "\n\n" + $0 } ?? "")
        return try original.applying(raw)
    }
}

private enum ScriptWorker {
    private struct Input: Encodable { let source: String; let message: WireMessage }
    private struct Response: Decodable { let message: WireMessage?; let logs: [String]?; let error: String? }
    private struct Failure: LocalizedError { let errorDescription: String? }

    static func run(source: String, message: WireMessage) throws -> (message: WireMessage, logs: [String]) {
        guard source.utf8.count <= ScriptingService.sourceLimit else { throw Failure(errorDescription: "脚本超过 16 KiB") }
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("ProxyMirrorScriptWorker"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw Failure(errorDescription: "找不到脚本执行组件")
        }
        let data = try JSONEncoder().encode(Input(source: source, message: message))
        guard data.count <= 2 * 1024 * 1024 else { throw Failure(errorDescription: "脚本输入超过 2 MiB") }

        let input = try scratchFile()
        defer { try? input.close() }
        let output = try scratchFile()
        defer { try? output.close() }
        try input.write(contentsOf: data)
        try input.seek(toOffset: 0)

        let process = Process()
        process.executableURL = executable
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        guard done.wait(timeout: .now() + .milliseconds(400)) == .success else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = done.wait(timeout: .now() + .milliseconds(150))
            throw Failure(errorDescription: "脚本超过 400 ms")
        }
        try output.seek(toOffset: 0)
        guard process.terminationStatus == 0,
              let bytes = try output.read(upToCount: 1024 * 1024 + 1),
              bytes.count <= 1024 * 1024,
              let response = try? JSONDecoder().decode(Response.self, from: bytes) else {
            throw Failure(errorDescription: "脚本执行组件返回了无效结果")
        }
        if let error = response.error { throw Failure(errorDescription: error) }
        guard let packet = response.message else {
            throw Failure(errorDescription: "脚本需要返回完整报文或直接修改 message")
        }
        return (packet, (response.logs ?? []).prefix(12).map { String($0.prefix(1000)) })
    }

    /// Give the worker an inherited file descriptor without a named on-disk input.
    private static func scratchFile() throws -> FileHandle {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-script-\(UUID().uuidString)").path
        let descriptor = open(path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw Failure(errorDescription: "无法创建脚本输入输出缓冲") }
        guard unlink(path) == 0 else {
            close(descriptor)
            throw Failure(errorDescription: "无法隔离脚本输入输出缓冲")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}


/// 脚本帧动作返回值的宽松 JSON 解码
enum FrameValue: Decodable, Sendable {
    case null
    case bool(Bool)
    case string(String)
    case number(String)
    case object([String: FrameValue])
    case array([FrameValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode(Double.self) { self = .number(String(value)); return }
        if let value = try? container.decode([String: FrameValue].self) { self = .object(value); return }
        if let value = try? container.decode([FrameValue].self) { self = .array(value); return }
        self = .null
    }
}

extension ScriptWorker {
    fileprivate struct FrameInput: Encodable { let source: String; let message: WireMessage }
    fileprivate struct FrameResponse: Decodable { let message: FrameValue?; let logs: [String]?; let error: String? }
    fileprivate struct FrameFailure: LocalizedError { let errorDescription: String? }

    /// 帧级脚本执行：允许任意返回值（原报文对象、字符串、false、{base64} 等）
    fileprivate static func runFrame(source: String, message: WireMessage) throws -> (FrameValue?, [String]) {
        guard source.utf8.count <= ScriptingService.sourceLimit else {
            throw FrameFailure(errorDescription: "脚本超过 16 KiB")
        }
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("ProxyMirrorScriptWorker"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw FrameFailure(errorDescription: "找不到脚本执行组件")
        }
        let data = try JSONEncoder().encode(FrameInput(source: source, message: message))
        guard data.count <= 2 * 1024 * 1024 else { throw FrameFailure(errorDescription: "脚本输入超过 2 MiB") }

        let input = try scratchFile()
        defer { try? input.close() }
        let output = try scratchFile()
        defer { try? output.close() }
        try input.write(contentsOf: data)
        try input.seek(toOffset: 0)

        let process = Process()
        process.executableURL = executable
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        guard done.wait(timeout: .now() + .milliseconds(400)) == .success else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = done.wait(timeout: .now() + .milliseconds(150))
            throw FrameFailure(errorDescription: "脚本超过 400 ms")
        }
        try output.seek(toOffset: 0)
        guard process.terminationStatus == 0,
              let bytes = try output.read(upToCount: 1024 * 1024 + 1),
              bytes.count <= 1024 * 1024,
              let response = try? JSONDecoder().decode(FrameResponse.self, from: bytes) else {
            throw FrameFailure(errorDescription: "脚本执行组件返回了无效结果")
        }
        if let error = response.error { throw FrameFailure(errorDescription: error) }
        return (response.message, (response.logs ?? []).prefix(12).map { String($0.prefix(1000)) })
    }
}
