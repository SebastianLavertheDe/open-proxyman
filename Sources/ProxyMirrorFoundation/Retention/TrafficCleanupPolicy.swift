import Foundation

/// The portable retention decision; UI scheduling and resident-memory sampling are injected.
package struct TrafficCleanupPolicy {
    package static let maximumRemovalsPerPass = 1024

    package struct Configuration {
        package let enabled: Bool
        package let memoryLimitMB: Int
        package let intervalMinutes: Int

        package init(enabled: Bool, memoryLimitMB: Int, intervalMinutes: Int) {
            self.enabled = enabled
            self.memoryLimitMB = memoryLimitMB
            self.intervalMinutes = intervalMinutes
        }
    }

    package struct Result {
        package let checked: Bool
        package let removed: Int
        package let residentBytes: UInt64?
    }

    private var lastCheck: TimeInterval?
    package init() {}

    package mutating func run(configuration: Configuration, now: TimeInterval, forceTime: Bool = false,
                              residentMemory: () -> UInt64?, completedCount: () -> Int,
                              removeCompleted: (Int) -> Int) -> Result {
        guard configuration.enabled else {
            lastCheck = nil
            return Result(checked: false, removed: 0, residentBytes: nil)
        }
        let interval = TimeInterval(max(1, configuration.intervalMinutes)) * 60
        guard forceTime || (lastCheck.map { now - $0 >= interval } ?? true) else {
            return Result(checked: false, removed: 0, residentBytes: nil)
        }
        lastCheck = now
        guard var resident = residentMemory() else {
            return Result(checked: true, removed: 0, residentBytes: nil)
        }
        let (threshold, overflow) = UInt64(max(1, configuration.memoryLimitMB))
            .multipliedReportingOverflow(by: 1024 * 1024)
        guard !overflow, resident >= threshold else {
            return Result(checked: true, removed: 0, residentBytes: resident)
        }
        let allowance = min(Self.maximumRemovalsPerPass, max(64, completedCount() / 4))
        var removed = 0
        while resident >= threshold && removed < allowance {
            let count = removeCompleted(min(64, allowance - removed))
            guard count > 0 else { break }
            removed += count
            guard let next = residentMemory() else { break }
            resident = next
        }
        return Result(checked: true, removed: removed, residentBytes: resident)
    }
}
