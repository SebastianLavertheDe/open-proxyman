import Foundation

/// Immutable metadata snapshot. Never passes mutable captured transactions to a worker.
struct FlowSummarySample: Sendable {
    enum State: Sendable, Equatable { case inProgress, completed, failed }
    let host: String
    let statusCode: Int
    let state: State
    let durationSeconds: Double
    let uploadedBytes: Int
    let downloadedBytes: Int

    init(host: String, statusCode: Int, state: State, durationSeconds: Double,
         uploadedBytes: Int = 0, downloadedBytes: Int = 0) {
        self.host = host; self.statusCode = statusCode; self.state = state; self.durationSeconds = durationSeconds
        self.uploadedBytes = uploadedBytes; self.downloadedBytes = downloadedBytes
    }

    @MainActor
    init(_ transaction: Transaction) {
        host = transaction.host; statusCode = transaction.statusCode; durationSeconds = transaction.duration
        uploadedBytes = transaction.requestBytes; downloadedBytes = transaction.responseBytes
        switch transaction.state {
        case .pending, .awaiting: state = .inProgress
        case .completed: state = .completed
        case .failed: state = .failed
        }
    }
}

struct FlowSummaryStatistics: Sendable {
    enum Bucket: String, CaseIterable, Identifiable, Sendable {
        case informational = "1xx", success = "2xx", redirect = "3xx", clientError = "4xx", serverError = "5xx"
        case unanswered = "未完成 / 未响应", failed = "传输失败"
        var id: String { rawValue }
    }
    struct Count: Identifiable, Sendable {
        let status: Int
        let count: Int
        var id: Int { status }
    }
    struct DurationBin: Identifiable, Sendable {
        let lowerMilliseconds: Double
        let upperMilliseconds: Double?
        var count: Int
        var id: Double { lowerMilliseconds }
        var label: String {
            if let upperMilliseconds { return "\(Int(lowerMilliseconds))–<\(Int(upperMilliseconds))" }
            return "≥\(Int(lowerMilliseconds))"
        }
    }
    struct Host: Identifiable, Sendable {
        let name: String
        var count = 0
        var uploadedBytes: Int64 = 0
        var downloadedBytes: Int64 = 0
        var id: String { name }
    }

    var total = 0
    var completed = 0
    var transportFailed = 0
    var httpErrors = 0
    var invalidCompletedDurations = 0
    var durationCount = 0
    var averageMilliseconds: Double?
    var p50Milliseconds: Double?
    var p95Milliseconds: Double?
    var p99Milliseconds: Double?
    var uploadedBytes: Int64 = 0
    var downloadedBytes: Int64 = 0
    var buckets: [Bucket: Int] = [:]
    var statusCounts: [Count] = []
    var hosts: [Host] = []
    var durationBins: [DurationBin] = Self.makeDurationBins()

    private static func makeDurationBins() -> [DurationBin] {
        let bounds: [Double] = [0, 10, 50, 100, 250, 500, 1000, 5000]
        return bounds.enumerated().map { index, lower in
            DurationBin(lowerMilliseconds: lower, upperMilliseconds: index + 1 < bounds.count ? bounds[index + 1] : nil, count: 0)
        }
    }

    /// Returns nil when cancelled, keeping rapid updates from publishing stale results.
    static func calculate(_ samples: [FlowSummarySample], cancelled: () -> Bool = { Task.isCancelled }) -> Self? {
        var result = Self()
        var statuses: [Int: Int] = [:]
        var byHost: [String: Host] = [:]
        var durations: [Double] = []
        durations.reserveCapacity(samples.count)
        for (index, sample) in samples.enumerated() {
            if index % 512 == 0, cancelled() { return nil }
            result.total += 1
            let up = Int64(max(0, sample.uploadedBytes)), down = Int64(max(0, sample.downloadedBytes))
            result.uploadedBytes = saturatedAdd(result.uploadedBytes, up)
            result.downloadedBytes = saturatedAdd(result.downloadedBytes, down)
            let host = sample.host.isEmpty ? "（无主机）" : sample.host
            var entry = byHost[host] ?? Host(name: host)
            entry.count += 1
            entry.uploadedBytes = saturatedAdd(entry.uploadedBytes, up)
            entry.downloadedBytes = saturatedAdd(entry.downloadedBytes, down)
            byHost[host] = entry
            let bucket: Bucket
            if sample.state == .failed {
                bucket = .failed; result.transportFailed += 1
            } else if sample.state == .inProgress || !(100...599).contains(sample.statusCode) {
                bucket = .unanswered
            } else {
                switch sample.statusCode {
                case 100...199: bucket = .informational
                case 200...299: bucket = .success
                case 300...399: bucket = .redirect
                case 400...499: bucket = .clientError
                default: bucket = .serverError
                }
            }
            result.buckets[bucket, default: 0] += 1
            if sample.state == .completed {
                result.completed += 1
                if (400...599).contains(sample.statusCode) { result.httpErrors += 1 }
                if (100...599).contains(sample.statusCode) { statuses[sample.statusCode, default: 0] += 1 }
                let ms = sample.durationSeconds * 1000
                if ms.isFinite, ms >= 0 {
                    durations.append(ms)
                    if let index = result.durationBins.firstIndex(where: { $0.upperMilliseconds.map { ms < $0 } ?? true }) {
                        result.durationBins[index].count += 1
                    }
                } else { result.invalidCompletedDurations += 1 }
            }
        }
        guard !cancelled() else { return nil }
        durations.sort()
        guard !cancelled() else { return nil }
        result.durationCount = durations.count
        if !durations.isEmpty {
            // Incremental mean avoids overflow from summing many large, finite durations.
            var mean = 0.0
            for (index, duration) in durations.enumerated() { mean += (duration - mean) / Double(index + 1) }
            result.averageMilliseconds = mean
            func percentile(_ fraction: Double) -> Double {
                durations[max(0, min(durations.count - 1, Int(ceil(Double(durations.count) * fraction)) - 1))]
            }
            result.p50Milliseconds = percentile(0.50)
            result.p95Milliseconds = percentile(0.95)
            result.p99Milliseconds = percentile(0.99)
        }
        result.statusCounts = statuses.keys.sorted().map { Count(status: $0, count: statuses[$0] ?? 0) }
        result.hosts = byHost.values.sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
        return result
    }

    private static func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }
}
