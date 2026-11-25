import XCTest
@testable import ProxyMirrorFoundation

final class RuleExecutionPolicyTests: XCTestCase {
    func testBlockStatusesAndDisconnect() throws {
        XCTAssertEqual(RuleBlockAction.forbidden.statusCode, 403)
        XCTAssertEqual(RuleBlockAction.serviceUnavailable.statusCode, 503)
        XCTAssertEqual(RuleBlockAction.tooManyRequests.statusCode, 429)
        XCTAssertNil(RuleBlockAction.disconnect.statusCode)
        for action in RuleBlockAction.allCases {
            XCTAssertEqual(try JSONDecoder().decode(RuleBlockAction.self, from: JSONEncoder().encode(action)), action)
        }
    }

    func testFirstMatchingRuleRetainsEveryActionAndFiltersGraphQLBeforeSelecting() {
        struct Entry {
            let rule: UUID
            let operation: String
            let action: String
        }
        let unrelated = UUID(), first = UUID(), second = UUID()
        let entries = [Entry(rule: unrelated, operation: "Other", action: "skip"),
                       Entry(rule: first, operation: "Users", action: "header"),
                       Entry(rule: first, operation: "Users", action: "script"),
                       Entry(rule: second, operation: "", action: "second")]
        let selected = ScriptMatchPolicy.select(entries, operation: "Users", stopAfterFirstMatch: true,
                                                ruleID: { $0.rule }, requiredOperation: { $0.operation })
        XCTAssertEqual(selected.map(\.action), ["header", "script"])
        let all = ScriptMatchPolicy.select(entries, operation: "Users", stopAfterFirstMatch: false,
                                           ruleID: { $0.rule }, requiredOperation: { $0.operation })
        XCTAssertEqual(all.map(\.action), ["header", "script", "second"])
        let unknown = ScriptMatchPolicy.select(entries, operation: nil, stopAfterFirstMatch: true,
                                               ruleID: { $0.rule }, requiredOperation: { $0.operation })
        XCTAssertEqual(unknown.map(\.action), ["second"])
    }
}
