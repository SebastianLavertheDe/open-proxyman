import Foundation

/// A single producer owns a draft until publish. After publication, both
/// mutations and notifications are delivered in order on the main thread.
/// The producer remains on its own executor; only the supplied value changes
/// cross the UI boundary. Call these methods from that same producer executor.
package final class MetadataPublication<Value> {
    package let value: Value
    package private(set) var isPublished = false

    package init(_ value: Value) { self.value = value }

    package func update(_ mutation: @escaping (Value) -> Void) {
        guard isPublished else { mutation(value); return }
        Self.onMain { [value] in mutation(value) }
    }

    package func publish(_ notification: @escaping (Value) -> Void) {
        guard !isPublished else { return }
        isPublished = true
        Self.onMain { [value] in notification(value) }
    }

    package static func onMain(_ mutation: @escaping () -> Void) {
        if Thread.isMainThread { mutation() }
        else {
            DispatchQueue.main.async {
                dispatchPrecondition(condition: .onQueue(.main))
                mutation()
            }
        }
    }
}
