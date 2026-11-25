import Foundation

/// GraphQL 操作名在捕获正文后才能确定，必须先筛操作名，再选择首条规则。
public enum ScriptMatchPolicy {
    public static func select<Entry>(_ entries: [Entry], operation: String?, stopAfterFirstMatch: Bool,
                                     ruleID: (Entry) -> UUID, requiredOperation: (Entry) -> String) -> [Entry] {
        let matching = entries.filter { requiredOperation($0).isEmpty || requiredOperation($0) == operation }
        guard stopAfterFirstMatch, let first = matching.first else { return matching }
        let selected = ruleID(first)
        return matching.filter { ruleID($0) == selected }
    }
}
