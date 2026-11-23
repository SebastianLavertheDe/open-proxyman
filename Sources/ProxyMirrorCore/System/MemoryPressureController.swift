import Combine
import Darwin
import Foundation

extension Notification.Name {
    /// Derived renderers should cancel outstanding work and drop their cached
    /// presentations. Captured wire bytes and user documents are never removed.
    static let pmMemoryPressure = Notification.Name("ProxyMirror.memoryPressure")
}

/// Warning/critical dispatch events and the Help-menu simulation use exactly the
/// same cleanup path. Simulation requests cleanup; it never allocates pressure.
@MainActor
final class MemoryPressureController: ObservableObject {
    static let shared = MemoryPressureController()

    enum Level: String, Equatable, Sendable { case warning, critical }
    enum Source: String, Equatable, Sendable { case system, simulation }
    struct Event: Sendable {
        let level: Level
        let source: Source
        let date: Date
        let clearedCaches: [String]
        let residentBytesReleased: UInt64?
        var summary: String {
            let origin = source == .system ? Strings.Errors.memoryPressureControllerSystemMemoryPressure : Strings.Errors.memoryPressureControllerSimulateMemoryWarning
            return Strings.Errors.memoryPressureControllerClearedTypesOfRebuildableCachesCapturedTrafficAnd(String(origin), level == .critical ? Strings.Errors.memoryCritical : Strings.Errors.memoryWarning, Int(clearedCaches.count))
        }
    }
    struct Cleaner {
        let name: String
        let clear: () -> Void
    }

    @Published private(set) var isMonitoring = false
    @Published private(set) var cleanupCount = 0
    @Published private(set) var systemCount = 0
    @Published private(set) var simulationCount = 0
    @Published private(set) var warningCount = 0
    @Published private(set) var criticalCount = 0
    @Published private(set) var lastEvent: Event?
    private var source: DispatchSourceMemoryPressure?
    private var monitoringID: UUID?
    private let cleaners: [Cleaner]
    private let notifications: NotificationCenter
    private let now: () -> Date

    init(cleaners: [Cleaner]? = nil, notifications: NotificationCenter = .default,
         now: @escaping () -> Date = Date.init) {
        self.cleaners = cleaners ?? [
            Cleaner(name: "decoded-bodies", clear: { InspectionBody.clearCache() }),
            Cleaner(name: "leaf-tls-contexts", clear: { CertificateAuthority.shared.invalidateLeafContexts() }),
            Cleaner(name: "custom-certificate-chains", clear: { CustomCertificateStore.shared.invalidate() }),
            Cleaner(name: "client-tls-contexts", clear: { UpstreamTrust.clearClientIdentityContexts() }),
            Cleaner(name: "process-attribution", clear: { ProcessAttribution.shared.clearCache() }),
            Cleaner(name: "application-icons", clear: { ClientApplicationIcons.clearCache() }),
        ]
        self.notifications = notifications
        self.now = now
    }

    func startMonitoring() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        self.source = source
        let id = UUID()
        monitoringID = id
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.monitoringID == id, let source = self.source else { return }
                self.receiveSystemPressure(source.data)
            }
        }
        source.resume()
        isMonitoring = true
    }

    func stopMonitoring() {
        source?.setEventHandler {}
        source?.cancel()
        source = nil
        monitoringID = nil
        isMonitoring = false
    }

    /// Kept as a separate event-source boundary so checks can exercise real event
    /// flags without asking macOS to exhaust the machine's available memory.
    func receiveSystemPressure(_ flags: DispatchSource.MemoryPressureEvent) {
        if flags.contains(.critical) { _ = handlePressure(.critical, source: .system) }
        else if flags.contains(.warning) { _ = handlePressure(.warning, source: .system) }
    }

    @discardableResult
    func simulateWarning() -> Event { handlePressure(.warning, source: .simulation) }

    private func handlePressure(_ level: Level, source: Source) -> Event {
        let before = Self.residentMemory()
        for cleaner in cleaners { cleaner.clear() }
        cleanupCount += 1
        if source == .system { systemCount += 1 } else { simulationCount += 1 }
        if level == .critical { criticalCount += 1 } else { warningCount += 1 }
        // Synchronous main-thread delivery lets renderer observers release their
        // derived state before the after-cleanup resident-memory sample.
        notifications.post(name: .pmMemoryPressure, object: self,
            userInfo: ["level": level.rawValue, "source": source.rawValue, "cleanupCount": cleanupCount])
        let after = Self.residentMemory()
        let released = before.flatMap { initial in after.map { remaining in initial > remaining ? initial - remaining : 0 } }
        let event = Event(level: level, source: source, date: now(), clearedCaches: cleaners.map(\.name),
                          residentBytesReleased: released)
        lastEvent = event
        DiagnosticLog.record("memory-pressure source=\(source.rawValue) level=\(level.rawValue) caches=\(cleaners.count)")
        return event
    }

    nonisolated static func residentMemory() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }
}
