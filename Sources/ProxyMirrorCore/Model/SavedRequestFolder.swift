import Foundation

/// A container of saved request snapshots. This has no relationship to SourceFolder's host/app filters.
struct SavedRequestFolder: Codable, Sendable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var parentID: UUID?
}

struct SavedRequestFolderArchive: Codable, Sendable {
    var format = "proxymirror.saved-request-folders"
    var version = 1
    var folders: [SavedRequestFolder] = []
    var unfiled: [SessionRecord] = []
    var requestsByFolder: [String: [SessionRecord]] = [:]
    static let fileLimit = 512 * 1024 * 1024

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
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
        let old = try JSONDecoder().decode(LegacySavedFile.self, from: read(legacy))
        guard old.version == 1 else { throw Failure("旧 Saved 请求文件版本不受支持，原文件未修改。") }
        let records = old.records
        var archive = Self()
        archive.unfiled = try appendPreserving(records, to: [])
        try archive.validate()
        // The original legacy file is retained verbatim, including on a failed migration write.
        return (archive, true)
    }

    /// The legacy Saved file is the native v1 session wire format. Decode only its snapshot payload;
    /// a SourceFolders.json (which has no records field) can never enter this migration path.
    private struct LegacySavedFile: Decodable {
        let version: Int
        let records: [SessionRecord]
    }

    static func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let next = try handle.read(upToCount: 65536), !next.isEmpty {
            guard data.count + next.count <= fileLimit else { throw Failure("Saved 请求库超过 512 MiB。原文件未修改。") }
            data.append(next)
        }
        return data
    }

    func write(to url: URL) throws {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.fileLimit else { throw Failure("Saved 请求库超过 512 MiB，未覆盖原文件。") }
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
        guard format == "proxymirror.saved-request-folders", version == 1, folders.count <= 2000,
              Set(folders.map(\.id)).count == folders.count else { throw Failure("Saved 请求文件夹格式或版本无效。") }
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var names = Set<String>()
        for folder in folders {
            let name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.utf8.count <= 512,
                  names.insert((folder.parentID?.uuidString ?? "root") + ":" + name.lowercased()).inserted else {
                throw Failure("Saved 文件夹名称不能为空、超过 512 字节或与同级文件夹重名。")
            }
            var parent = folder.parentID
            var seen: Set<UUID> = [folder.id]
            while let id = parent {
                guard let ancestor = byID[id], seen.insert(id).inserted, seen.count <= 32 else {
                    throw Failure("Saved 文件夹父级不存在、形成循环或超过 32 层。")
                }
                parent = ancestor.parentID
            }
        }
        var buckets = Set<UUID>()
        for key in requestsByFolder.keys {
            guard let id = UUID(uuidString: key), byID[id] != nil, buckets.insert(id).inserted else {
                throw Failure("Saved 请求引用了不存在的文件夹，或同一文件夹存在重复记录桶。")
            }
        }
        for records in [unfiled] + Array(requestsByFolder.values) {
            guard Set(records.map(\.id)).count == records.count else { throw Failure("同一 Saved 文件夹内有重复请求 ID。") }
        }
        let allIDs = unfiled.map(\.id) + requestsByFolder.values.flatMap { $0.map(\.id) }
        guard Set(allIDs).count == allIDs.count else { throw Failure("Saved 请求库有重复快照 ID。") }
    }

    @discardableResult
    mutating func create(name: String, parentID: UUID? = nil) throws -> UUID {
        let folder = SavedRequestFolder(name: name.trimmingCharacters(in: .whitespacesAndNewlines), parentID: parentID)
        try committing { $0.folders.append(folder) }
        return folder.id
    }

    mutating func rename(_ id: UUID, name: String) throws {
        try committing { next in
            guard let index = next.folders.firstIndex(where: { $0.id == id }) else { throw Failure("Saved 文件夹不存在。") }
            next.folders[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    mutating func moveFolder(_ id: UUID, parentID: UUID?) throws {
        try committing { next in
            guard let index = next.folders.firstIndex(where: { $0.id == id }) else { throw Failure("Saved 文件夹不存在。") }
            next.folders[index].parentID = parentID
        }
    }

    /// Deleting containers moves every snapshot in the subtree back to Unfiled; no request is discarded.
    mutating func deletePreservingRequests(_ id: UUID) throws {
        try committing { next in
            guard next.folders.contains(where: { $0.id == id }) else { throw Failure("Saved 文件夹不存在。") }
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
            guard moving.count == ids.count else { throw Failure("部分所选 Saved 请求已不存在，请刷新后重试。") }
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
        if let id, !folders.contains(where: { $0.id == id }) { throw Failure("目标 Saved 文件夹不存在。") }
    }

    /// A collision represents two independently edited snapshots: keep both, assigning the incoming copy a new ID.
    private static func appendPreserving(_ incoming: [SessionRecord], to existing: [SessionRecord]) throws -> [SessionRecord] {
        var ids = Set(existing.map(\.id))
        var result = existing
        for record in incoming {
            var value = record
            if !ids.insert(value.id).inserted {
                guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any] else {
                    throw Failure("无法复制 Saved 请求快照。")
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
