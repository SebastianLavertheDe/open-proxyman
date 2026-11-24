import Combine
import Foundation

/// Retention policy for live requests. Saved snapshots and imported sessions are independent.
@MainActor
final class TrafficCleanupController: ObservableObject {
    static let shared = TrafficCleanupController()
    static let maximumRemovalsPerPass = TrafficCleanupPolicy.maximumRemovalsPerPass
    typealias Configuration = TrafficCleanupPolicy.Configuration

    @Published private(set) var isMonitoring = false
    @Published private(set) var removedRequests = 0
    @Published private(set) var lastRun: Date?
    @Published private(set) var lastResidentBytes: UInt64?
    private var timer: Timer?
    private var policy = TrafficCleanupPolicy()
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
        let configuration = configuration()
        let result = policy.run(configuration: configuration, now: now(), forceTime: forceTime,
                                residentMemory: residentMemory, completedCount: completedCount,
                                removeCompleted: { limit in autoreleasepool { self.removeCompleted(limit) } })
        if result.checked {
            lastRun = Date()
            lastResidentBytes = result.residentBytes
        }
        removedRequests += result.removed
        if result.removed > 0 {
            DiagnosticLog.record("automatic-traffic-cleanup removed=\(result.removed) resident=\(result.residentBytes ?? 0) limitMB=\(configuration.memoryLimitMB)")
        }
        return result.removed
    }
}
