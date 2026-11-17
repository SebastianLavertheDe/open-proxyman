import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class GRPCDescriptors: ObservableObject {
    static let shared = GRPCDescriptors()

    @Published private(set) var schema: GRPCSchema?
    @Published private(set) var filename: String?
    @Published private(set) var revision = UUID()
    @Published private(set) var loading = false
    @Published var error: String?

    func load(_ url: URL) {
        guard !loading else { return }
        loading = true
        error = nil
        Task {
            defer { loading = false }
            do {
                schema = try await Task.detached(priority: .userInitiated) {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    return try GRPCSchema.load(url)
                }.value
                filename = url.lastPathComponent
                revision = UUID()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func clear() {
        schema = nil
        filename = nil
        error = nil
        revision = UUID()
    }
}

@MainActor
struct GRPCInspectorView: View {
    let data: Data
    let bodyRevision: UInt64
    let bodyGeneration: UInt64
    let headers: HTTPHeaders
    let trailers: HTTPHeaders
    let complete: Bool
    let truncated: Bool
    let path: String
    let isRequest: Bool
    let mediaType: GRPCFrames.MediaType

    @ObservedObject private var descriptors = GRPCDescriptors.shared
    @State private var importing = false
    @State private var selectedID: Int?
    @State private var typeOverride = ""
    @State private var raw = false
    @State private var output: (key: DecodeKey, value: Output)?
    @State private var scanner = BodyScanner()
    @State private var snapshot: ScanSnapshot?

    private struct ScanKey: Equatable, Sendable {
        let revision: UInt64
        let generation: UInt64
        let complete: Bool
        let truncated: Bool
        let transport: GRPCFrames.Transport
        let encoding: String?

        func sameStream(as other: Self) -> Bool {
            generation == other.generation && transport == other.transport && encoding == other.encoding
        }
    }

    private struct ScanSnapshot: Sendable {
        let key: ScanKey
        let scan: GRPCFrames.Scan
    }

    private actor BodyScanner {
        private var lastKey: ScanKey?
        private var scanner = GRPCFrames.Scanner()

        func scan(_ data: Data, key: ScanKey) throws -> ScanSnapshot {
            try Task.checkCancellation()
            if let lastKey {
                if !key.sameStream(as: lastKey) || key.revision < lastKey.revision {
                    scanner = GRPCFrames.Scanner()
                }
            }
            lastKey = key
            let scan = scanner.scan(data, complete: key.complete, truncated: key.truncated,
                                    transport: key.transport, encoding: key.encoding)
            try Task.checkCancellation()
            return ScanSnapshot(key: key, scan: scan)
        }

        func copyPayload(_ message: GRPCFrames.Message, from data: Data,
                         key: ScanKey, limit: Int) throws -> Data {
            try Task.checkCancellation()
            guard let lastKey, key.sameStream(as: lastKey) else { throw CancellationError() }
            let frames = scanner.frameData(data, transport: key.transport)
            let start = message.payloadRange.lowerBound
            let end = min(message.payloadRange.upperBound, start + limit)
            guard frames.startIndex <= start, frames.endIndex >= end else { throw CancellationError() }
            return frames.subdata(in: start..<end)
        }
    }

    private struct DecodeKey: Equatable {
        let message: GRPCFrames.Message?
        let bodyGeneration: UInt64
        let encoding: String?
        let mediaType: GRPCFrames.MediaType
        let type: String?
        let descriptor: UUID
        let raw: Bool
    }

    private enum Output: Sendable {
        case decoded(String, notice: String?)
        case raw(Data, notice: String?)

        static let rawLimit = 65_536
    }

    private var encoding: String? { headers.value(of: "grpc-encoding") }
    private var messageType: String? {
        let requested = GRPCSchema.normalized(typeOverride)
        if !requested.isEmpty { return requested }
        return descriptors.schema?.messageType(for: path, isRequest: isRequest)
    }

    var body: some View {
        let scanKey = ScanKey(revision: bodyRevision, generation: bodyGeneration, complete: complete, truncated: truncated,
                              transport: mediaType.transport, encoding: encoding)
        let current = snapshot.flatMap { scanKey.sameStream(as: $0.key) ? $0 : nil }
        let scan = current?.scan ?? GRPCFrames.Scan(messages: [], issue: nil)
        let metadata = trailers.pairs.reduce(into: scan.trailers) { $0.append($1.name, $1.value) }
        let selected = scan.messages.first(where: { $0.id == selectedID }) ?? scan.messages.first
        let key = DecodeKey(message: selected, bodyGeneration: bodyGeneration, encoding: encoding, mediaType: mediaType,
                            type: messageType, descriptor: descriptors.revision, raw: raw)
        let rendered = output?.key == key ? output?.value : nil
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if !isRequest { responseStatus(metadata) }
                schemaControls
                if let selected {
                    messageControls(scan.messages, selected: selected)
                } else {
                    Text(complete ? "无 gRPC 消息" : "等待 gRPC 消息…").foregroundStyle(.secondary)
                }
                if let issue = scan.issue {
                    Text(issue).foregroundStyle(.orange)
                }
                if let selected {
                    messageContent(selected, output: rendered)
                }
                if metadata.count > 0 { trailingMetadata(metadata) }
            }
            .font(.caption)
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url): descriptors.load(url)
            case .failure(let error): descriptors.error = error.localizedDescription
            }
        }
        .task(id: scanKey) {
            if let scanned = try? await scanner.scan(data, key: scanKey), !Task.isCancelled {
                snapshot = scanned
            }
        }
        .task(id: key) {
            guard let message = key.message, let current else { return }
            if let decoded = await inspect(message, snapshot: current, key: key), !Task.isCancelled {
                output = (key, decoded)
            }
        }
    }

    private func inspect(_ message: GRPCFrames.Message, snapshot: ScanSnapshot, key: DecodeKey) async -> Output? {
        let supportsFormat = key.mediaType.format == "proto" || key.mediaType.format == "json"
        let oversized = message.byteCount > GRPCFrames.maxPayload
        let rawOnly = key.raw || oversized || !supportsFormat
        let limit = rawOnly ? Output.rawLimit : GRPCFrames.maxPayload
        guard let payload = try? await scanner.copyPayload(message, from: data, key: snapshot.key, limit: limit) else {
            return nil
        }
        if key.raw { return .raw(payload, notice: nil) }
        if oversized { return .raw(payload, notice: "消息超过 1 MiB 解码上限。") }
        if !supportsFormat { return .raw(payload, notice: "自定义消息格式 · \(key.mediaType.rawValue)") }

        let schema = descriptors.schema
        let worker = Task.detached(priority: .userInitiated) {
            try Self.decode(payload, compressed: message.compressed, key: key, schema: schema)
        }
        do {
            return try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        } catch {
            return .raw(Data(payload.prefix(Output.rawLimit)), notice: error.localizedDescription)
        }
    }

    private func responseStatus(_ metadata: HTTPHeaders) -> some View {
        let grpcStatus = GRPCFrames.status(headers: headers, trailers: metadata)
        return VStack(alignment: .leading, spacing: 4) {
            if let label = grpcStatus.label {
                Text("\(mediaType.transport.label) 状态 · \(label)").fontWeight(.semibold)
                    .foregroundStyle(grpcStatus.code == "0" ? Color.green : Color.orange)
            } else {
                Text(complete ? "未捕获 grpc-status" : "等待 gRPC 状态…").foregroundStyle(.secondary)
            }
            if let message = grpcStatus.message, !message.isEmpty {
                Text(message).textSelection(.enabled)
            }
            if let details = grpcStatus.details, metadata.value(of: "grpc-status-details-bin") == nil {
                Text("grpc-status-details-bin: \(details)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private var schemaControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Button("导入描述符…") { importing = true }
                    .disabled(descriptors.loading)
                    .help("导入 protoc 生成的 FileDescriptorSet (.pb / .desc)")
                if descriptors.loading {
                    ProgressView().controlSize(.small)
                } else if let file = descriptors.filename {
                    Text(file).lineLimit(1).foregroundStyle(.secondary)
                    Button { descriptors.clear(); typeOverride = "" } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除描述符")
                }
            }
            .controlSize(.small)
            if descriptors.schema != nil {
                TextField("完整消息类型（默认按 RPC 路径匹配）", text: $typeOverride)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Protobuf 消息类型")
                if let type = messageType {
                    Text(type).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if let error = descriptors.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    private func messageControls(_ messages: [GRPCFrames.Message], selected: GRPCFrames.Message) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("gRPC 消息", selection: Binding(get: { selected.id }, set: { selectedID = $0 })) {
                    ForEach(messages.indices, id: \.self) { index in
                        let message = messages[index]
                        Text("#\(index + 1) · \(message.byteCount) 字节").tag(message.id)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("gRPC 消息")
                Toggle("原始字节", isOn: $raw).toggleStyle(.checkbox)
            }
            .controlSize(.small)
            Text(selected.compressed ? "已压缩 · \(encoding ?? "未知编码")" : "未压缩")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func messageContent(_ message: GRPCFrames.Message, output: Output?) -> some View {
        switch output {
        case .raw(let bytes, let notice):
            if let notice { Text(notice).foregroundStyle(.secondary) }
            if bytes.isEmpty {
                Text("空消息").foregroundStyle(.secondary)
            } else {
                if bytes.count < message.byteCount {
                    Text("原始字节仅显示前 64 KiB。").foregroundStyle(.secondary)
                }
                HexView(data: bytes, generation: bodyGeneration).text.id(message.id)
            }
        case .decoded(let text, let notice):
            if let notice { Text(notice).foregroundStyle(.secondary) }
            Text(text.isEmpty ? "空消息" : text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case nil:
            ProgressView("正在解码…").controlSize(.small)
        }
    }

    private func trailingMetadata(_ trailers: HTTPHeaders) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("Trailers").fontWeight(.semibold)
            ForEach(trailers.pairs.indices, id: \.self) { index in
                let field = trailers.pairs[index]
                Text("\(field.name): \(field.value)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private nonisolated static func decode(_ bytes: Data, compressed: Bool,
                                           key: DecodeKey, schema: GRPCSchema?) throws -> Output {
        let payload = try GRPCFrames.decodePayload(bytes, compressed: compressed, encoding: key.encoding)
        if key.mediaType.format == "json" {
            let value = try JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed])
            let bytes = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
            let count = 512 * 1024
            return .decoded(String(decoding: bytes.prefix(count), as: UTF8.self),
                            notice: bytes.count > count ? "JSON 仅显示前 512 KiB。" : nil)
        }
        let type = key.type.flatMap { schema?.contains($0) == true ? $0 : nil }
        let notice: String?
        if let type {
            notice = "Protobuf · \(type)"
        } else if let requested = key.type {
            notice = "描述符未包含 \(requested) · 按 Protobuf 字段编号显示。"
        } else {
            notice = "Protobuf · 按字段编号显示"
        }
        return .decoded(try GRPCProtobuf.describe(payload, type: type, schema: schema), notice: notice)
    }
}
