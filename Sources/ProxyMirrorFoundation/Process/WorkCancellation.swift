import Foundation

/// Cancellation shared by detached work and its actual file/process operation.
package final class WorkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    package init() {}
    package func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    package var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    package func check() throws { if isCancelled { throw CancellationError() } }

    /// A successful commit and cancellation have a single ordering point.
    package func whileActive<T>(_ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        return try operation()
    }
}
