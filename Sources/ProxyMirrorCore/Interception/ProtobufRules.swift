import Foundation
import Combine

enum ProtobufPayloadEncoding: String, Codable, CaseIterable, Sendable {
    case single = "Single", delimited = "Delimited"
}

enum ProtobufPayloadType: String, Codable, CaseIterable, Sendable {
    case binary = "Protobuf", base64 = "Base64 Protobuf"
}

struct ProtobufSchemaRecord: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var filename: String
    var enabled = true
    var descriptorData: Data?
}

struct ProtobufMappingRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Protobuf 映射"
    var enabled = true
    /// Matches a complete URL when supplied, otherwise the RPC/request path.
    var pattern = "*"
    var schemaID: UUID?
    var requestMessage = ""
    var responseMessage = ""
    var requestEncoding = ProtobufPayloadEncoding.single
    var responseEncoding = ProtobufPayloadEncoding.single
    var payloadType = ProtobufPayloadType.binary
}

struct ProtobufConfiguration: Codable, Equatable {
    var enabled = true
    var schemas: [ProtobufSchemaRecord] = []
    var rules: [ProtobufMappingRule] = []

    var validationError: String? {
        guard schemas.count <= 128, rules.count <= 1000,
              Set(schemas.map(\.id)).count == schemas.count,
              Set(rules.map(\.id)).count == rules.count else { return "Schema 或规则数量过多，或 ID 重复。" }
        guard schemas.reduce(0, { $0 + ($1.descriptorData?.count ?? 0) }) <= 8 * 1024 * 1024 else {
            return "Protobuf Schema 合计超过 8 MiB。"
        }
        var parsed: [UUID: GRPCSchema] = [:]
        for record in schemas {
            guard !record.name.isEmpty, record.name.utf8.count <= 1024,
                  record.filename == record.id.uuidString + ".desc", let data = record.descriptorData else {
                return "Schema 缺少有效名称、描述符字节或内部文件名。"
            }
            do { parsed[record.id] = try GRPCSchema.parse(data) } catch { return error.localizedDescription }
        }
        for rule in rules {
            guard !rule.name.isEmpty, rule.name.utf8.count <= 512, rule.pattern.utf8.count <= 8192 else {
                return "请填写有效的 Protobuf 规则名称和 URL 模式。"
            }
            if let id = rule.schemaID {
                guard let schema = parsed[id] else { return "Protobuf 规则引用的 Schema 不存在。" }
                for type in [rule.requestMessage, rule.responseMessage] where !type.isEmpty {
                    guard schema.contains(type) else { return "Schema 中没有消息类型 \(type)。" }
                }
            }
        }
        return nil
    }

    func resolving(with current: ProtobufConfiguration, merge: Bool) -> ProtobufConfiguration {
        guard merge else { return self }
        var result = current
        result.enabled = enabled
        for record in schemas {
            if let index = result.schemas.firstIndex(where: { $0.id == record.id }) { result.schemas[index] = record }
            else { result.schemas.append(record) }
        }
        for rule in rules {
            if let index = result.rules.firstIndex(where: { $0.id == rule.id }) { result.rules[index] = rule }
            else { result.rules.append(rule) }
        }
        return result
    }
}

extension Notification.Name {
    static let protobufConfigurationChanged = Notification.Name("ProxyMirror.protobufConfigurationChanged")
}

/// Canonical persistence is rules.json; descriptors are embedded so backups remain portable.
final class ProtobufRuntimeStore: @unchecked Sendable {
    static let shared = ProtobufRuntimeStore()
    private let current: LockedBox<ProtobufConfiguration>

    private init() {
        let consolidated: RuleBackup? = RulesFileIO.load("rules.json")
        var loaded = consolidated?.protobuf ?? RulesFileIO.load("protobuf.json") ?? ProtobufConfiguration()
        for index in loaded.schemas.indices where loaded.schemas[index].descriptorData == nil {
            let record = loaded.schemas[index]
            guard record.filename == record.id.uuidString + ".desc" else { continue }
            let url = RulesFileIO.dir.appendingPathComponent("ProtobufSchemas", isDirectory: true).appendingPathComponent(record.filename)
            if let handle = try? FileHandle(forReadingFrom: url) {
                loaded.schemas[index].descriptorData = try? handle.read(upToCount: GRPCSchema.maxDescriptorBytes + 1)
                try? handle.close()
            }
        }
        current = LockedBox(loaded.validationError == nil ? loaded : ProtobufConfiguration())
    }

    func snapshot() -> ProtobufConfiguration { current.value }

    func updateSnapshot(_ replacement: ProtobufConfiguration) {
        guard current.value != replacement else { return }
        current.set(replacement)
        NotificationCenter.default.post(name: .protobufConfigurationChanged, object: nil)
    }
}

struct ProtobufResolution: Sendable {
    let schema: GRPCSchema
    let type: String?
    let encoding: ProtobufPayloadEncoding
    let payloadType: ProtobufPayloadType
    let ruleName: String
}

enum ProtobufPayload {
    static let messageLimit = 256

    static func messages(_ input: Data, encoding: ProtobufPayloadEncoding,
                         payloadType: ProtobufPayloadType = .binary) throws -> [Data] {
        guard input.count <= GRPCFrames.maxPayload * 2 else { throw GRPCInspectionError("Protobuf 转换输入超过 2 MiB。") }
        let data: Data
        switch payloadType {
        case .binary: data = Data(input)
        case .base64:
            let bytes = input.filter { ![9, 10, 13, 32].contains($0) }
            guard let decoded = Data(base64Encoded: bytes) else { throw GRPCInspectionError("Protobuf Base64 无效。") }
            data = decoded
        }
        if encoding == .single {
            guard data.count <= GRPCFrames.maxPayload else { throw GRPCInspectionError("Protobuf 消息超过 1 MiB。") }
            return [data]
        }
        var output: [Data] = []
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            guard output.count < messageLimit else { throw GRPCInspectionError("Delimited 消息超过 256 条。") }
            var length: UInt64 = 0
            var shift = 0
            var terminated = false
            for _ in 0..<10 {
                guard offset < data.count else { throw GRPCInspectionError("Delimited 长度前缀不完整。") }
                let byte = data[data.startIndex + offset]
                offset += 1
                if shift == 63 && byte > 1 { throw GRPCInspectionError("Delimited 长度前缀溢出。") }
                length |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { terminated = true; break }
                shift += 7
            }
            guard terminated else { throw GRPCInspectionError("Delimited 长度前缀溢出。") }
            guard length <= UInt64(GRPCFrames.maxPayload), length <= UInt64(data.count - offset) else {
                throw GRPCInspectionError("Delimited 消息不完整或超过 1 MiB。")
            }
            let end = offset + Int(length)
            output.append(data.subdata(in: offset..<end))
            offset = end
        }
        return output
    }

    static func describe(_ data: Data, resolution: ProtobufResolution) throws -> String {
        let payloads = try messages(data, encoding: resolution.encoding, payloadType: resolution.payloadType)
        return try describeMessages(payloads, type: resolution.type, schema: resolution.schema,
                                    showNumbers: resolution.encoding == .delimited)
    }

    static func describeMessages(_ payloads: [Data], type: String?, schema: GRPCSchema?, showNumbers: Bool = true) throws -> String {
        let limit = 1024 * 1024
        var output = ""
        var bytes = 0
        for (index, payload) in payloads.enumerated() {
            try Task.checkCancellation()
            let text = (showNumbers ? "Message #\(index + 1)\n" : "")
                + (try GRPCProtobuf.describe(payload, type: type, schema: schema))
            if bytes + text.utf8.count > limit {
                output += "\n…（转换输出超过 1 MiB，后续消息已省略）"
                break
            }
            if index > 0 { output += "\n\n" }
            output += text
            bytes += text.utf8.count + 2
        }
        return output
    }
}

@MainActor
final class ProtobufRuleStore: ObservableObject {
    static let shared = ProtobufRuleStore()

    struct ConsoleEntry: Identifiable {
        var id = UUID()
        let date = Date()
        let isError: Bool
        let message: String
    }

    @Published private(set) var configuration: ProtobufConfiguration
    @Published private(set) var revision = UUID()
    @Published private(set) var loading = false
    @Published private(set) var console: [ConsoleEntry] = []
    @Published var error: String?
    private var schemas: [UUID: GRPCSchema] = [:]
    private var configurationObserver: NSObjectProtocol?

    private init() {
        configuration = ProtobufRuntimeStore.shared.snapshot()
        reload()
        configurationObserver = NotificationCenter.default.addObserver(forName: .protobufConfigurationChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private func reload() {
        configuration = ProtobufRuntimeStore.shared.snapshot()
        schemas.removeAll()
        for record in configuration.schemas {
            guard let data = record.descriptorData else { continue }
            do { schemas[record.id] = try GRPCSchema.parse(data) }
            catch { log("\(record.name)：\(error.localizedDescription)", isError: true) }
        }
        revision = UUID()
    }

    func schema(id: UUID?) -> GRPCSchema? { id.flatMap { schemas[$0] } }

    func schemaNames(id: UUID?) -> [String] { schema(id: id)?.messageTypes ?? [] }

    func schema(containing type: String?) -> GRPCSchema? {
        guard let type else { return nil }
        for record in configuration.schemas where record.enabled {
            if let schema = schemas[record.id], schema.contains(type) { return schema }
        }
        return nil
    }

    func resolution(for target: String, isRequest: Bool) -> ProtobufResolution? {
        guard configuration.enabled, RuleOrganizationStore.shared.isEnabled("protobuf") else { return nil }
        for rule in configuration.rules where rule.enabled && RuleOrganizationStore.shared.ruleIsEnabled(tool: "protobuf", id: rule.id) {
            let path = URLComponents(string: target)?.path ?? target
            guard URLRule.wildcardMatch(rule.pattern, value: target) || URLRule.wildcardMatch(rule.pattern, value: path),
                  let record = configuration.schemas.first(where: { $0.id == rule.schemaID && $0.enabled }),
                  let schema = schemas[record.id] else { continue }
            let type = GRPCSchema.normalized(isRequest ? rule.requestMessage : rule.responseMessage)
            return ProtobufResolution(schema: schema, type: type.isEmpty ? nil : type,
                                      encoding: isRequest ? rule.requestEncoding : rule.responseEncoding,
                                      payloadType: rule.payloadType, ruleName: rule.name)
        }
        // Imported RPC descriptors also work without an explicit mapping rule.
        for record in configuration.schemas where record.enabled {
            if let schema = schemas[record.id], let type = schema.messageType(for: URLComponents(string: target)?.path ?? target, isRequest: isRequest) {
                return ProtobufResolution(schema: schema, type: type, encoding: .single,
                                          payloadType: .binary, ruleName: record.name)
            }
        }
        return nil
    }

    func importSchema(_ url: URL) {
        guard !loading else { return }
        loading = true
        error = nil
        Task {
            defer { loading = false }
            do {
                let imported = try await Task.detached(priority: .userInitiated) { () -> (GRPCSchema, Data) in
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    let data = try file.read(upToCount: GRPCSchema.maxDescriptorBytes + 1) ?? Data()
                    return (try GRPCSchema.parse(data), data)
                }.value
                let id = UUID()
                let record = ProtobufSchemaRecord(id: id, name: url.lastPathComponent, filename: id.uuidString + ".desc", descriptorData: imported.1)
                var next = configuration
                next.schemas.append(record)
                try save(next)
                schemas[id] = imported.0
                revision = UUID()
                log("已导入 \(record.name)，\(imported.0.messageTypes.count) 个消息类型。")
            } catch { fail(error) }
        }
    }

    func addRule(for target: String) {
        var next = configuration
        var rule = ProtobufMappingRule()
        rule.name = URLComponents(string: target)?.host.map { "Protobuf · " + $0 } ?? "Protobuf 映射"
        rule.pattern = target
        rule.schemaID = next.schemas.first?.id
        next.rules.append(rule)
        do { try save(next) } catch { fail(error) }
    }

    func removeSchema(_ id: UUID) throws {
        var next = configuration
        next.schemas.removeAll { $0.id == id }
        next.rules.removeAll { $0.schemaID == id }
        try save(next)
        schemas.removeValue(forKey: id)
    }

    func save(_ replacement: ProtobufConfiguration) throws {
        if let issue = replacement.validationError { throw GRPCInspectionError(issue) }
        let store = RulesStore.shared
        var backup = store.backup()
        backup.protobuf = replacement
        try store.install(backup)
        reload()
    }

    func log(_ message: String, isError: Bool = false) {
        console.append(ConsoleEntry(isError: isError, message: String(message.prefix(4096))))
        if console.count > 200 { console.removeFirst(console.count - 200) }
    }

    func clearConsole() { console.removeAll() }
    func fail(_ failure: Error) { error = failure.localizedDescription; log(failure.localizedDescription, isError: true) }
}
