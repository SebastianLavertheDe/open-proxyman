import Foundation

/// A local editor draft. It uses RuleOrganization's validation and execution semantics;
/// no change is published until the editor installs its complete rule backup.
struct RuleFolderEditingDraft: Equatable {
    private let base: RuleOrganization
    var organization: RuleOrganization

    init(_ source: RuleOrganization = RuleOrganizationStore.shared.snapshot()) {
        base = source; organization = source
    }
    var hasChanges: Bool { organization != base }

    func folders(tool: String) -> [RuleFolder] {
        organization.folders.filter { $0.tool == tool }.sorted {
            let left = path($0), right = path($1)
            return left == right ? $0.id.uuidString < $1.id.uuidString : left.localizedStandardCompare(right) == .orderedAscending
        }
    }
    func path(_ folder: RuleFolder) -> String {
        var names = [folder.name], parentID = folder.parentID, seen: Set<UUID> = [folder.id]
        while let id = parentID, seen.insert(id).inserted,
              let parent = organization.folders.first(where: { $0.id == id && $0.tool == folder.tool }) {
            names.insert(parent.name, at: 0); parentID = parent.parentID
        }
        return names.joined(separator: " / ")
    }
    func folderID(ruleID: String, tool: String) -> UUID? {
        organization.assignments[tool + ":" + ruleID].flatMap(UUID.init(uuidString:))
    }
    mutating func assign(ruleID: String, tool: String, folderID: UUID?) {
        organization.assignments[tool + ":" + ruleID] = folderID?.uuidString
    }

    @discardableResult
    mutating func createFolder(tool: String, name: String, parentID: UUID?) throws -> RuleFolder {
        let folder = RuleFolder(tool: tool, name: name.trimmingCharacters(in: .whitespacesAndNewlines), parentID: parentID, enabled: true)
        var candidate = organization
        candidate.folders.append(folder)
        if let issue = candidate.validationError { throw RuleOrganizationStore.OrganizationError(issue) }
        organization = candidate
        return folder
    }

    /// Apply only this editor's changes to the latest organization, preserving other
    /// windows' folder additions and tool switches. A deleted parent fails validation.
    func merging(into latest: RuleOrganization, tool: String, keeping ruleIDs: Set<String>) throws -> RuleOrganization {
        var result = latest
        let baseIDs = Set(base.folders.map(\.id))
        for folder in organization.folders where folder.tool == tool && !baseIDs.contains(folder.id) {
            if !result.folders.contains(where: { $0.id == folder.id }) { result.folders.append(folder) }
        }
        let prefix = tool + ":"
        result.assignments = result.assignments.filter { key, _ in
            !key.hasPrefix(prefix) || ruleIDs.contains(String(key.dropFirst(prefix.count)))
        }
        let keys = Set(base.assignments.keys).union(organization.assignments.keys)
        for key in keys where key.hasPrefix(prefix) && ruleIDs.contains(String(key.dropFirst(prefix.count))) {
            if base.assignments[key] != organization.assignments[key] { result.assignments[key] = organization.assignments[key] }
        }
        if let issue = result.validationError { throw RuleOrganizationStore.OrganizationError(issue) }
        return result
    }
}
