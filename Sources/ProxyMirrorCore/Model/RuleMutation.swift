import Foundation

/// Schema-aware rule labels and independent copies. Identity references such as
/// schemaID are preserved; every owned UUID field named id is regenerated.
enum RuleMutation {
    struct Copy {
        let rule: [String: Any]
        /// One source ID can appear in multiple owned nodes in an older rule.
        let identifiers: [String: [String]]
    }
    struct Failure: LocalizedError, OperationIssueProviding {
        let operationIssue: OperationIssue
        init(_ issue: OperationIssue) { operationIssue = issue }
        init(_ diagnostic: String) { operationIssue = .technical(diagnostic) }
        var errorDescription: String? { operationIssue.diagnostic }
    }

    private static let commentTools: Set<String> = ["mapLocal", "mapRemote", "blockList", "allowList", "sslProxyingList"]
    private static let nameTools: Set<String> = ["sslApplications", "customCertificates", "dns", "rewrite", "latency", "protobuf", "reverse"]

    static func rename(_ source: [String: Any], tool: String, nestedRewrite: Bool = false, name: String) throws -> [String: Any] {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.utf8.count <= 512,
              !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw Failure(OperationIssue.modelRuleNameInvalid)
        }
        var result = source
        if tool == "breakpoints" || tool == "rewrite" && nestedRewrite {
            guard var predicate = result["rule"] as? [String: Any] else { throw Failure(OperationIssue.modelRuleUrlMissing) }
            predicate["name"] = label
            result["rule"] = predicate
        } else if commentTools.contains(tool) { result["comment"] = label }
        else if nameTools.contains(tool) { result["name"] = label }
        else { throw Failure(OperationIssue.modelRuleRenameUnsupported) }
        return result
    }

    static func duplicate(_ source: [String: Any], tool: String, nestedRewrite: Bool = false,
                          name: String? = nil, bundleID: String? = nil,
                          makeID: () -> UUID = { UUID() }) throws -> Copy {
        var identifiers: [String: [String]] = [:]
        func clone(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                var result: [String: Any] = [:]
                for (key, child) in dictionary {
                    if key == "id", let old = child as? String, let uuid = UUID(uuidString: old) {
                        let fresh = makeID().uuidString
                        identifiers[uuid.uuidString, default: []].append(fresh)
                        result[key] = fresh
                    } else { result[key] = clone(child) }
                }
                return result
            }
            if let array = value as? [Any] { return array.map(clone) }
            return value
        }
        guard var result = clone(source) as? [String: Any] else { throw Failure(OperationIssue.modelRuleInvalid) }
        if tool == "sslApplications" {
            guard let raw = bundleID else { throw Failure(OperationIssue.modelSslCopyBundleRequired) }
            let newID = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let oldID = (source["bundleID"] as? String ?? "").lowercased()
            guard !newID.isEmpty, newID != oldID, newID.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else {
                throw Failure(OperationIssue.modelSslCopyBundleInvalid)
            }
            result["bundleID"] = newID
            identifiers[oldID] = [newID]
        } else {
            guard bundleID == nil, let oldID = source["id"] as? String, let uuid = UUID(uuidString: oldID),
                  let newID = result["id"] as? String, newID != uuid.uuidString else {
                throw Failure(OperationIssue.modelRuleCopyRequiresUuid)
            }
        }
        // A second active reverse listener cannot bind the original port.
        if tool == "reverse" { result["enabled"] = false }
        let label = name ?? Strings.Models.ruleCopyName(String(displayName(source, tool: tool, nestedRewrite: nestedRewrite).prefix(120)))
        result = try rename(result, tool: tool, nestedRewrite: nestedRewrite, name: label)
        return Copy(rule: result, identifiers: identifiers)
    }

    static func ownedIdentifiers(_ source: [String: Any]) -> Set<String> {
        var result = Set<String>()
        func visit(_ value: Any) {
            if let object = value as? [String: Any] {
                for (key, child) in object {
                    if key == "id", let text = child as? String, let uuid = UUID(uuidString: text) { result.insert(uuid.uuidString) }
                    else { visit(child) }
                }
            } else if let array = value as? [Any] { array.forEach(visit) }
        }
        visit(source)
        return result
    }

    private static func displayName(_ row: [String: Any], tool: String, nestedRewrite: Bool) -> String {
        if tool == "breakpoints" || tool == "rewrite" && nestedRewrite {
            let predicate = row["rule"] as? [String: Any] ?? [:]
            return (predicate["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Strings.Models.ruleDefaultName
        }
        let field = commentTools.contains(tool) ? "comment" : "name"
        return (row[field] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Strings.Models.ruleDefaultName
    }
}
