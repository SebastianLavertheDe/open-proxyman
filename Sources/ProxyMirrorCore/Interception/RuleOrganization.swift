import Foundation

struct RuleFolder: Codable, Equatable, Identifiable {
    var id = UUID()
    var tool: String
    var name: String
    var parentID: UUID?
    var enabled: Bool?
}

struct RuleOrganization: Codable, Equatable {
    var folders: [RuleFolder] = []
    /// Keys are "tool:ruleID"; values are folder UUID strings.
    var assignments: [String: String] = [:]
    var disabledTools: [String] = []
    /// nil denotes the whole backup; single-tool exports explicitly scope their metadata.
    var includedTools: [String]?

    var validationError: String? {
        guard folders.count <= 2000, assignments.count <= 50_000,
              Set(folders.map(\.id)).count == folders.count else { return "规则文件夹数量过多或 ID 重复。" }
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        for folder in folders {
            guard !folder.tool.isEmpty, folder.tool.utf8.count <= 128,
                  !folder.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  folder.name.utf8.count <= 512 else { return "文件夹需要有效工具名和名称。" }
            var ancestor = folder.parentID
            var seen: Set<UUID> = [folder.id]
            while let id = ancestor {
                guard let parent = byID[id], parent.tool == folder.tool, seen.insert(id).inserted else {
                    return "文件夹父级不存在、跨工具或形成循环。"
                }
                ancestor = parent.parentID
                guard seen.count <= 32 else { return "文件夹最多嵌套 32 层。" }
            }
        }
        for (key, value) in assignments {
            guard let id = UUID(uuidString: value), let folder = byID[id], key.hasPrefix(folder.tool + ":") else {
                return "规则归属引用了无效文件夹。"
            }
        }
        guard disabledTools.count <= 128, disabledTools.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
            return "工具开关列表无效。"
        }
        if let includedTools {
            let scope = Set(includedTools)
            guard includedTools.count <= 128, includedTools.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
                  folders.allSatisfy({ scope.contains($0.tool) }), disabledTools.allSatisfy(scope.contains),
                  assignments.keys.allSatisfy({ key in scope.contains(String(key.split(separator: ":", maxSplits: 1).first ?? "")) }) else {
                return "备份工具范围无效或包含范围外的元数据。"
            }
        }
        return nil
    }

    var disabledRuleKeys: Set<String> {
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return Set(assignments.compactMap { key, assigned -> String? in
            var id = UUID(uuidString: assigned)
            var seen = Set<UUID>()
            while let current = id {
                guard seen.insert(current).inserted, let folder = byID[current], folder.enabled != false else { return key }
                id = folder.parentID
            }
            return nil
        })
    }

    func ruleIsEnabled(tool: String, ruleID: String) -> Bool {
        !disabledTools.contains(tool) && !disabledRuleKeys.contains(tool + ":" + ruleID)
    }

    func resolving(with current: RuleOrganization, merge: Bool) -> RuleOrganization {
        var result = current
        let scope = includedTools.map(Set.init)
        if !merge {
            if let scope {
                result.folders.removeAll { scope.contains($0.tool) }
                result.assignments = result.assignments.filter { key, _ in !scope.contains(String(key.split(separator: ":", maxSplits: 1).first ?? "")) }
                result.disabledTools.removeAll { scope.contains($0) }
            } else { return self }
        }
        for folder in folders {
            if let index = result.folders.firstIndex(where: { $0.id == folder.id }) { result.folders[index] = folder }
            else { result.folders.append(folder) }
        }
        result.assignments.merge(assignments, uniquingKeysWith: { _, incoming in incoming })
        if let scope { result.disabledTools.removeAll { scope.contains($0) } }
        result.disabledTools = Array(Set(result.disabledTools).union(disabledTools)).sorted()
        result.includedTools = nil
        return result
    }
}

extension Notification.Name {
    static let ruleOrganizationChanged = Notification.Name("ProxyMirror.ruleOrganizationChanged")
}

/// Folder membership and global switches never change the rules' individual enabled flags.
/// The engine reads immutable snapshots, and writes are persisted before publication.
final class RuleOrganizationStore: @unchecked Sendable {
    static let shared = RuleOrganizationStore()
    private let lock = NSLock()
    private let mutationLock = NSRecursiveLock()
    private var value: RuleOrganization
    private var disabledAssignments: Set<String>

    private init() {
        let consolidated: RuleBackup? = RulesFileIO.load("rules.json")
        let loaded = consolidated?.organization ?? RulesFileIO.load("rule-organization.json") ?? RuleOrganization()
        value = loaded.validationError == nil ? loaded : RuleOrganization()
        disabledAssignments = value.disabledRuleKeys
    }

    func snapshot() -> RuleOrganization {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func isEnabled(_ tool: String) -> Bool { !snapshot().disabledTools.contains(tool) }

    func ruleIsEnabled(tool: String, id: UUID) -> Bool { ruleIsEnabled(tool: tool, ruleID: id.uuidString) }

    func ruleIsEnabled(tool: String, ruleID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !value.disabledTools.contains(tool) && !disabledAssignments.contains(tool + ":" + ruleID)
    }

    func setFolderEnabled(id: UUID, enabled: Bool) throws {
        try mutate { state in
            guard let index = state.folders.firstIndex(where: { $0.id == id }) else { throw OrganizationError("文件夹不存在。") }
            state.folders[index].enabled = enabled
        }
    }
    func folders(tool: String) -> [RuleFolder] { snapshot().folders.filter { $0.tool == tool } }
    func folderID(ruleID: String, tool: String) -> UUID? {
        snapshot().assignments[tool + ":" + ruleID].flatMap(UUID.init(uuidString:))
    }

    func install(_ replacement: RuleOrganization) throws {
        try mutate { $0 = replacement }
    }

    func setEnabled(_ enabled: Bool, tool: String) throws {
        try mutate { state in
            state.disabledTools.removeAll { $0 == tool }
            if !enabled { state.disabledTools.append(tool) }
        }
    }

    @discardableResult
    func createFolder(tool: String, name: String, parentID: UUID? = nil) throws -> RuleFolder {
        let folder = RuleFolder(tool: tool, name: name.trimmingCharacters(in: .whitespacesAndNewlines), parentID: parentID, enabled: true)
        try mutate { $0.folders.append(folder) }
        return folder
    }

    func renameFolder(id: UUID, name: String) throws {
        try mutate { state in
            guard let index = state.folders.firstIndex(where: { $0.id == id }) else { throw OrganizationError("文件夹不存在。") }
            state.folders[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func moveFolder(id: UUID, parentID: UUID?) throws {
        try mutate { state in
            guard let index = state.folders.firstIndex(where: { $0.id == id }) else { throw OrganizationError("文件夹不存在。") }
            state.folders[index].parentID = parentID
        }
    }

    func deleteFolder(id: UUID) throws {
        try mutate { state in
            guard state.folders.contains(where: { $0.id == id }) else { throw OrganizationError("文件夹不存在。") }
            var deleted: Set<UUID> = [id]
            var previous = 0
            while deleted.count != previous {
                previous = deleted.count
                for folder in state.folders where folder.parentID.map(deleted.contains) == true { deleted.insert(folder.id) }
            }
            state.folders.removeAll { deleted.contains($0.id) }
            state.assignments = state.assignments.filter { _, folder in UUID(uuidString: folder).map(deleted.contains) != true }
        }
    }

    func assign(ruleID: String, tool: String, folderID: UUID?) throws {
        try mutate { state in
            guard !ruleID.isEmpty, ruleID.utf8.count <= 512 else { throw OrganizationError("规则 ID 无效。") }
            if let folderID {
                guard state.folders.contains(where: { $0.id == folderID && $0.tool == tool }) else {
                    throw OrganizationError("目标文件夹不存在或属于其他工具。")
                }
                state.assignments[tool + ":" + ruleID] = folderID.uuidString
            } else {
                state.assignments.removeValue(forKey: tool + ":" + ruleID)
            }
        }
    }

    /// Called only after RulesStore has atomically persisted the consolidated backup.
    /// No second file is written, so imports and regular edits have the same commit boundary.
    func updateSnapshot(_ replacement: RuleOrganization) {
        lock.lock()
        let changed = value != replacement
        value = replacement
        disabledAssignments = replacement.disabledRuleKeys
        lock.unlock()
        if changed { NotificationCenter.default.post(name: .ruleOrganizationChanged, object: nil) }
    }

    private func mutate(_ action: (inout RuleOrganization) throws -> Void) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        var replacement = snapshot()
        try action(&replacement)
        if let error = replacement.validationError { throw OrganizationError(error) }
        let store = RulesStore.shared
        var backup = store.backup()
        backup.organization = replacement
        try store.install(backup)
    }

    struct OrganizationError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
