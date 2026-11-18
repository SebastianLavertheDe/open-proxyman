import SwiftUI

/// SSE（text/event-stream）事件级视图：序号 / 事件名 / id / 到达时间 / data（JSON 自动美化）
struct SseEventsView: View {
    @ObservedObject var tx: Transaction

    private struct RecoveryInput: Equatable {
        let transaction: ObjectIdentifier
        let revision: UInt64
        let generation: UInt64
        let encodings: [String]
    }

    private var recoveryInput: RecoveryInput? {
        guard tx.responseBodyComplete, !tx.responseTruncated, !tx.sseEventsTruncated,
              !tx.responseBody.isEmpty else { return nil }
        let encodings = SSEBodyStream.encodings(tx.responseHeaders)
        guard tx.sseDecodingDeferred || tx.sseEvents.isEmpty || !encodings.isEmpty else { return nil }
        return RecoveryInput(transaction: ObjectIdentifier(tx), revision: tx.responseBodyRevision,
                             generation: tx.responseBodyGeneration, encodings: encodings)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("共 \(tx.sseEvents.count) 个事件")
                if tx.sseEventsTruncated { Text("已截断") }
                if let first = tx.sseEvents.first?.at, let last = tx.sseEvents.last?.at {
                    Text(String(format: "· 跨度 %.1fs", max(last.timeIntervalSince(first), 0)))
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            if tx.sseEvents.contains(where: { $0.at == nil }) {
                Text("事件从捕获正文恢复，历史到达时间未记录。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            }
            if let issue = tx.sseParseIssue {
                Text(issue).font(.caption).foregroundStyle(tx.sseDecodingDeferred ? Color.secondary : Color.orange)
                    .textSelection(.enabled).padding(.horizontal, 10)
            }
            if tx.sseEvents.isEmpty {
                Text(tx.sseDecodingDeferred && tx.responseBodyComplete ? "正在恢复 SSE 事件…" :
                     tx.responseBodyComplete || tx.state == .failed || (tx.sseParseIssue != nil && !tx.sseDecodingDeferred)
                        ? "没有可显示的 SSE 事件" : "等待事件…")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(tx.sseEvents, id: \.index) { event in
                                eventRow(event).id(event.index)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: tx.sseEvents.count) { _ in
                        proxy.scrollTo(tx.sseEvents.last?.index ?? 0, anchor: .bottom)
                    }
                }
            }
        }
        .task(id: recoveryInput) {
            guard let input = recoveryInput else { return }
            let data = tx.responseBody
            let headers = tx.responseHeaders
            let worker = Task.detached(priority: .userInitiated) {
                SSEBodyRecovery.recover(data, headers: headers, complete: true, truncated: false)
            }
            let snapshot = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, input.transaction == ObjectIdentifier(tx),
                  input.revision == tx.responseBodyRevision, input.generation == tx.responseBodyGeneration else { return }
            tx.applySSESnapshot(snapshot, preservingArrivalTimes: true)
        }
    }

    private func eventRow(_ event: SSEEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("#\(event.index)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(event.event)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(event.event == "message" ? Color.secondary : Color.orange)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                if let id = event.id {
                    Text("id: \(id)")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }
                if let retry = event.retry {
                    Text("retry: \(retry)")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }
                Spacer()
                if event.index > 0, let at = event.at, let previous = tx.sseEvents[safe: event.index - 1]?.at {
                    Text(String(format: "+%.0f ms", max(0, at.timeIntervalSince(previous) * 1000)))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Text(event.at?.formatted(date: .omitted, time: .standard) ?? "到达时间未记录")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if let tree = JSONTreeService.build(from: Data(event.data.utf8)) {
                JSONTreeNodesView(node: tree, expanded: false)
            } else {
                Text(event.data)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
        .contextMenu { Button("复制事件数据") { CopyPaste.copy(event.data) } }
    }

}
