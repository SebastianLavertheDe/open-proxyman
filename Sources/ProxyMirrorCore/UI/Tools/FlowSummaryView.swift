import Combine
import SwiftUI

@MainActor
private final class FlowSummaryModel: ObservableObject {
    @Published private(set) var statistics = FlowSummaryStatistics()
    @Published private(set) var calculating = false
    @Published private(set) var refreshedAt: Date?
    private var calculation: Task<FlowSummaryStatistics?, Never>?
    private var publication: Task<Void, Never>?
    private var generation = UUID()

    func refresh(_ samples: [FlowSummarySample]) {
        stop()
        calculating = true
        let id = UUID(); generation = id
        let work = Task.detached(priority: .utility) { FlowSummaryStatistics.calculate(samples) }
        calculation = work
        publication = Task { [weak self] in
            let result = await work.value
            guard !Task.isCancelled, let self, self.generation == id, let result else { return }
            self.statistics = result; self.calculating = false; self.refreshedAt = Date()
        }
    }

    func stop() { calculation?.cancel(); publication?.cancel(); calculation = nil; publication = nil }
}

@MainActor
struct FlowSummaryView: View {
    @ObservedObject var store: TrafficStore
    @StateObject private var model = FlowSummaryModel()
    @State private var onlySelection = false
    @State private var automatic = true
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Toggle("仅统计当前筛选内的所选请求", isOn: $onlySelection)
                Spacer()
                Toggle("自动刷新", isOn: $automatic)
                Button("刷新", action: refresh)
                if model.calculating { ProgressView().controlSize(.small) }
            }
            let stats = model.statistics
            HStack(spacing: 25) {
                metric("请求", String(stats.total))
                metric("已完成", String(stats.completed))
                metric("传输失败", String(stats.transportFailed))
                metric("HTTP 4xx / 5xx", String(stats.httpErrors))
                metric("平均耗时", duration(stats.averageMilliseconds))
            }
            HStack(spacing: 28) {
                metric("P50", duration(stats.p50Milliseconds))
                metric("P95", duration(stats.p95Milliseconds))
                metric("P99", duration(stats.p99Milliseconds))
                Spacer()
                Text("上传 \(size(stats.uploadedBytes)) · 下载 \(size(stats.downloadedBytes))").monospacedDigit()
            }
            Text("耗时统计已完成请求中的有效非负数值（\(stats.durationCount) 条）；分位数采用 nearest-rank。\(stats.invalidCompletedDurations > 0 ? "已排除 \(stats.invalidCompletedDurations) 条无效耗时。" : "")")
                .font(.caption).foregroundStyle(.secondary)
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("状态分桶").font(.headline)
                    ForEach(FlowSummaryStatistics.Bucket.allCases) { bucket in
                        bar(bucket.rawValue, count: stats.buckets[bucket] ?? 0,
                            maximum: stats.buckets.values.max() ?? 0, color: bucket == .failed ? .red : .accentColor)
                    }
                    Text("传输失败单独计数；未完成或没有有效 HTTP 状态的请求归入「未完成 / 未响应」。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("已完成请求的具体状态码").font(.headline).padding(.top, 4)
                    List(stats.statusCounts) { entry in
                        HStack { Text(String(entry.status)); Spacer(); Text(String(entry.count)).monospacedDigit() }
                    }.frame(minHeight: 90)
                    if stats.statusCounts.isEmpty { Text("暂无已完成的 HTTP 状态码").font(.caption).foregroundStyle(.secondary) }
                }.frame(minWidth: 290)
                VStack(alignment: .leading, spacing: 8) {
                    Text("耗时分布（毫秒 ms）").font(.headline)
                    ForEach(stats.durationBins) { bin in
                        bar(bin.label, count: bin.count, maximum: stats.durationBins.map(\.count).max() ?? 0, color: .teal)
                    }
                    Text("区间左闭右开，例如 10–<50 表示 ≥10 ms 且 <50 ms；最后一档包含 5000 ms 及以上。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("按主机汇总").font(.headline).padding(.top, 4)
                    List(stats.hosts) { host in
                        HStack {
                            Text(host.name).lineLimit(1).textSelection(.enabled)
                            Spacer()
                            Text("\(host.count) 条 · ↓\(size(host.downloadedBytes))").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }.frame(minHeight: 90)
                    if stats.total == 0 { Text("当前范围没有请求").font(.caption).foregroundStyle(.secondary) }
                }.padding(.leading, 12).frame(minWidth: 340)
            }
            if let date = model.refreshedAt {
                Text("统计快照：\(date.formatted(date: .omitted, time: .standard))；自动刷新最多每秒一次，聚合在后台计算。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20).frame(minWidth: 760, minHeight: 650)
        .onAppear { visible = true; refresh() }
        .onDisappear { visible = false; model.stop() }
        .onChange(of: onlySelection) { _ in refresh() }
        .onChange(of: automatic) { value in if value { refresh() } }
        .onReceive(store.objectWillChange.throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)) { _ in
            guard automatic else { return }
            // ObservableObject publishes before the corresponding mutation.
            DispatchQueue.main.async { refresh() }
        }
    }

    private func refresh() {
        guard visible else { return }
        let flows = onlySelection ? store.visible.filter { store.selectedIDs.contains($0.id) } : store.visible
        model.refresh(flows.map(FlowSummarySample.init))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
        }
    }
    private func bar(_ label: String, count: Int, maximum: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption.monospacedDigit()).frame(width: 112, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.7))
                        .frame(width: maximum == 0 ? 0 : geometry.size.width * CGFloat(count) / CGFloat(maximum))
                }
            }.frame(height: 13)
            Text(String(count)).font(.caption.monospacedDigit()).frame(minWidth: 36, alignment: .trailing)
        }.accessibilityElement(children: .ignore).accessibilityLabel("\(label)：\(count) 条")
    }
    private func duration(_ ms: Double?) -> String { ms.map { String(format: "%.1f ms", $0) } ?? "—" }
    private func size(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}
