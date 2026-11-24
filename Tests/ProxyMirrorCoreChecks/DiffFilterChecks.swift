import Foundation
@testable import ProxyMirrorCore

@MainActor
func checkDiffAndFilters(_ test: CoreAssertions) throws {
    try checkSavedRequestFolders(test)
    checkFilterPanelShortcuts(test)
    let tx = Transaction()
    tx.host = "api.example.test"
    tx.path = "/v1/items"
    tx.method = "POST"
    tx.requestHeaders = HTTPHeaders([("X-One", "allowed"), ("X-Two", "secret")])
    tx.responseHeaders = HTTPHeaders([("Z-Header", "last"), ("A-Header", "first")])
    tx.responseBody = Data("{\"z\":2,\"a\":1}".utf8)
    tx.responseBodyComplete = true
    tx.statusCode = 201
    tx.state = .completed
    tx.duration = 0.125
    tx.comment = "fixture note"
    tx.requestBytes = 64
    tx.responseBytes = 128

    test.expect(TrafficCondition(field: .host, comparison: .wildcard, value: "*.example.test").compile()(tx),
                "Host wildcard matches a complete field")
    test.expect(!TrafficCondition(field: .host, comparison: .wildcard, value: "*.example").compile()(tx),
                "Wildcard matching remains anchored")
    test.expect(!TrafficCondition(field: .host, comparison: .wildcard, value: "*.exampleXtest").compile()(tx),
                "Wildcard preserves literal punctuation")
    test.expect(!TrafficCondition(field: .requestHeader, comparison: .notContains, value: "secret").compile()(tx),
                "Negative header comparison negates the entire header set")
    test.expect(TrafficCondition(field: .requestHeader, comparison: .notContains, value: "missing").compile()(tx),
                "Negative header comparison accepts a value absent from every header")
    test.expect(TrafficCondition(field: .comment, comparison: .startsWith, value: "FIXTURE").compile()(tx),
                "Prefix comparison is case-insensitive")
    test.expect(TrafficCondition(field: .duration, comparison: .between, value: "100...125").compile()(tx),
                "Duration range includes both bounds and uses milliseconds")
    test.expect(TrafficCondition(field: .responseSize, comparison: .greaterThan, value: "127").compile()(tx),
                "Size filters compare byte counts numerically")
    test.expect(!TrafficCondition(field: .status, comparison: .between, value: "500...200").isValid,
                "Reversed ranges are rejected")
    test.expect(!TrafficCondition(field: .status, comparison: .atLeast, value: "inf").isValid,
                "Non-finite numeric thresholds are rejected")
    test.expect(!TrafficCondition(field: .host, comparison: .atLeast, value: "1").isValid,
                "Numeric operations reject nonnumeric fields")
    test.expect(!TrafficCondition(field: .url, comparison: .notRegex, value: "[").compile()(tx),
                "Invalid negative regex fails closed")
    let normalRegex = TrafficCondition(field: .host, comparison: .regex, value: #"^API\.EXAMPLE\.TEST$"#).compile()
    test.expect(normalRegex(tx), "Bounded regular expressions preserve case-insensitive matching")
    let previousComment = tx.comment
    tx.comment = String(repeating: "a", count: 48) + "!"
    let startedRegex = ProcessInfo.processInfo.systemUptime
    let limitedRegex = TrafficCondition(field: .comment, comparison: .regex, value: "(a+)+$").compile()
    let limitedNegative = TrafficCondition(field: .comment, comparison: .notRegex, value: "(a+)+$").compile()
    test.expect(!limitedRegex(tx) && !limitedNegative(tx), "Budget exhaustion fails closed for positive and negative regex filters")
    test.expect(ProcessInfo.processInfo.systemUptime - startedRegex < 0.5, "Catastrophic backtracking is interrupted within the matching budget")
    tx.comment = "a"
    test.expect(!limitedRegex(tx) && !limitedNegative(tx), "An exhausted compiled rule cannot repeatedly consume its budget")
    tx.comment = previousComment
    let nested = TrafficConditionGroup(mode: .all, conditions: [TrafficCondition(field: .method, comparison: .equals, value: "POST")],
        groups: [TrafficConditionGroup(mode: .any, conditions: [
            TrafficCondition(field: .status, comparison: .equals, value: "404"),
            TrafficCondition(field: .status, comparison: .between, value: "200...299")])])
    test.expect(nested.compile()(tx), "Nested OR evaluates within its parent AND")
    tx.method = "GET"
    test.expect(!nested.compile()(tx), "Parent AND remains effective around nested OR")
    let minimal = Data(#"{"name":"Minimal","id":"00000000-0000-0000-0000-000000000001","group":{"mode":"all","conditions":[]}}"#.utf8)
    let decoded = try JSONDecoder().decode(SavedTrafficFilter.self, from: minimal)
    test.expect(decoded.highlightName == nil && decoded.group.groups == nil, "Saved filters decode without optional fields using stable storage IDs")
    let obsoleteMode = Data(#""全部匹配 (AND)""#.utf8)
    test.expect((try? JSONDecoder().decode(TrafficConditionGroup.Mode.self, from: obsoleteMode)) == nil,
                "Obsolete localized mode IDs are rejected")

    let reordered = Transaction()
    reordered.responseHeaders = HTTPHeaders([("A-Header", "first"), ("Z-Header", "last")])
    reordered.responseBody = Data("{\"a\":1,\"z\":2}".utf8)
    reordered.responseBodyComplete = true
    let body1 = TrafficDiffDocument.lines(tx, component: .responseBody, sortJSON: true, sortHeaders: true)
    let body2 = TrafficDiffDocument.lines(reordered, component: .responseBody, sortJSON: true, sortHeaders: true)
    test.equal(body1, body2, "Sorted JSON comparison ignores key order")
    test.equal(TrafficDiffDocument.lines(tx, component: .responseHeaders, sortJSON: true, sortHeaders: true),
               TrafficDiffDocument.lines(reordered, component: .responseHeaders, sortJSON: true, sortHeaders: true),
               "Header sorting removes header-order-only differences")
    test.equal(TrafficDiffDocument.lines(tx, component: .requestHeaders, sortJSON: false, sortHeaders: false),
               ["X-One: allowed", "X-Two: secret"], "Request header comparison uses request data")
    let diff = TrafficDiffDocument.compare(["same", "old", "tail"], ["same", "new", "tail", "added"])
    test.equal(diff.removed, 1, "Diff counts deleted lines")
    test.equal(diff.inserted, 2, "Diff counts inserted and trailing lines")
    test.equal(diff.unified.filter { $0.change != .inserted }.map(\.text), ["same", "old", "tail"],
               "Removing inserted lines reconstructs the left document")
    test.equal(diff.unified.filter { $0.change != .removed }.map(\.text), ["same", "new", "tail", "added"],
               "Removing deleted lines reconstructs the right document")
    test.equal(diff.pairs.compactMap(\.left), ["same", "old", "tail"], "Side-by-side alignment preserves every left line")
    test.equal(diff.pairs.compactMap(\.right), ["same", "new", "tail", "added"], "Side-by-side alignment preserves every right line")
    test.equal(TrafficDiffDocument.compare([], ["new"]).pairs.compactMap(\.right), ["new"], "Diff handles an empty left side")

    let suite = "ProxyMirror-FilterChecks-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let profiles = [SavedTrafficFilter(name: "errors", group: TrafficConditionGroup(conditions: [
        TrafficCondition(field: .status, comparison: .atLeast, value: "400")]), highlightName: "Red"),
        SavedTrafficFilter(name: "fixture", group: TrafficConditionGroup(conditions: [
            TrafficCondition(field: .host, comparison: .equals, value: "api.example.test")]), highlightName: "Blue")]
    defaults.set(try JSONEncoder().encode(profiles), forKey: SavedTrafficFilter.defaultsKey)
    let palette = TrafficFilterPalette(defaults: defaults)
    test.equal(palette.highlight(for: tx), "Blue", "Saved coloring profiles evaluate their real predicates")
    tx.statusCode = 500
    test.equal(palette.highlight(for: tx), "Red", "The first matching saved color has precedence")
    test.expect(tx.highlightName == nil, "Filter coloring never mutates manual session highlights")
    let limitedProfiles = [SavedTrafficFilter(name: "limited", group: TrafficConditionGroup(conditions: [
        TrafficCondition(field: .comment, comparison: .notRegex, value: "(a+)+$")]), highlightName: "Red")]
    defaults.set(try JSONEncoder().encode(limitedProfiles), forKey: SavedTrafficFilter.defaultsKey)
    let limitedPalette = TrafficFilterPalette(defaults: defaults)
    tx.comment = String(repeating: "a", count: 48) + "!"
    test.expect(limitedPalette.highlight(for: tx) == nil, "Saved coloring uses the same fail-closed regex budget")
    tx.comment = previousComment
}
