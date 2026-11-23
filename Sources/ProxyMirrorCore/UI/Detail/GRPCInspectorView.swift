import SwiftUI
import UniformTypeIdentifiers

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
    var target = ""

    @ObservedObject private var descriptors = ProtobufRuleStore.shared
    @State private var showRules = false
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
        return descriptors.resolution(for: target.isEmpty ? path : target, isRequest: isRequest)?.type
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
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !isRequest { responseStatus(metadata) }
                        schemaControls
                        if let selected {
                            messageControls(scan.messages, selected: selected)
                        } else {
                            Text(complete ? Strings.Detail.noGrpcMessages : Strings.Detail.waitingForGrpcMessages).foregroundStyle(.secondary)
                        }
                        if let issue = scan.issue { Text(issue).foregroundStyle(.orange) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: selected == nil ? .infinity : min(176, max(0, geometry.size.height - 18) * 0.35))
                if let selected {
                    messageContent(selected, output: rendered)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                if metadata.count > 0 {
                    ScrollView { trailingMetadata(metadata).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: min(100, max(0, geometry.size.height - 18) * 0.2))
                }
            }
            .font(.caption)
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url): descriptors.importSchema(url)
            case .failure(let error): descriptors.error = LocalizedErrorPresentation.message(for: error)
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
        if oversized { return .raw(payload, notice: Strings.Detail.theMessageExceedsThe1MibDecodingLimit) }
        if !supportsFormat { return .raw(payload, notice: Strings.Detail.customMessageFormat(String(describing: key.mediaType.rawValue))) }

        let schema = descriptors.resolution(for: target.isEmpty ? path : target, isRequest: isRequest)?.schema
            ?? descriptors.schema(containing: key.type)
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
            return .raw(Data(payload.prefix(Output.rawLimit)), notice: LocalizedErrorPresentation.message(for: error))
        }
    }

    private func responseStatus(_ metadata: HTTPHeaders) -> some View {
        let grpcStatus = GRPCFrames.status(headers: headers, trailers: metadata)
        return VStack(alignment: .leading, spacing: 4) {
            if let label = grpcStatus.label {
                Text(Strings.Detail.status2(String(describing: mediaType.transport.label), String(describing: label))).fontWeight(.semibold)
                    .foregroundStyle(grpcStatus.code == "0" ? Color.green : Color.orange)
            } else {
                Text(complete ? Strings.Detail.grpcStatusNotCaptured : Strings.Detail.waitingForGrpcStatus).foregroundStyle(.secondary)
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
                Button(Strings.Detail.importDescriptor) { importing = true }.disabled(descriptors.loading)
                    .help(Strings.Detail.importAFiledescriptorsetPbDescGeneratedByProtocAndSaveIt)
                Button(Strings.Detail.globalMappings) { showRules = true }
                if descriptors.loading { ProgressView().controlSize(.small) }
                Spacer()
                Text(Strings.Detail.schemas(descriptors.configuration.schemas.count)).foregroundStyle(.secondary)
            }.controlSize(.small)
            TextField(Strings.Detail.fullyQualifiedMessageTypeDefaultsToGlobalRulesRpcPathMatching, text: $typeOverride)
                .textFieldStyle(.roundedBorder).accessibilityLabel(Strings.Detail.protobufMessageType)
            if let type = messageType {
                Text(type).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let error = descriptors.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .sheet(isPresented: $showRules) { ProtobufRulesView() }
    }

    private func messageControls(_ messages: [GRPCFrames.Message], selected: GRPCFrames.Message) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker(Strings.Detail.grpcMessages, selection: Binding(get: { selected.id }, set: { selectedID = $0 })) {
                    ForEach(messages.indices, id: \.self) { index in
                        let message = messages[index]
                        Text(Strings.Detail.bytes(index + 1, message.byteCount)).tag(message.id)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(Strings.Detail.grpcMessages)
                Toggle(Strings.Detail.rawBytes, isOn: $raw).toggleStyle(.checkbox)
            }
            .controlSize(.small)
            Text(selected.compressed ? Strings.Detail.compressed(String(describing: encoding ?? Strings.Detail.unknownEncoding)) : Strings.Detail.uncompressed)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func messageContent(_ message: GRPCFrames.Message, output: Output?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch output {
            case .raw(let bytes, let notice):
                if let notice { Text(notice).foregroundStyle(.secondary) }
                if bytes.isEmpty {
                    Text(Strings.Detail.emptyMessage).foregroundStyle(.secondary)
                } else {
                    if bytes.count < message.byteCount {
                        Text(Strings.Detail.onlyTheFirst64KibOfRawBytesAreShown).foregroundStyle(.secondary)
                    }
                    HexView(data: bytes, generation: bodyGeneration).id(message.id)
                }
            case .decoded(let text, let notice):
                if let notice { Text(notice).foregroundStyle(.secondary) }
                CodeDocument(text: text.isEmpty ? Strings.Detail.emptyMessage : text)
                    .id(message.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case nil:
                ProgressView(Strings.Detail.decoding).controlSize(.small)
            }
        }
    }

    private func trailingMetadata(_ trailers: HTTPHeaders) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text(Strings.Detail.trailers).fontWeight(.semibold)
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
                            notice: bytes.count > count ? Strings.Detail.jsonPreviewIsLimitedToTheFirst512Kib : nil)
        }
        let type = key.type.flatMap { schema?.contains($0) == true ? $0 : nil }
        let notice: String?
        if let type {
            notice = "Protobuf · \(type)"
        } else if let requested = key.type {
            notice = Strings.Detail.theDescriptorDoesNotContainShowingProtobufFieldNumbers(String(describing: requested))
        } else {
            notice = Strings.Detail.protobufFieldNumbers
        }
        return .decoded(try GRPCProtobuf.describe(payload, type: type, schema: schema), notice: notice)
    }
}
