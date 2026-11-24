import Foundation

/// Scalar results outlive the much smaller parsed-root cache. Re-sorting a
/// stable capture therefore never requires retaining every JSON object graph.
package actor DerivedFieldCache {
    package static let shared = DerivedFieldCache()
    private struct Entry { let values: [String: String]; let cost: Int }
    private var entries: [JSONFieldCache.Key: Entry] = [:]
    private var order: [JSONFieldCache.Key?] = []
    private var slots: [JSONFieldCache.Key: Int] = [:]
    private var head = 0
    private var cost = 0
    private var generation: UInt64 = 0
    private let byteLimit: Int
    private let entryLimit: Int
    package init(byteLimit: Int = 8 * 1024 * 1024, entryLimit: Int = 50_000) {
        self.byteLimit = max(0, byteLimit); self.entryLimit = max(0, entryLimit)
    }
    package func lookup(_ key: JSONFieldCache.Key) -> (values: [String: String], generation: UInt64) {
        (entries[key]?.values ?? [:], generation)
    }
    package func store(_ values: [String: String], for key: JSONFieldCache.Key, generation expected: UInt64) {
        guard !Task.isCancelled, expected == generation else { return }
        let merged = (entries[key]?.values ?? [:]).merging(values) { _, new in new }
        guard merged.count <= 32 else { return }
        let charge = merged.reduce(key.estimatedCost) { $0 + $1.key.utf8.count + $1.value.utf8.count + 96 }
        guard charge <= byteLimit, entryLimit > 0 else { return }
        cost -= entries.removeValue(forKey: key)?.cost ?? 0
        // An entry gets one FIFO slot; updating it never grows the queue.
        while entries.count >= entryLimit || cost + charge > byteLimit {
            guard head < order.count else { break }
            if let old = order[head] { cost -= entries.removeValue(forKey: old)?.cost ?? 0; slots[old] = nil }
            order[head] = nil; head += 1
        }
        entries[key] = Entry(values: merged, cost: charge); cost += charge
        if slots[key] == nil { slots[key] = order.count; order.append(key) }
        if head > 1024 && head * 2 >= order.count {
            order.removeFirst(head); head = 0
            slots = Dictionary(uniqueKeysWithValues: order.enumerated().compactMap { index, key in key.map { ($0, index) } })
        }
    }
    package func clear() { generation &+= 1; entries.removeAll(); order.removeAll(); slots.removeAll(); head = 0; cost = 0 }
    package func statistics() -> (entries: Int, cost: Int) { (entries.count, cost) }
}
