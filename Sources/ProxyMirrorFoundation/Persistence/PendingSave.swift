import Foundation

/// Coalesces edits while retaining failed writes for an explicit retry at shutdown.
package final class PendingSave {
    private let delay: TimeInterval
    private let commit: () throws -> Void
    private let reportFailure: (Error) -> Void
    private var timer: Timer?
    package private(set) var hasChanges = false

    package init(delay: TimeInterval = 0.5, commit: @escaping () throws -> Void,
         reportFailure: @escaping (Error) -> Void) {
        self.delay = delay
        self.commit = commit
        self.reportFailure = reportFailure
    }

    deinit { timer?.invalidate() }

    package func schedule() {
        hasChanges = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.timer = nil
            do { try self.flush() }
            catch { self.reportFailure(error) }
        }
    }

    /// A failed write keeps the pending state, so quitting cannot silently lose it.
    package func flush() throws {
        guard hasChanges else { return }
        try commit()
        didCommit()
    }

    /// An immediate transaction already persisted the current edits.
    package func didCommit() {
        timer?.invalidate()
        timer = nil
        hasChanges = false
    }
}
