import Foundation

/// Publication accepts only unchanged keys. Rows added/changed while a worker
/// runs stay visible in a pending tail and enter the next sort, without aborting
/// the current round. Removed rows can never reappear from an old snapshot.
package enum ColumnOrderPublication {
    package struct Result: Sendable {
        package let indices: [Int]
        package let orderedKeys: [JSONFieldCache.Key]
        package let pendingCount: Int
    }
    package static func reconcile(ordered: [JSONFieldCache.Key], current: [JSONFieldCache.Key]) -> Result {
        let positions = Dictionary(current.enumerated().map { ($0.element.owner, $0.offset) }, uniquingKeysWith: { a, _ in a })
        var included = Set<Int>()
        var indices: [Int] = [], keys: [JSONFieldCache.Key] = []
        for key in ordered {
            guard let index = positions[key.owner], current[index] == key, included.insert(index).inserted else { continue }
            indices.append(index); keys.append(key)
        }
        let pending = current.indices.filter { !included.contains($0) }
        indices.append(contentsOf: pending)
        return Result(indices: indices, orderedKeys: keys, pendingCount: pending.count)
    }
}

package enum PresentationPredicateResult: Sendable, Equatable {
    case matched, notMatched, pending
    package static func all<S: Sequence>(_ values: S) -> Self where S.Element == Self {
        var pending = false
        for value in values { if value == .notMatched { return .notMatched }; pending = pending || value == .pending }
        return pending ? .pending : .matched
    }
    package static func any<S: Sequence>(_ values: S) -> Self where S.Element == Self {
        var pending = false
        for value in values { if value == .matched { return .matched }; pending = pending || value == .pending }
        return pending ? .pending : .notMatched
    }
}
