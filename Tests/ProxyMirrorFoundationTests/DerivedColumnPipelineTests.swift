import XCTest
@testable import ProxyMirrorFoundation

final class DerivedColumnPipelineTests: XCTestCase {
    private func key(_ owner: UUID = UUID(), revision: UInt64 = 0) -> JSONFieldCache.Key {
        .init(owner: owner, revision: revision, request: true, encodings: [], complete: true, truncated: false)
    }

    func testScalarResultsSurviveRootEvictionAndShareMultiFieldParse() async {
        let roots = JSONFieldCache(byteLimit: 100_000, entryLimit: 2)
        let scalars = DerivedFieldCache(byteLimit: 1_000_000, entryLimit: 100)
        let keys = (0..<20).map { _ in key() }
        let body = Data(#"{"a":"one","b":"two"}"#.utf8)
        for _ in 0..<3 {
            for key in keys {
                let values = await roots.scalarValues(for: key, paths: ["a", "b"], scalars: scalars) { body }
                XCTAssertEqual(values["a"], "one"); XCTAssertEqual(values["b"], "two")
            }
        }
        let statistics = await roots.statistics
        XCTAssertEqual(statistics.parses, 20)
        XCTAssertLessThanOrEqual(statistics.entries, 2)
    }

    func testClearRejectsInFlightGenerationAndBoundsMetadata() async {
        let cache = DerivedFieldCache(byteLimit: 1500, entryLimit: 2)
        let key = key()
        let before = await cache.lookup(key)
        await cache.clear()
        await cache.store(["a": "old"], for: key, generation: before.generation)
        let cleared = await cache.lookup(key)
        XCTAssertNil(cleared.values["a"])
        for _ in 0..<100 {
            let current = keyForIteration()
            let ticket = await cache.lookup(current)
            await cache.store(["a": "new"], for: current, generation: ticket.generation)
        }
        let statistics = await cache.statistics()
        XCTAssertLessThanOrEqual(statistics.entries, 2); XCTAssertLessThanOrEqual(statistics.cost, 1500)
        let huge = JSONFieldCache.Key(owner: UUID(), revision: 0, request: true, encodings: [String(repeating: "x", count: 2000)], complete: true, truncated: false)
        let ticket = await cache.lookup(huge)
        await cache.store(["a": ""], for: huge, generation: ticket.generation)
        let result = await cache.lookup(huge)
        XCTAssertTrue(result.values.isEmpty)
    }
    private func keyForIteration() -> JSONFieldCache.Key { key() }

    func testContinuousUpdatesPublishStableKeysWithoutLosingRows() {
        let a = key(), b = key(), c = key(), added = key()
        let changedB = key(b.owner, revision: 1)
        let result = ColumnOrderPublication.reconcile(ordered: [c, b, a], current: [a, changedB, added, c])
        XCTAssertEqual(result.indices, [3, 0, 1, 2])
        XCTAssertEqual(result.orderedKeys, [c, a]); XCTAssertEqual(result.pendingCount, 2)
        let next = ColumnOrderPublication.reconcile(ordered: [added, changedB, c, a], current: [a, changedB, added, c])
        XCTAssertEqual(next.indices, [2, 1, 3, 0]); XCTAssertEqual(next.pendingCount, 0)
        let removed = ColumnOrderPublication.reconcile(ordered: next.orderedKeys, current: [a, added])
        XCTAssertEqual(removed.indices, [1, 0])
    }

    func testNestedPredicatesPreservePendingForPositiveAndNegativeFilters() {
        XCTAssertEqual(PresentationPredicateResult.all([.matched, .pending]), .pending)
        XCTAssertEqual(PresentationPredicateResult.all([.pending, .notMatched]), .notMatched)
        XCTAssertEqual(PresentationPredicateResult.any([.notMatched, .pending]), .pending)
        XCTAssertEqual(PresentationPredicateResult.any([.pending, .matched]), .matched)
        XCTAssertEqual(PresentationPredicateResult.all([]), .matched)
        XCTAssertEqual(PresentationPredicateResult.any([]), .notMatched)
        var calls = 0
        let lazy = [PresentationPredicateResult.notMatched, .pending].lazy.map { value in calls += 1; return value }
        XCTAssertEqual(PresentationPredicateResult.all(lazy), .notMatched); XCTAssertEqual(calls, 1)
    }

    func testMatchingNameIsNotTruncatedAndVariablesAreNotSerialized() {
        let name = String(repeating: "n", count: 3000)
        let variables = Dictionary(uniqueKeysWithValues: (0..<1500).map { ("key\($0)", String(repeating: "v", count: 60)) })
        let data = try! JSONSerialization.data(withJSONObject: ["query": "query Actual { viewer { id } }", "operationName": name, "variables": variables])
        XCTAssertEqual(GraphQLColumnValue.operationNameForMatching(path: "/graphql", query: "", contentType: "application/json", body: data), name)
        XCTAssertEqual(GraphQLColumnValue.operationName(path: "/graphql", query: "", contentType: "application/json", body: data).utf8.count, 2000)
    }
}
