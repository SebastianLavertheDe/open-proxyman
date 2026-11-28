/// Serial snapshot persistence policy. The owner performs I/O and confines all
/// transitions to its own executor; a failed write remains dirty until retried.
package struct SnapshotSaveState<Snapshot> {
    private var pending: Snapshot?
    private var inFlight: Snapshot?

    package enum Completion: Equatable { case clean, newerSnapshot, failed }
    package init() {}
    package var hasChanges: Bool { pending != nil || inFlight != nil }
    package var isWriting: Bool { inFlight != nil }

    package mutating func enqueue(_ snapshot: Snapshot) { pending = snapshot }

    package mutating func beginWrite() -> Snapshot? {
        guard inFlight == nil, let snapshot = pending else { return nil }
        pending = nil
        inFlight = snapshot
        return snapshot
    }

    /// A newer edit supersedes the completed snapshot, including after failure.
    /// A failed latest snapshot is retained without an automatic retry loop.
    package mutating func completeWrite(succeeded: Bool) -> Completion {
        guard let snapshot = inFlight else { preconditionFailure("No snapshot write is in progress") }
        inFlight = nil
        if pending != nil { return .newerSnapshot }
        if succeeded { return .clean }
        pending = snapshot
        return .failed
    }
}
