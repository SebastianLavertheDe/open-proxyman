import Foundation

/// Traffic filters and saved coloring rules share this execution boundary.
/// Returning nil means the result is unknown; callers must fail closed even for
/// a negative comparison. A pattern that exhausts its budget stays quarantined
/// until the rule is compiled again, so every incoming flow cannot retry it.
package final class BoundedTrafficRegex {
    private let expression: NSRegularExpression
    private let maximumDuration: TimeInterval
    private let maximumProgressCallbacks: Int
    private let lock = NSLock()
    private var exhausted = false

    package init(pattern: String, options: NSRegularExpression.Options = [],
         maximumDuration: TimeInterval = 0.008, maximumProgressCallbacks: Int = 128) throws {
        expression = try NSRegularExpression(pattern: pattern, options: options)
        self.maximumDuration = max(0, maximumDuration)
        self.maximumProgressCallbacks = max(0, maximumProgressCallbacks)
    }

    package func matchesAny(in values: [String]) -> Bool? {
        lock.lock()
        let unavailable = exhausted
        lock.unlock()
        guard !unavailable, !Task.isCancelled else { return nil }
        let started = ProcessInfo.processInfo.systemUptime
        var callbacks = 0
        var limited = false
        var cancelled = false
        func shouldStop() -> Bool {
            cancelled = Task.isCancelled
            limited = limited || callbacks > maximumProgressCallbacks
                || ProcessInfo.processInfo.systemUptime - started >= maximumDuration
            return cancelled || limited
        }
        for value in values {
            if shouldStop() { break }
            var matched = false
            expression.enumerateMatches(in: value, options: [.reportProgress],
                                        range: NSRange(value.startIndex..., in: value)) { result, flags, stop in
                callbacks += 1
                if flags.contains(.internalError) { limited = true; stop.pointee = true; return }
                if shouldStop() { stop.pointee = true; return }
                if result != nil { matched = true; stop.pointee = true }
            }
            if shouldStop() { break }
            if matched { return true }
        }
        if limited {
            lock.lock(); exhausted = true; lock.unlock()
        }
        return limited || cancelled ? nil : false
    }
}
