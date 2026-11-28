import Foundation

/// Immutable body identities cross the UI boundary; the cache never receives a
/// Transaction or other observable application state. One parse serves every
/// requested field and subsequent columns at the same body revision.
package actor JSONFieldCache {
    package static let shared = JSONFieldCache()
    package static let maximumInputBytes = 131_072
    package struct Key: Hashable, Sendable {
        package let owner: UUID
        package let revision: UInt64
        package let request: Bool
        package let encodings: [String]
        package let complete: Bool
        package let truncated: Bool
        package let context: [String]
        package init(owner: UUID, revision: UInt64, request: Bool, encodings: [String], complete: Bool, truncated: Bool,
                     context: [String] = []) {
            self.owner = owner; self.revision = revision; self.request = request
            self.encodings = encodings; self.complete = complete; self.truncated = truncated
            self.context = context
        }
        package var estimatedCost: Int { (encodings + context).reduce(256) { $0 + $1.utf8.count + 64 } }
    }
    package struct Statistics: Sendable {
        package let entries: Int
        package let cost: Int
        package let parses: Int
    }
    private struct Entry {
        let root: Any?
        var values: [String: String]
        var cost: Int
    }
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private var cost = 0
    private var parses = 0
    private let byteLimit: Int
    private let entryLimit: Int

    package init(byteLimit: Int = 16 * 1024 * 1024, entryLimit: Int = 256) {
        self.byteLimit = max(0, byteLimit); self.entryLimit = max(0, entryLimit)
    }

    package var statistics: Statistics { Statistics(entries: entries.count, cost: cost, parses: parses) }

    package func clear() { entries.removeAll(); order.removeAll(); cost = 0 }

    package func derivedValue(for key: Key, compute: @Sendable () -> String) -> String {
        guard !Task.isCancelled else { return "" }
        if let cached = entries[key]?.values[""] { return cached }
        let value = compute()
        guard !Task.isCancelled else { return "" }
        store(Entry(root: nil, values: ["": value], cost: key.estimatedCost + value.utf8.count + 128), for: key)
        return value
    }

    package func scalarValues(for key: Key, paths: [String], scalars: DerivedFieldCache = .shared,
                              load: @Sendable () -> Data?) async -> [String: String] {
        let cached = await scalars.lookup(key)
        let missing = paths.filter { cached.values[$0] == nil }
        guard !missing.isEmpty, !Task.isCancelled else { return cached.values }
        let resolved = values(for: key, paths: missing, load: load)
        await scalars.store(resolved, for: key, generation: cached.generation)
        return cached.values.merging(resolved) { _, new in new }
    }

    package func values(for key: Key, paths: [String], load: @Sendable () -> Data?) -> [String: String] {
        guard !Task.isCancelled else { return [:] }
        var entry: Entry
        if let cached = entries[key] { entry = cached }
        else {
            let data = load()
            guard !Task.isCancelled else { return [:] }
            let bounded = data.flatMap { $0.count <= Self.maximumInputBytes ? $0 : nil }
            let root = bounded.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
            parses += 1
            // Conservatively charge parsed Foundation objects as well as input
            // bytes. Both the entry count and total estimated storage are bounded.
            entry = Entry(root: root, values: [:], cost: (bounded?.count ?? 0) * 32 + key.estimatedCost)
        }
        var result: [String: String] = [:]
        for path in paths {
            guard !Task.isCancelled else { return [:] }
            if let cached = entry.values[path] { result[path] = cached; continue }
            let value = Self.value(path, in: entry.root)
            result[path] = value
            if entry.values.count < 32, path.utf8.count <= 8192 {
                entry.values[path] = value
                entry.cost += path.utf8.count + value.utf8.count + 128
            }
        }
        guard !Task.isCancelled else { return [:] }
        store(entry, for: key)
        return result
    }

    private func store(_ entry: Entry, for key: Key) {
        if let previous = entries.removeValue(forKey: key) { cost -= previous.cost }
        order.removeAll { $0 == key }
        if entry.cost <= byteLimit, entryLimit > 0 {
            while !order.isEmpty && (order.count >= entryLimit || cost + entry.cost > byteLimit) {
                let removed = order.removeFirst()
                cost -= entries.removeValue(forKey: removed)?.cost ?? 0
            }
            entries[key] = entry; order.append(key); cost += entry.cost
        }
    }

    private static func value(_ path: String, in root: Any?) -> String {
        var current = root
        for component in path.split(separator: ".") {
            if let object = current as? [String: Any] { current = object[String(component)] }
            else if let array = current as? [Any], let index = Int(component), array.indices.contains(index) { current = array[index] }
            else { return "" }
        }
        guard let current else { return "" }
        let text: String
        if let string = current as? String { text = String(string.prefix(500)) }
        else if let data = try? JSONSerialization.data(withJSONObject: current, options: [.fragmentsAllowed, .sortedKeys]) {
            text = String(decoding: data.prefix(500), as: UTF8.self)
        } else { return "" }
        return String(decoding: text.utf8.prefix(2000), as: UTF8.self)
    }
}
