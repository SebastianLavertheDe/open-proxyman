import SwiftUI

/// SSE（text/event-stream）事件级视图：序号 / 事件名 / id / 到达时间 / data（JSON 自动美化）
struct SseEventsView: View {
    @ObservedObject var tx: Transaction

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("共 \(tx.sseEvents.count) 个事件")
                if tx.sseEventsTruncated { Text("已截断") }
                if !tx.sseEvents.isEmpty, let first = tx.sseEvents.first, let last = tx.sseEvents.last {
                    Text(String(format: "· 跨度 %.1fs", max(last.at.timeIntervalSince(first.at), 0)))
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            if tx.sseEvents.isEmpty {
                Text(tx.responseBodyComplete ? "没有可显示的 SSE 事件" : "等待事件…")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(tx.sseEvents) { event in
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
                if event.index > 0, let previous = tx.sseEvents[safe: event.index - 1] {
                    Text(String(format: "+%.0f ms", max(0, event.at.timeIntervalSince(previous.at) * 1000)))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Text(event.at.formatted(date: .omitted, time: .standard))
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
