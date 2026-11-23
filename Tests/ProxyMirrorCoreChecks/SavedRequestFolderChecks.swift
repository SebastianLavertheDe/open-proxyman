import Foundation
import AppKit
@testable import ProxyMirrorCore

@MainActor
func checkSavedRequestFolders(_ test: CoreAssertions) throws {
    let directory = try makeCheckDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let legacy = directory.appendingPathComponent("Saved.proxymirror")
    let sourceFile = directory.appendingPathComponent("SourceFolders.json")
    let first = Transaction(); first.host = "one.saved.test"; first.responseBody = Data("original body".utf8); first.comment = "original"
    let second = Transaction(); second.host = "two.saved.test"
    try SessionFile(transactions: [first, second], pinnedDomains: [], selected: []).write(to: legacy)
    let original = try Data(contentsOf: legacy)
    var seed = SavedRequestFolderArchive()
    seed.unfiled = [SessionRecord(first), SessionRecord(second)]
    try seed.write(to: SavedRequestFolderArchive.fileURL(for: legacy))
    let store = TrafficStore(sourceFolderFile: sourceFile, savedFile: legacy)
    let deadline = Date().addingTimeInterval(3)
    while store.saved.count != 2, store.savedError == nil, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    test.equal(store.saved.map(\.host), [first.host, second.host], "Current Saved archive retains every original request")
    try finishSavedFolderWrite(store)
    test.equal(try Data(contentsOf: legacy), original, "Canonical load does not modify a separate session file")
    let canonical = SavedRequestFolderArchive.fileURL(for: legacy)
    test.expect(FileManager.default.fileExists(atPath: canonical.path), "Current Saved archive has an explicit versioned file")
    let sourceID = try store.saveSourceFolder(name: "接口", members: [.domain("keep.source.test")])
    let live = Transaction(); live.host = "keep.source.test"; store.add(live)
    let parent = try store.createSavedRequestFolder(name: "工作")
    let child = try store.createSavedRequestFolder(name: "子文件夹", parentID: parent)
    test.equal(store.savedRequestFolderPath(child), "工作 / 子文件夹", "Saved request folders retain a real parent hierarchy")
    test.rejects(try store.moveSavedRequestFolder(parent, parentID: child), with: SavedRequestFolderArchive.Failure.self,
                 "A Saved folder cannot become its own descendant")
    test.expect(store.savedRequestFolders.first { $0.id == parent }?.parentID == nil, "Rejected folder move leaves the committed hierarchy intact")
    try store.transferSavedRequests(ids: [first.id], from: nil, to: parent, copy: false)
    test.equal(store.saved.map(\.id), [second.id], "Moving a Saved request removes it from the source container")
    store.filterMode = .savedFolder(parent)
    test.equal(store.visible.map(\.host), [first.host], "Selecting a Saved folder shows its captured snapshots, not live host filtering")
    test.equal(store.session(onlySelection: false, pinned: []).records.map(\.host), [first.host],
               "Session export reads the active Saved container")
    let savedFirst = store.visible[0]
    try store.copyRequests([savedFirst], toSavedFolder: child)
    let savedCopy = store.savedRequests(in: child)[0]
    test.expect(savedCopy.id != savedFirst.id && savedCopy !== savedFirst, "Cross-folder copies have independent snapshot identities")
    savedCopy.comment = "edited copy"; store.update(savedCopy)
    test.equal(savedFirst.comment, "original", "Editing a copied request does not mutate the source snapshot")
    first.responseBody = Data("changed live body".utf8)
    test.equal(savedCopy.responseBody, Data("original body".utf8), "Saved folders own snapshots rather than references to live capture")
    try store.renameSavedRequestFolder(parent, name: "接口")
    test.equal(store.savedRequestFolderPath(child), "接口 / 子文件夹", "Renaming updates descendant display paths")
    try store.moveSavedRequestFolder(child, parentID: nil)
    test.equal(store.savedRequestFolderPath(child), "子文件夹", "Moving folder containers updates parent membership")
    try store.moveSavedRequestFolder(child, parentID: parent)

    let exported = try SessionFile.decode(store.session(onlySelection: false, pinned: []).exportData())
    store.loadArchive(exported.records.map { $0.transaction() }, name: "Imported Saved")
    try store.copyRequests(store.selectedTransactions, toSavedFolder: child)
    test.equal(store.savedRequests(in: child).count, 2, "Imported sessions can be copied to a Saved folder without interpreting source folders")
    store.filterMode = .savedFolder(child)
    test.equal(store.session(onlySelection: false, pinned: []).records.count, 2, "Saved-folder session export contains that folder's requests only")
    try finishSavedFolderWrite(store)
    let reloaded = TrafficStore(sourceFolderFile: sourceFile, savedFile: legacy)
    let reloadDeadline = Date().addingTimeInterval(3)
    while reloaded.savedRequestFolders.count != 2, reloaded.savedError == nil, Date() < reloadDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    test.equal(reloaded.savedRequests(in: child).count, 2, "Saved folders and their request snapshots survive a storage reload")
    test.equal(reloaded.savedRequests(in: child).first?.comment, "edited copy", "Saved snapshot edits survive a storage reload")
    try store.deleteSavedRequestFolder(parent)
    test.expect(store.savedRequestFolders.isEmpty && store.saved.count == 4, "Deleting a Saved subtree moves all snapshots to Unfiled without dropping requests")
    test.equal(store.filterMode, .saved, "Deleting the active Saved folder returns its workspace to Unfiled")
    test.equal(store.sourceFolders.first?.id, sourceID, "Deleting a Saved folder does not delete a same-named source folder")
    store.filterMode = .folder(sourceID)
    test.equal(store.visible.map(\.id), [live.id], "Source folders continue filtering the original live data independently")
    try finishSavedFolderWrite(store)
    test.equal(try Data(contentsOf: legacy), original, "Folder rename/move/delete never rewrites the legacy recovery file")
    let state = try SavedRequestFolderArchive.load(legacy: legacy).archive
    test.equal(state.unfiled.count, 4, "The complete library is persisted after subtree deletion")
    let mode = try FileManager.default.attributesOfItem(atPath: canonical.path)[.posixPermissions] as? NSNumber
    test.equal(mode?.intValue, 0o600, "Saved request libraries containing captured credentials are written privately")

    let wrong = directory.appendingPathComponent("wrong.proxymirror")
    try SourceFolderArchive.write([SourceFolder(name: "source", members: [.domain("example.test")])], to: SavedRequestFolderArchive.fileURL(for: wrong))
    do { _ = try SavedRequestFolderArchive.load(legacy: wrong); test.expect(false, "Source-folder JSON is not a saved-request archive") }
    catch { test.expect(true, "Source-folder JSON is not a saved-request archive") }
}

@MainActor
private func finishSavedFolderWrite(_ store: TrafficStore) throws {
    var done = false, success = false
    if !store.finishSaving({ value in success = value; done = true }) { return }
    let deadline = Date().addingTimeInterval(4)
    while !done, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    if !done || !success { throw SavedRequestFolderArchive.Failure("Fixture Saved persistence failed or timed out") }
}

@MainActor
func checkFilterPanelShortcuts(_ test: CoreAssertions) {
    test.equal(TrafficFilterShortcut.match(key: "n", code: 45, modifiers: .command), .addCondition, "Filter panel Command-N creates a condition")
    test.equal(TrafficFilterShortcut.match(key: "N", code: 45, modifiers: [.command, .shift]), .addGroup, "Filter panel Shift-Command-N creates a subgroup")
    test.equal(TrafficFilterShortcut.match(key: "", code: 126, modifiers: .command), .previous, "Filter panel Command-Up navigates backward")
    test.equal(TrafficFilterShortcut.match(key: "", code: 125, modifiers: .command), .next, "Filter panel Command-Down navigates forward")
    test.equal(TrafficFilterShortcut.match(key: "b", code: 11, modifiers: .command), .toggleColor, "Filter panel Command-B toggles selected preset coloring")
    test.equal(TrafficFilterShortcut.match(key: "f", code: 3, modifiers: .command), .search, "Filter panel Command-F focuses local search")
    test.equal(TrafficFilterShortcut.match(key: "", code: 53, modifiers: []), .cancel, "Filter panel Escape cancels")
    test.expect(TrafficFilterShortcut.match(key: "n", code: 45, modifiers: [.command, .option]) == nil,
                "Filter panel leaves Compose's Option-Command-N untouched")
    test.expect(TrafficFilterShortcut.match(key: "t", code: 17, modifiers: .command) == nil,
                "Filter panel leaves workspace Command-T untouched")
    test.equal(TrafficFilterShortcut.nextIndex(current: 2, count: 3, delta: 1), 2, "Condition navigation stays within the visible list")
    test.equal(TrafficFilterShortcut.nextIndex(current: nil, count: 3, delta: -1), 2, "Previous navigation begins at the last visible entry when unselected")
}
