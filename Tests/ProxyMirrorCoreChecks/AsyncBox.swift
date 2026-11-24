import Foundation

/// A bounded mailbox for callbacks running on a different thread.
final class NSBox<T: Sendable>: @unchecked Sendable {
    struct Timeout: Error, CustomStringConvertible {
        let seconds: TimeInterval
        var description: String { "Async check did not complete within \(seconds) seconds" }
    }

    private let condition = NSCondition()
    private var value: T?
    private var done = false

    func store(_ newValue: T) {
        condition.lock()
        guard !done else { condition.unlock(); return }
        self.value = newValue
        done = true
        condition.broadcast()
        condition.unlock()
    }

    func wait(timeout: TimeInterval = 8) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !done {
            guard condition.wait(until: deadline) || done else { throw Timeout(seconds: timeout) }
        }
        return value!
    }
}
