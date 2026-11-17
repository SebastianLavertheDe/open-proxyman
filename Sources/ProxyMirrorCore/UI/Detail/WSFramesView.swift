import SwiftUI

/// The message list and its preview keep independent scroll positions.
struct WSFramesView: View {
    @ObservedObject var tx: Transaction
    var direction: WSFrame.Direction? = nil

    @State private var selectedID: UUID?
    @State private var filter = ""
    @State private var directionFilter = DirectionFilter.all
    @State private var display = MessageDisplay.preview
    @State private var recovered: (input: RecoveryInput, frames: [WSFrame])?
    @State private var copyTask: Task<Void, Never>?
    @State private var copyFeedback: String?

    private enum DirectionFilter: String, CaseIterable {
        case all = "所有", sent = "发送", received = "接收"

        var direction: WSFrame.Direction? {
            switch self {
            case .all: nil
            case .sent: .upstream
            case .received: .downstream
            }
        }
    }

    private enum MessageDisplay: String, CaseIterable {
        case preview = "预览", rawText = "消息原文", tree = "JSON 树"
    }

    private struct RecoveryInput: Equatable {
        let request: UInt64?
        let response: UInt64?
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static let hexCopyLimit = 8 * 1024 * 1024

    var body: some View {
        let captured = tx.websocketFrames
        let oldSession = captured.first.map { $0.rsv1 == nil } ?? false
        let requestDeflate = oldSession && direction != .downstream
            ? WebSocketDeflate.negotiated(in: tx.responseHeaders, direction: .upstream) : nil
        let responseDeflate = oldSession && direction != .upstream
            ? WebSocketDeflate.negotiated(in: tx.responseHeaders, direction: .downstream) : nil
        let recovery = RecoveryInput(request: requestDeflate == nil ? nil : tx.requestBodyRevision,
                                     response: responseDeflate == nil ? nil : tx.responseBodyRevision)
        let allFrames = recovered.flatMap { $0.input == recovery ? $0.frames : nil } ?? captured
        let wantedDirection = direction ?? directionFilter.direction
        let rows = allFrames.filter {
            (wantedDirection == nil || $0.direction == wantedDirection) &&
            (filter.isEmpty || $0.opcodeName.localizedCaseInsensitiveContains(filter)
                || $0.previewText.localizedCaseInsensitiveContains(filter))
        }
        let selected = rows.first { $0.id == selectedID }
        return VSplitView {
            VStack(spacing: 0) {
                listControls
                messageTable(rows, allFrames: allFrames)
            }
            .frame(minHeight: 72, idealHeight: 150)

            messageDetails(selected, allFrames: allFrames)
                .frame(minHeight: 76, idealHeight: 160)
        }
        .task(id: recovery) {
            guard requestDeflate != nil || responseDeflate != nil else { return }
            let request = requestDeflate == nil ? Data() : tx.requestBody
            let response = responseDeflate == nil ? Data() : tx.responseBody
            let worker = Task.detached(priority: .userInitiated) {
                var previews: [UUID: WSFrame] = [:]
                if let requestDeflate {
                    for frame in requestDeflate.recoverPreviews(
                        for: captured.filter { $0.direction == .upstream }, wire: request, direction: .upstream) {
                        previews[frame.id] = frame
                    }
                }
                if let responseDeflate, !Task.isCancelled {
                    for frame in responseDeflate.recoverPreviews(
                        for: captured.filter { $0.direction == .downstream }, wire: response, direction: .downstream) {
                        previews[frame.id] = frame
                    }
                }
                return captured.map { previews[$0.id] ?? $0 }
            }
            let frames = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            if !Task.isCancelled { recovered = (recovery, frames) }
        }
        .onChange(of: selected?.id) { _ in cancelCopy() }
        .onDisappear { cancelCopy() }
    }

    private var listControls: some View {
        HStack(spacing: 7) {
            TextField("筛选消息", text: $filter)
                .textFieldStyle(.roundedBorder)
            if direction == nil {
                Picker("消息方向", selection: $directionFilter) {
                    ForEach(DirectionFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
    }

    private func messageTable(_ rows: [WSFrame], allFrames: [WSFrame]) -> some View {
        Table(rows, selection: $selectedID) {
            TableColumn("数据") { frame in
                HStack(spacing: 6) {
                    Image(systemName: frame.direction == .upstream ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .foregroundStyle(frame.direction == .upstream ? Color.green : Color.orange)
                        .help(frame.directionGlyph)
                        .accessibilityLabel(frame.direction == .upstream ? "发送" : "接收")
                    Text(frame.previewText.isEmpty ? frame.opcodeName : frame.previewText)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            TableColumn("时间") { frame in
                Text(Self.timeFormatter.string(from: frame.timestamp))
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
            }
            .width(92)
        }
        .accessibilityLabel("WebSocket 消息列表")
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let frame = rows.first(where: { ids.contains($0.id) }) {
                Button("复制原文") { copy(frame, from: allFrames, wireHex: false) }
                    .disabled(!canCopyText(frame))
                Button("复制捕获负载（十六进制）") { copy(frame, from: allFrames, wireHex: true) }
                    .disabled(frame.payload.isEmpty || frame.payload.count > Self.hexCopyLimit)
            }
        }
        .overlay {
            if rows.isEmpty {
                Text(filter.isEmpty ? "暂无 WebSocket 消息" : "没有匹配的消息")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func messageDetails(_ frame: WSFrame?, allFrames: [WSFrame]) -> some View {
        if let frame {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Picker("消息显示方式", selection: $display) {
                        ForEach(MessageDisplay.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    Spacer(minLength: 4)
                    if let copyFeedback {
                        Text(copyFeedback).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Button("复制原文") { copy(frame, from: allFrames, wireHex: false) }
                        .disabled(!canCopyText(frame))
                        .help("复制消息的原始文本，保留解压后的内容和原有格式")
                    Menu {
                        Button("复制捕获负载（十六进制）") { copy(frame, from: allFrames, wireHex: true) }
                            .disabled(frame.payload.isEmpty || frame.payload.count > Self.hexCopyLimit)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("更多消息操作")
                }
                .controlSize(.small)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(ProxymanTheme.inspectorChrome)
                Divider()
                preview(frame)
                    .id(PreviewID(frame: frame.id, rsv1: frame.rsv1, decodedCount: frame.decompressedPreview?.count))
            }
        } else {
            Text("选择一条 WebSocket 消息查看内容")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private struct PreviewID: Hashable {
        let frame: UUID
        let rsv1: Bool?
        let decodedCount: Int?
    }

    @ViewBuilder
    private func preview(_ frame: WSFrame) -> some View {
        if let data = frame.displayPayload {
            if data.isEmpty {
                messageHint("\(frame.opcodeName) · 无负载")
            } else if BodyContentView.isBinary(data: data, contentType: "text/plain") {
                HexView(data: data)
            } else {
                VStack(spacing: 0) {
                    if frame.decompressedPreviewTruncated == true {
                        Text("仅显示解压后的预览")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    if display == .tree && frame.decompressedPreviewTruncated != true {
                        WSMessageTree(data: data)
                    } else {
                        TextViewer(data: data, pretty: display != .rawText && frame.decompressedPreviewTruncated != true, revision: 0)
                    }
                }
            }
        } else {
            messageHint(WSFrame.unavailablePreview)
        }
    }

    private func messageHint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func canCopyText(_ frame: WSFrame) -> Bool {
        guard !frame.payload.isEmpty else { return false }
        if let data = frame.displayPayload {
            return frame.kind == .text || !BodyContentView.isBinary(data: data, contentType: "text/plain")
        }
        return frame.rsv1 == true && frame.kind == .text &&
            WebSocketDeflate.negotiated(in: tx.responseHeaders, direction: frame.direction) != nil
    }

    private func copy(_ frame: WSFrame, from frames: [WSFrame], wireHex: Bool) {
        cancelCopy()
        copyFeedback = "正在复制…"
        let deflate = WebSocketDeflate.negotiated(in: tx.responseHeaders, direction: frame.direction)
        let worker = Task.detached(priority: .userInitiated) { () -> String? in
            if wireHex {
                let digits = Array("0123456789abcdef".utf8)
                var result: [UInt8] = []
                result.reserveCapacity(frame.payload.count * 2)
                for byte in frame.payload {
                    result.append(digits[Int(byte >> 4)])
                    result.append(digits[Int(byte & 0xF)])
                }
                return String(decoding: result, as: UTF8.self)
            }
            if let text = frame.fullText { return text }
            guard frame.rsv1 == true, let bytes = deflate?.fullMessage(frame, in: frames) else { return nil }
            return String(data: bytes, encoding: .utf8)
        }
        copyTask = Task {
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            if let result {
                CopyPaste.copy(result)
                copyFeedback = "已复制"
            } else {
                copyFeedback = "完整文本不可用"
            }
        }
    }

    private func cancelCopy() {
        copyTask?.cancel()
        copyTask = nil
        copyFeedback = nil
    }
}

private struct WSMessageTree: View {
    let data: Data
    @State private var tree: JSONTreeNode?

    var body: some View {
        Group {
            if let tree {
                ScrollView {
                    JSONTreeNodesView(node: tree)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            } else {
                TextViewer(data: data, pretty: true, revision: 0)
            }
        }
        .task {
            let worker = Task.detached(priority: .userInitiated) { JSONTreeService.build(from: data) }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            if !Task.isCancelled { tree = result }
        }
    }
}

/// JSON 树递归视图（对齐 Proxyman JSON 树配色）
struct JSONTreeNodesView: View {
    let node: JSONTreeNode
    @State private var expanded: Bool

    init(node: JSONTreeNode, expanded: Bool = true) {
        self.node = node
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if node.isBranch {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                        Text("\(node.key) : \(node.kindName) (\(node.childCount))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(ProxymanTheme.jsonKey)
                    }
                }
                .buttonStyle(.plain)
                if expanded {
                    ForEach(node.children) { child in
                        JSONTreeNodesView(node: child, expanded: false)
                            .padding(.leading, 14)
                    }
                    if node.childCount > node.children.count {
                        Text("其余项目未展开预览").font(.caption).foregroundStyle(.secondary)
                            .padding(.leading, 14)
                    }
                }
            } else {
                HStack(spacing: 4) {
                    Text("\(node.key) :")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(ProxymanTheme.jsonKey)
                    Text(node.valuePreview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(colorFor(node))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func colorFor(_ node: JSONTreeNode) -> Color {
        switch node.kindName {
        case "String": return ProxymanTheme.jsonString
        case "Number": return ProxymanTheme.jsonNumber
        case "Bool", "Null": return ProxymanTheme.jsonBoolNull
        default: return .primary
        }
    }
}
