import Foundation
@testable import ProxyMirrorCore

func checkRuleMutations(_ test: CoreAssertions) throws {
    let id = UUID().uuidString
    let classic: [String: Any] = ["id": id, "enabled": true, "pattern": "https://api.test/*", "target": "", "comment": "Original"]
    let renamed = try RuleMutation.rename(classic, tool: "blockList", name: "New label")
    test.equal(renamed["comment"] as? String, "New label", "Classic rename writes its comment label")
    test.equal(renamed["pattern"] as? String, classic["pattern"] as? String, "Rename preserves the URL match")
    test.expect(renamed["name"] == nil, "Classic rename does not add an unsupported name field")
    let copied = try RuleMutation.duplicate(classic, tool: "blockList")
    test.expect(copied.rule["id"] as? String != id, "Classic duplicate receives a new identity")
    test.equal(copied.identifiers[id]?.count, 1, "Duplicate reports membership identity mapping")

    let predicate = URLRule(name: "Original predicate", host: "api.test")
    let child = RewriteRule(rule: predicate)
    let group = RewriteRuleSet(name: "Group", rules: [child])
    let groupObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(group)) as! [String: Any]
    let groupCopy = try RuleMutation.duplicate(groupObject, tool: "rewrite")
    let oldIDs = RuleMutation.ownedIdentifiers(groupObject)
    let newIDs = RuleMutation.ownedIdentifiers(groupCopy.rule)
    test.equal(oldIDs.count, 3, "Rewrite group owns group, child and predicate identities")
    test.equal(newIDs.count, oldIDs.count, "Rewrite duplicate retains the complete hierarchy")
    test.expect(oldIDs.isDisjoint(with: newIDs), "Every nested rewrite identity is regenerated")
    let nested = (groupObject["rules"] as! [[String: Any]])[0]
    let childRename = try RuleMutation.rename(nested, tool: "rewrite", nestedRewrite: true, name: "Child label")
    test.equal((childRename["rule"] as? [String: Any])?["name"] as? String, "Child label", "Nested rewrite rename writes URLRule.name")
    test.equal((childRename["rule"] as? [String: Any])?["host"] as? String, "api.test", "Nested rewrite rename preserves its host")
    let breakpoint = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BreakpointRule(rule: predicate))) as! [String: Any]
    let breakpointCopy = try RuleMutation.duplicate(breakpoint, tool: "breakpoints")
    test.expect(RuleMutation.ownedIdentifiers(breakpoint).isDisjoint(with: RuleMutation.ownedIdentifiers(breakpointCopy.rule)), "Breakpoint duplicate also regenerates its URL predicate ID")
    let reverse: [String: Any] = ["id": UUID().uuidString, "name": "Route", "enabled": true, "listenPort": 10000]
    test.equal(try RuleMutation.duplicate(reverse, tool: "reverse").rule["enabled"] as? Bool, false, "Reverse duplicate starts disabled to avoid a duplicate listener port")
    let application: [String: Any] = ["bundleID": "com.example.source", "name": "App", "enabled": true, "action": "decrypt"]
    test.rejects(try RuleMutation.duplicate(application, tool: "sslApplications"), with: RuleMutation.Failure.self, "Application copy requires a new bundle identity")
    let applicationCopy = try RuleMutation.duplicate(application, tool: "sslApplications", bundleID: "com.example.target")
    test.equal(applicationCopy.rule["bundleID"] as? String, "com.example.target", "Application duplicate uses the requested new bundle identity")
    test.rejects(try RuleMutation.rename(classic, tool: "blockList", name: "\n"), with: RuleMutation.Failure.self, "Empty labels are rejected")
}
