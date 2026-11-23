import Combine
import Foundation

/// Retention policy for live requests. Saved snapshots and imported sessions are independent.
@MainActor
final class TrafficCleanupController: ObservableObject {
    static let shared = TrafficCleanupController()
    static let maximumRemovalsPerPass = 1024

    struct Configuration {
        let enabled: Bool
        let memoryLimitMB: Int
        let intervalMinutes: Int
    }

    @Published private(set) var isMonitoring = false
    @Published private(set) var removedRequests = 0
    @Published private(set) var lastRun: Date?
    @Published private(set) var lastResidentBytes: UInt64?
    private var timer: Timer?
    private var lastCheck: TimeInterval?
    private let configuration: () -> Configuration
    private let now: () -> TimeInterval
    private let residentMemory: () -> UInt64?
    private let removeCompleted: (Int) -> Int
    private let completedCount: () -> Int

    init(configuration: (() -> Configuration)? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         residentMemory: @escaping () -> UInt64? = MemoryPressureController.residentMemory,
         completedCount: (() -> Int)? = nil,
         removeCompleted: ((Int) -> Int)? = nil) {
        self.configuration = configuration ?? {
            let settings = AppSettings.shared
            return Configuration(enabled: settings.automaticTrafficCleanup,
                                 memoryLimitMB: settings.cleanupMemoryLimitMB,
                                 intervalMinutes: settings.cleanupIntervalMinutes)
        }
        self.now = now
        self.residentMemory = residentMemory
        self.completedCount = completedCount ?? { AppState.shared.store.completedLiveRequestCount }
        self.removeCompleted = removeCompleted ?? { AppState.shared.store.removeOldestCompleted(count: $0) }
    }

    func startMonitoring() {
        guard timer == nil else { return }
        // A short timer observes preference changes; resident-memory checks retain their configured cadence.
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runIfNeeded() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        isMonitoring = true
        runIfNeeded()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        isMonitoring = false
    }

    /// `forceTime` bypasses the interval for an explicit user action or a deterministic check.
    /// It never bypasses the enable switch or the resident-memory threshold.
    @discardableResult
    func runIfNeeded(forceTime: Bool = false) -> Int {
        let policy = configuration()
        guard policy.enabled else { lastCheck = nil; return 0 }
        let timestamp = now()
        let interval = TimeInterval(max(1, policy.intervalMinutes)) * 60
        guard forceTime || (lastCheck.map({ timestamp - $0 >= interval }) ?? true) else { return 0 }
        lastCheck = timestamp
        lastRun = Date()
        let threshold = UInt64(max(1, policy.memoryLimitMB)) * 1024 * 1024
        guard var resident = residentMemory() else { lastResidentBytes = nil; return 0 }
        lastResidentBytes = resident
        guard resident >= threshold else { return 0 }
        // ARC and the allocator may not return resident pages immediately. Bound one
        // pass instead of draining all traffic while repeatedly sampling a sticky RSS.
        let allowance = min(Self.maximumRemovalsPerPass, max(64, completedCount() / 4))
        var removed = 0
        while resident >= threshold && removed < allowance {
            // Release local transaction references before resampling the actual resident size.
            let count = autoreleasepool { removeCompleted(min(64, allowance - removed)) }
            guard count > 0 else { break }
            removed += count
            guard let next = residentMemory() else { break }
            resident = next
            lastResidentBytes = next
        }
        removedRequests += removed
        if removed > 0 {
            DiagnosticLog.record("automatic-traffic-cleanup removed=\(removed) resident=\(lastResidentBytes ?? resident) limitMB=\(policy.memoryLimitMB)")
        }
        return removed
    }
}
