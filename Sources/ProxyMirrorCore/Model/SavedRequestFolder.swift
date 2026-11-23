import Foundation

/// A container of saved request snapshots. This has no relationship to SourceFolder's host/app filters.
struct SavedRequestFolder: Codable, Sendable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var parentID: UUID?
}

struct SavedRequestFolderArchive: Codable, Sendable {
    var format = "proxymirror.saved-request-folders"
    static let currentVersion = 2
    var version = Self.currentVersion
    var folders: [SavedRequestFolder] = []
    var unfiled: [SessionRecord] = []
    var requestsByFolder: [String: [SessionRecord]] = [:]
    static let fileLimit = 512 * 1024 * 1024

    struct Failure: LocalizedError, OperationIssueProviding {
        let operationIssue: OperationIssue
        init(_ issue: OperationIssue) { operationIssue = issue }
        init(_ diagnostic: String) { operationIssue = .technical(diagnostic) }
        var errorDescription: String? { operationIssue.diagnostic }
        var message: String { operationIssue.diagnostic }
    }

    static func fileURL(for legacy: URL) -> URL {
        legacy.deletingPathExtension().appendingPathExtension("folders.json")
    }

    static func load(legacy: URL) throws -> (archive: Self, migrated: Bool) {
        let target = fileURL(for: legacy)
        if FileManager.default.fileExists(atPath: target.path) {
            let archive = try JSONDecoder().decode(Self.self, from: read(target))
            try archive.validate()
            return (archive, false)
        }
        guard FileManager.default.fileExists(atPath: legacy.path) else { return (Self(), false) }
        throw Failure(OperationIssue.modelSavedUnsupportedVersion)
    }

    static func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let next = try handle.read(upToCount: 65536), !next.isEmpty {
            guard data.count + next.count <= fileLimit else { throw Failure(OperationIssue.modelSavedReadLimit) }
            data.append(next)
        }
        return data
    }

    func write(to url: URL) throws {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.fileLimit else { throw Failure(OperationIssue.modelSavedWriteLimit) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PrivateAppFile.write(data, to: url)
    }

    func records(in folder: UUID?) -> [SessionRecord] {
        guard let folder else { return unfiled }
        return requestsByFolder[folder.uuidString] ?? requestsByFolder.first { UUID(uuidString: $0.key) == folder }?.value ?? []
    }

    mutating func setRecords(_ records: [SessionRecord], in folder: UUID?) {
        if let folder {
            requestsByFolder = requestsByFolder.filter { UUID(uuidString: $0.key) != folder }
            requestsByFolder[folder.uuidString] = records
        } else { unfiled = records }
    }

    func validate() throws {
        guard format == "proxymirror.saved-request-folders", version == Self.currentVersion, folders.count <= 2000,
              Set(folders.map(\.id)).count == folders.count else { throw Failure(OperationIssue.modelSavedFormatInvalid) }
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var names = Set<String>()
        for folder in folders {
            let name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.utf8.count <= 512,
                  names.insert((folder.parentID?.uuidString ?? "root") + ":" + name.lowercased()).inserted else {
                throw Failure(OperationIssue.modelSavedNameInvalid)
            }
            var parent = folder.parentID
            var seen: Set<UUID> = [folder.id]
            while let id = parent {
                guard let ancestor = byID[id], seen.insert(id).inserted, seen.count <= 32 else {
                    throw Failure(OperationIssue.modelSavedParentInvalid)
                }
                parent = ancestor.parentID
            }
        }
        var buckets = Set<UUID>()
        for key in requestsByFolder.keys {
            guard let id = UUID(uuidString: key), byID[id] != nil, buckets.insert(id).inserted else {
                throw Failure(OperationIssue.modelSavedBucketInvalid)
            }
        }
        for records in [unfiled] + Array(requestsByFolder.values) {
            guard Set(records.map(\.id)).count == records.count else { throw Failure(OperationIssue.modelSavedFolderDuplicateRequest) }
        }
        let allIDs = unfiled.map(\.id) + requestsByFolder.values.flatMap { $0.map(\.id) }
        guard Set(allIDs).count == allIDs.count else { throw Failure(OperationIssue.modelSavedDuplicateSnapshot) }
    }

    @discardableResult
    mutating func create(name: String, parentID: UUID? = nil) throws -> UUID {
        let folder = SavedRequestFolder(name: name.trimmingCharacters(in: .whitespacesAndNewlines), parentID: parentID)
        try committing { $0.folders.append(folder) }
        return folder.id
    }

    mutating func rename(_ id: UUID, name: String) throws {
        try committing { next in
            guard let index = next.folders.firstIndex(where: { $0.id == id }) else { throw Failure(OperationIssue.modelSavedFolderMissing) }
            next.folders[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    mutating func moveFolder(_ id: UUID, parentID: UUID?) throws {
        try committing { next in
            guard let index = next.folders.firstIndex(where: { $0.id == id }) else { throw Failure(OperationIssue.modelSavedFolderMissing) }
            next.folders[index].parentID = parentID
        }
    }

    /// Deleting containers moves every snapshot in the subtree back to Unfiled; no request is discarded.
    mutating func deletePreservingRequests(_ id: UUID) throws {
        try committing { next in
            guard next.folders.contains(where: { $0.id == id }) else { throw Failure(OperationIssue.modelSavedFolderMissing) }
            var removing: Set<UUID> = [id]
            var previous = 0
            while removing.count != previous {
                previous = removing.count
                for folder in next.folders where folder.parentID.map(removing.contains) == true { removing.insert(folder.id) }
            }
            for folder in next.folders where removing.contains(folder.id) {
                next.unfiled = try Self.appendPreserving(next.records(in: folder.id), to: next.unfiled)
                next.requestsByFolder = next.requestsByFolder.filter { UUID(uuidString: $0.key) != folder.id }
            }
            next.folders.removeAll { removing.contains($0.id) }
        }
    }

    mutating func add(_ snapshots: [SessionRecord], to destination: UUID?) throws {
        try committing { next in
            try next.requireFolder(destination)
            let all = next.unfiled + next.requestsByFolder.values.flatMap { $0 }
            let incoming = try Self.appendPreserving(snapshots, to: all).suffix(snapshots.count)
            next.setRecords(next.records(in: destination) + Array(incoming), in: destination)
        }
    }

    mutating func transfer(ids: Set<UUID>, from source: UUID?, to destination: UUID?, copy: Bool) throws {
        try committing { next in
            try next.requireFolder(source); try next.requireFolder(destination)
            guard source != destination else { return }
            let sourceRecords = next.records(in: source)
            let moving = sourceRecords.filter { ids.contains($0.id) }
            guard moving.count == ids.count else { throw Failure(OperationIssue.modelSavedSelectionMissing) }
            if !copy { next.setRecords(sourceRecords.filter { !ids.contains($0.id) }, in: source) }
            try next.add(moving, to: destination)
        }
    }

    /// All mutations validate a value copy first. Failed names, cycles or missing requests leave self unchanged.
    private mutating func committing(_ mutation: (inout Self) throws -> Void) throws {
        var next = self
        try mutation(&next)
        try next.validate()
        self = next
    }

    private func requireFolder(_ id: UUID?) throws {
        if let id, !folders.contains(where: { $0.id == id }) { throw Failure(OperationIssue.modelSavedTargetMissing) }
    }

    /// A collision represents two independently edited snapshots: keep both, assigning the incoming copy a new ID.
    private static func appendPreserving(_ incoming: [SessionRecord], to existing: [SessionRecord]) throws -> [SessionRecord] {
        var ids = Set(existing.map(\.id))
        var result = existing
        for record in incoming {
            var value = record
            if !ids.insert(value.id).inserted {
                guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any] else {
                    throw Failure(OperationIssue.modelSavedCopyFailed)
                }
                object["id"] = UUID().uuidString
                value = try JSONDecoder().decode(SessionRecord.self, from: JSONSerialization.data(withJSONObject: object))
                ids.insert(value.id)
            }
            result.append(value)
        }
        return result
    }
}
