import Foundation

package enum JSONColumnSort {
    package struct ValueInput: Sendable {
        package let sequence: Int
        package let resolve: @Sendable () async -> String
        package init(sequence: Int, resolve: @escaping @Sendable () async -> String) {
            self.sequence = sequence; self.resolve = resolve
        }
    }
    package struct Input: Sendable {
        package let key: JSONFieldCache.Key
        package let sequence: Int
        package let load: @Sendable () -> Data?
        package init(key: JSONFieldCache.Key, sequence: Int, load: @escaping @Sendable () -> Data?) {
            self.key = key; self.sequence = sequence; self.load = load
        }
    }
    /// The UI checks the complete request identity before publishing. A late
    /// worker cannot apply to another filter/order or to newer captured bytes.
    package struct Ticket: Sendable {
        private let generation: UUID
        private let keys: [JSONFieldCache.Key]
        package init(generation: UUID, keys: [JSONFieldCache.Key]) { self.generation = generation; self.keys = keys }
        package func isCurrent(generation: UUID, keys: [JSONFieldCache.Key]) -> Bool {
            !Task.isCancelled && self.generation == generation && self.keys == keys
        }
    }

    package static func indices(_ inputs: [Input], path: String, ascending: Bool,
                                cache: JSONFieldCache = .shared) async -> [Int]? {
        let values = inputs.map { input in
            ValueInput(sequence: input.sequence) {
                let values = await cache.values(for: input.key, paths: [path], load: input.load)
                return values[path] ?? ""
            }
        }
        return await indices(values: values, ascending: ascending)
    }

    package static func indices(values inputs: [ValueInput], ascending: Bool) async -> [Int]? {
        var keys: [(index: Int, sequence: Int, value: String)] = []
        keys.reserveCapacity(inputs.count)
        for (index, input) in inputs.enumerated() {
            guard !Task.isCancelled else { return nil }
            let value = await input.resolve()
            keys.append((index, input.sequence, value))
        }
        guard !Task.isCancelled else { return nil }
        let result = keys.sorted { lhs, rhs in
            let comparison = lhs.value.localizedStandardCompare(rhs.value)
            return comparison == .orderedSame ? lhs.sequence < rhs.sequence
                : (ascending ? comparison == .orderedAscending : comparison == .orderedDescending)
        }.map(\.index)
        return Task.isCancelled ? nil : result
    }
}
