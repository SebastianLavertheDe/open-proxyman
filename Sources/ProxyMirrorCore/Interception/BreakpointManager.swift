import Foundation

@MainActor
final class BreakpointManager: ObservableObject {
    static let shared = BreakpointManager()
    nonisolated static let enabledSnapshot = LockedBox(UserDefaults.standard.object(forKey: "breakpoints.enabled") as? Bool ?? true)

    @Published private(set) var held: [HeldItem] = []
    @Published var enabled = BreakpointManager.enabledSnapshot.value {
        didSet {
            Self.enabledSnapshot.set(enabled)
            UserDefaults.standard.set(enabled, forKey: "breakpoints.enabled")
        }
    }
    @Published var autoBringToFront = UserDefaults.standard.object(forKey: "breakpoints.autoOpen") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoBringToFront, forKey: "breakpoints.autoOpen") }
    }

    struct HeldItem: Identifiable {
        let id: UUID
        let txID: UUID
        let phase: BreakpointRule.Phase
        let summary: String
        let source: String
        let rule: String
        let message: BreakpointMessage
        let deadline: Date
    }

    enum Decision: Sendable {
        case original
        case apply(BreakpointMessage)
        case drop(String)
        case discard
    }

    private var pending: [UUID: @Sendable (Decision) -> Void] = [:]

    func hold(_ item: HeldItem, resume: @escaping @Sendable (Decision) -> Void) {
        guard enabled else { resume(.original); return }
        guard held.count < 48 else { resume(.drop(OperationIssue.modelBreakpointQueueFull.diagnostic)); return }
        let first = held.isEmpty
        pending[item.id] = resume
        held.append(item)
        if autoBringToFront && first {
            NotificationCenter.default.post(name: .pmBreakpointHit, object: nil)
        }
    }

    func continueOriginal(_ item: HeldItem) { finish(item.id, decision: .original) }

    func applyAndExecute(_ item: HeldItem, draft: String) throws {
        finish(item.id, decision: .apply(try item.message.applying(draft)))
    }

    func drop(_ item: HeldItem) { finish(item.id, decision: .drop(OperationIssue.modelBreakpointCancelled.diagnostic)) }

    func discardAll() {
        for id in held.map(\.id) { finish(id, decision: .discard) }
    }

    func forget(_ id: UUID) {
        pending.removeValue(forKey: id)
        held.removeAll { $0.id == id }
    }

    private func finish(_ id: UUID, decision: Decision) {
        let callback = pending[id]
        forget(id)
        callback?(decision)
    }
}

extension Notification.Name {
    static let pmBreakpointHit = Notification.Name("pm.breakpoint.hit")
}
