import Combine
import SwiftUI
import ProxyMirrorFoundation

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
    @ObservedObject private var presentationSettings = AppSettings.shared
    @StateObject private var model = FlowSummaryModel()
    @State private var onlySelection = false
    @State private var automatic = true
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Toggle(Strings.Tools.includeOnlySelectedRequestsWithinTheCurrentFilter, isOn: $onlySelection)
                Spacer()
                Toggle(Strings.Tools.autoRefresh, isOn: $automatic)
                Button(Strings.Tools.refresh, action: refresh)
                if model.calculating { ProgressView().controlSize(.small) }
            }
            let stats = model.statistics
            HStack(spacing: 25) {
                metric(Strings.Tools.request, PresentationNumbers.integer(stats.total))
                metric(Strings.Tools.completed, PresentationNumbers.integer(stats.completed))
                metric(Strings.Tools.transportFailed, PresentationNumbers.integer(stats.transportFailed))
                metric("HTTP 4xx / 5xx", PresentationNumbers.integer(stats.httpErrors))
                metric(Strings.Tools.averageDuration, duration(stats.averageMilliseconds))
            }
            HStack(spacing: 28) {
                metric("P50", duration(stats.p50Milliseconds))
                metric("P95", duration(stats.p95Milliseconds))
                metric("P99", duration(stats.p99Milliseconds))
                Spacer()
                Text(Strings.Tools.trafficTransferTotals(String(describing: size(stats.uploadedBytes)), String(describing: size(stats.downloadedBytes)))).monospacedDigit()
            }
            Text(Strings.Tools.timingStatisticsExplanation(Int(stats.durationCount), String(describing: stats.invalidCompletedDurations > 0 ? Strings.Tools.excludedInvalidDurationValues(stats.invalidCompletedDurations) : "")))
                .font(.caption).foregroundStyle(.secondary)
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Strings.Tools.statusBuckets).font(.headline)
                    ForEach(FlowSummaryStatistics.Bucket.allCases) { bucket in
                        bar(bucket.localizedTitle, count: stats.buckets[bucket] ?? 0,
                            maximum: stats.buckets.values.max() ?? 0, color: bucket == .failed ? .red : .accentColor)
                    }
                    Text(Strings.Tools.transportFailuresAreCountedSeparatelyIncompleteRequestsOrRequests)
                        .font(.caption).foregroundStyle(.secondary)
                    Text(Strings.Tools.statusCodesOfCompletedRequests).font(.headline).padding(.top, 4)
                    List(stats.statusCounts) { entry in
                        HStack { Text(String(entry.status)); Spacer(); Text(PresentationNumbers.integer(entry.count)).monospacedDigit() }
                    }.frame(minHeight: 90)
                    if stats.statusCounts.isEmpty { Text(Strings.Tools.noCompletedHttpStatusCodes).font(.caption).foregroundStyle(.secondary) }
                }.frame(minWidth: 290)
                VStack(alignment: .leading, spacing: 8) {
                    Text(Strings.Tools.durationDistributionMilliseconds).font(.headline)
                    ForEach(stats.durationBins) { bin in
                        bar(bin.label, count: bin.count, maximum: stats.durationBins.map(\.count).max() ?? 0, color: .teal)
                    }
                    Text(Strings.Tools.rangesIncludeTheLowerBoundAndExcludeTheUpper)
                        .font(.caption).foregroundStyle(.secondary)
                    Text(Strings.Tools.summaryByHost).font(.headline).padding(.top, 4)
                    List(stats.hosts) { host in
                        HStack {
                            Text(host.name).lineLimit(1).textSelection(.enabled)
                            Spacer()
                            Text(Strings.Tools.hostRequestCount(Int(host.count), String(describing: size(host.downloadedBytes)))).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }.frame(minHeight: 90)
                    if stats.total == 0 { Text(Strings.Tools.noRequestsInTheCurrentScope).font(.caption).foregroundStyle(.secondary) }
                }.padding(.leading, 12).frame(minWidth: 340)
            }
            if let date = model.refreshedAt {
                Text(Strings.Tools.snapshot1AutomaticRefreshRunsAtMostOncePer(PresentationTime.string(from: date)))
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
            Text((title)).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
        }
    }
    private func bar(_ label: String, count: Int, maximum: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Text((label)).font(.caption.monospacedDigit()).frame(width: 112, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.7))
                        .frame(width: maximum == 0 ? 0 : geometry.size.width * CGFloat(count) / CGFloat(maximum))
                }
            }.frame(height: 13)
            Text(PresentationNumbers.integer(count)).font(.caption.monospacedDigit()).frame(minWidth: 36, alignment: .trailing)
        }.accessibilityElement(children: .ignore).accessibilityLabel(Strings.Tools.countAccessibility(String(describing: label), Int(count)))
    }
    private func duration(_ ms: Double?) -> String { ms.map { PresentationNumbers.milliseconds($0) } ?? "—" }
    private func size(_ count: Int64) -> String { PresentationNumbers.byteCount(count) }
}
