#!/usr/bin/env python3
"""Compile and execute the actual SavedRequestFolderArchive Swift source on Linux.

Only the unrelated SessionRecord payload and private-file writer are tiny test
boundaries. The archive's version checks, ID collision handling, hierarchy, validation,
copy/move/delete and rollback code is compiled verbatim from the repository.
This is not a macOS UI, TrafficStore, or SessionFile integration test.
"""
import argparse
import os
from pathlib import Path
from localization_model_test_support import localization_sources
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BOUNDARIES = r'''
import Foundation
struct SessionRecord: Codable, Sendable, Equatable {
    let id: UUID
    let host: String
    let body: Data
    let comment: String
    let startedAt: Date
}
enum PrivateAppFile {
    static func write(_ data: Data, to target: URL) throws {
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}
'''
HARNESS = r'''
import Foundation
@main struct SavedModelChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pm-saved-native-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var checks = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { fatalError(message) }; checks += 1
        }
        func rejects(_ message: String, _ operation: () throws -> Void) {
            do { try operation(); fatalError(message) } catch { checks += 1 }
        }
        func bytes(_ archive: SavedRequestFolderArchive) throws -> Data {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(archive)
        }
        struct Legacy: Encodable { let version = 1; let records: [SessionRecord] }
        let first = SessionRecord(id: UUID(), host: "one.saved.test", body: Data([0, 1, 255]), comment: "retain metadata", startedAt: Date(timeIntervalSince1970: 100))
        let second = SessionRecord(id: UUID(), host: "two.saved.test", body: Data("payload".utf8), comment: "second", startedAt: Date(timeIntervalSince1970: 200))
        let legacy = directory.appendingPathComponent("Saved.proxymirror")
        let original = try JSONEncoder().encode(Legacy(records: [first, second]))
        try original.write(to: legacy)
        rejects("obsolete native Saved file accepted") { _ = try SavedRequestFolderArchive.load(legacy: legacy) }
        let canonical = SavedRequestFolderArchive.fileURL(for: legacy)
        var seed = SavedRequestFolderArchive()
        seed.unfiled = [first, second]
        try seed.write(to: canonical)
        var loaded = try SavedRequestFolderArchive.load(legacy: legacy)
        try expect(!loaded.migrated && loaded.archive.unfiled == [first, second], "new-format load lost snapshots")
        try expect(Data(contentsOf: legacy) == original, "new archive load touched an unrelated file")
        let parent = try loaded.archive.create(name: "接口")
        let child = try loaded.archive.create(name: "子文件夹", parentID: parent)
        try expect(loaded.archive.folders.first { $0.id == child }?.parentID == parent, "hierarchy was not stored")
        let before = try bytes(loaded.archive)
        rejects("cycle accepted") { try loaded.archive.moveFolder(parent, parentID: child) }
        try expect(bytes(loaded.archive) == before, "cycle failure mutated archive")
        rejects("duplicate name accepted") { _ = try loaded.archive.create(name: "接口") }
        try expect(bytes(loaded.archive) == before, "duplicate name failure mutated archive")
        rejects("unknown destination accepted") { try loaded.archive.transfer(ids: [first.id], from: nil, to: UUID(), copy: false) }
        try expect(bytes(loaded.archive) == before, "invalid destination partially removed the source request")
        try loaded.archive.transfer(ids: [first.id], from: nil, to: parent, copy: false)
        try expect(loaded.archive.unfiled == [second] && loaded.archive.records(in: parent) == [first], "move did not retain identity and content")
        try loaded.archive.transfer(ids: [first.id], from: parent, to: child, copy: true)
        let copy = loaded.archive.records(in: child)[0]
        try expect(copy.id != first.id && copy.host == first.host && copy.body == first.body && copy.comment == first.comment && copy.startedAt == first.startedAt,
                   "copy collision did not preserve complete payload with independent ID")
        try expect(loaded.archive.records(in: parent) == [first], "copy removed the source snapshot")
        try loaded.archive.rename(parent, name: "已重命名")
        try expect(loaded.archive.folders.first { $0.id == parent }?.name == "已重命名", "rename failed")
        try loaded.archive.moveFolder(child, parentID: nil)
        try expect(loaded.archive.folders.first { $0.id == child }?.parentID == nil, "folder reparent failed")
        try loaded.archive.moveFolder(child, parentID: parent)
        let moveBefore = try bytes(loaded.archive)
        rejects("missing request accepted") { try loaded.archive.transfer(ids: [UUID()], from: parent, to: child, copy: false) }
        try expect(bytes(loaded.archive) == moveBefore, "missing request failure mutated source or destination")
        try loaded.archive.write(to: canonical)
        let reloaded = try SavedRequestFolderArchive.load(legacy: legacy)
        try expect(!reloaded.migrated && reloaded.archive.records(in: child) == [copy], "canonical reload did not restore nested snapshot")
        try loaded.archive.deletePreservingRequests(parent)
        try expect(loaded.archive.folders.isEmpty && loaded.archive.unfiled.count == 3, "subtree deletion dropped requests")
        try expect(Set(loaded.archive.unfiled.map(\.id)).count == 3, "subtree deletion collapsed independent snapshots")
        try loaded.archive.write(to: canonical)
        try expect(Data(contentsOf: legacy) == original, "mutations changed the original legacy file")
        let source = directory.appendingPathComponent("SourceFolders.json")
        let sourceBytes = Data(#"{"version":1,"folders":[{"id":"11111111-1111-1111-1111-111111111111","name":"来源","members":[]}]}"#.utf8)
        try sourceBytes.write(to: source)
        try loaded.archive.write(to: canonical)
        try expect(Data(contentsOf: source) == sourceBytes, "saved mutation touched source-folder storage")
        let badLegacy = directory.appendingPathComponent("Wrong.proxymirror")
        try sourceBytes.write(to: badLegacy)
        rejects("source folders misread as legacy saved requests") { _ = try SavedRequestFolderArchive.load(legacy: badLegacy) }
        try expect(Data(contentsOf: badLegacy) == sourceBytes, "rejected migration modified source file")
        try sourceBytes.write(to: SavedRequestFolderArchive.fileURL(for: badLegacy))
        rejects("source folders misread as canonical request archive") { _ = try SavedRequestFolderArchive.load(legacy: badLegacy) }
        var duplicateArchive = SavedRequestFolderArchive()
        duplicateArchive.unfiled = [first, first]
        rejects("duplicate snapshot IDs accepted") { try duplicateArchive.validate() }
        var obsolete = loaded.archive
        obsolete.version = 1
        rejects("obsolete folder archive accepted") { try obsolete.validate() }
        print("PASS: \(checks) actual Swift Saved archive checks; no macOS UI or TrafficStore runtime executed")
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default=os.environ.get("PM_SWIFTC") or shutil.which("swiftc"))
    args = parser.parse_args()
    if not args.swiftc:
        parser.error("set PM_SWIFTC or pass --swiftc to a Swift compiler")
    with tempfile.TemporaryDirectory(prefix="pm-saved-models-") as temporary:
        work = Path(temporary)
        (work / "Boundaries.swift").write_text(BOUNDARIES)
        (work / "Harness.swift").write_text(HARNESS)
        executable = work / "saved-checks"
        subprocess.run([args.swiftc, "-swift-version", "5", str(ROOT / "Sources/ProxyMirrorCore/Model/SavedRequestFolder.swift"),
                        str(work / "Boundaries.swift"), str(work / "Harness.swift"), *localization_sources(work), "-o", str(executable)], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
