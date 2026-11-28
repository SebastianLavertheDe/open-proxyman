import Foundation
import ProxyMirrorFoundation
@testable import ProxyMirrorCore

@MainActor
func checkDerivedColumns(_ test: CoreAssertions) throws {
    func pump(until ready: () -> Bool, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !ready(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return ready()
    }
    let values = CustomColumnValues.shared
    values.clear()
    defer { values.clear() }
    let named = Transaction()
    named.path = "/graphql"; named.scheme = "https"
    named.requestHeaders = HTTPHeaders([("Content-Type", "application/json")])
    named.requestBody = Data(#"{"query":"query Actual { viewer { id } }","operationName":"FindUser","variables":{"id":1}}"#.utf8)
    named.requestBodyComplete = true
    let positive = TrafficCondition(field: .graphql, comparison: .equals, value: "FindUser").compileForPresentation()
    let negative = TrafficCondition(field: .graphql, comparison: .notEquals, value: "FindUser").compileForPresentation()
    test.expect(positive(named) == .pending && negative(named) == .pending, "Cold positive and negative GraphQL predicates remain pending")
    test.expect(pump { positive(named) != .pending && negative(named) != .pending }, "Derived GraphQL predicates complete")
    test.expect(positive(named) == .matched && negative(named) == .notMatched, "Both comparisons use the completed name")
    values.clear()
    test.expect(positive(named) == .matched && negative(named) == .notMatched, "Per-predicate Boolean memo survives global scalar cache eviction")
    let https = TrafficCondition(field: .scheme, comparison: .equals, value: "https").compileForPresentation()
    test.expect(https(named) == .matched && values.workCounts.retained == 0, "Known scheme comparison skips unnecessary GraphQL work")
    let nested = TrafficConditionGroup(mode: .all, conditions: [TrafficCondition(field: .method, comparison: .equals, value: "NO-SUCH-METHOD")],
        groups: [TrafficConditionGroup(conditions: [TrafficCondition(field: .graphql, comparison: .contains, value: "Actual")])]).compileForPresentation()
    test.expect(nested(named) == .notMatched && values.workCounts.retained == 0, "AND short circuits a definite false without scheduling metadata")

    named.requestBody = Data(#"{"query":"query Changed { id }"}"#.utf8)
    test.expect(positive(named) == .pending, "Body revision retires a previous predicate memo")
    test.expect(pump { positive(named) != .pending }, "Updated metadata completes")
    test.expect(positive(named) == .notMatched, "Old operation name cannot publish into a new body revision")

    values.clear()
    let many = (0..<2500).map { _ -> Transaction in
        let tx = Transaction(); tx.path = "/graphql"; tx.requestBodyComplete = true
        tx.requestBody = Data(#"{"query":"query Work { id }"}"#.utf8)
        return tx
    }
    for tx in many { _ = values.graphqlValue(for: tx) }
    test.expect(values.workCounts.active <= 4 && values.workCounts.retained <= 1024,
                "A cold 2500-row pass retains at most four active workers and 1024 weak queued requests")
    values.clear()
    _ = values.graphqlValue(for: many[0])
    test.expect(values.workCounts.active <= 4, "Memory pressure replacements wait for cancelled workers instead of overlapping them")
    test.expect(pump { if case .ready(let value) = values.graphqlState(for: many[0]) { return value == "Work" }; return false },
                "A replacement progresses after pressure cancellation")

    let directory = try makeCheckDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TrafficStore(sourceFolderFile: directory.appendingPathComponent("folders.json"), savedFile: directory.appendingPathComponent("saved.proxymirror"))
    let noName = Transaction(); noName.path = "/ordinary"; noName.requestBodyComplete = true
    noName.requestBody = Data(#"{"plain":true}"#.utf8)
    store.loadArchive([named, noName], name: "derived")
    store.filter.conditions = TrafficConditionGroup(conditions: [TrafficCondition(field: .graphql, comparison: .equals, value: "Changed")])
    test.expect(store.visible.count == 2 && store.filteringCapturedValues, "A cold filter retains provisional rows and reports progress")
    test.expect(pump { _ = store.visible; return !store.filteringCapturedValues }, "Store automatically refilters when metadata arrives")
    test.equal(store.visible.map(\.id), [named.id], "Final positive filter preserves exact matching semantics")
    store.filter.conditions = TrafficConditionGroup(conditions: [TrafficCondition(field: .graphql, comparison: .notEquals, value: "Changed")])
    test.expect(pump { _ = store.visible; return !store.filteringCapturedValues }, "Negative filter also settles")
    test.equal(store.visible.map(\.id), [noName.id], "Negative filter includes only the actual nonmatching rows")
}
