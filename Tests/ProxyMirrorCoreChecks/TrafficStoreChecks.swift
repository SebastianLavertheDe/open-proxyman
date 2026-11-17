import Foundation
import Combine
@testable import ProxyMirrorCore

@MainActor
func checkTrafficStore(_ test: CoreAssertions) throws {
    let directory = try makeCheckDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let folderFile = directory.appendingPathComponent("SourceFolders.json")
    let savedFile = directory.appendingPathComponent("Saved.proxymirror")
    let store = TrafficStore(sourceFolderFile: folderFile, savedFile: savedFile)
    let split = TrafficStore(sharing: store)
    let good = Transaction()
    good.host = "api.example.test"
    good.clientName = "Fixture Browser"
    good.statusCode = 200
    good.state = .completed
    let pending = Transaction()
    pending.host = "api.example.test"
    store.add(good)
    test.expect(store.visible.map(\.id) == [good.id] && store.selectedID == nil,
                "New traffic appears without selecting a request by default")
    store.followLatest = true
    store.add(pending)
    test.equal(store.selectedIDs, [pending.id], "Follow Latest selects new record")

    store.selectManually([good.id])
    let other = Transaction()
    other.host = "other.test"
    other.clientName = "Fixture Browser"
    store.add(other)
    test.equal(store.selectedIDs, [good.id], "Manual selection survives incoming traffic")
    store.filter.statusBuckets = ["clientError"]
    test.expect(store.selectedIDs.isEmpty && store.selectedTransaction == nil, "Filtering out selection clears details")
    test.expect(store.visible.isEmpty, "Pending request does not match client-error filter")

    pending.statusCode = 404
    pending.state = .completed
    store.update(pending)
    test.equal(store.visible.map(\.id), [pending.id], "Status update invalidates visible rows")
    store.followLatest = true
    test.equal(store.selectedIDs, [pending.id], "Follow Latest chooses latest visible row")
    test.equal(split.visible.map(\.id), [good.id, pending.id, other.id], "Split filter stays independent")

    store.resetFilters()
    let folder = try store.saveSourceFolder(name: " Fixture ",
        members: [.domain("API.EXAMPLE.TEST"), .client("Fixture Browser")])
    store.filterMode = .folder(folder)
    test.equal(store.visible.map(\.id), [good.id, pending.id, other.id], "Folder matches either domain or client")
    test.equal(store.sourceFolderCounts[folder], 3, "Folder counts matching rows once")
    test.equal(split.sourceFolders.first?.name, "Fixture", "Shared view reads normalized folder name")
    try store.toggleSourceFolderMembership(.client("Fixture Browser"), folderID: folder)
    test.equal(store.visible.map(\.id), [good.id, pending.id], "Folder member edit refreshes cached filter")
    let reloaded = TrafficStore(sourceFolderFile: folderFile, savedFile: savedFile)
    test.equal(reloaded.sourceFolders, store.sourceFolders, "Folder membership round-trips from disk")

    split.filterMode = .folder(folder)
    try store.removeSourceFolder(folder)
    test.equal(store.filterMode, .all, "Deleting active folder resets primary view")
    test.equal(split.filterMode, .all, "Deleting active folder resets split view")
    test.equal(store.transactions.count, 3, "Deleting source folder preserves traffic")
    store.clear()
    test.expect(store.visible.isEmpty && store.selectedTransaction == nil, "Clear drops visible rows and selection")
    test.expect(split.visible.isEmpty, "Clear invalidates shared split rows")

    store.followLatest = false
    store.maxTransactions = 2
    let archive = Transaction()
    split.loadArchive([archive], name: "Fixture")
    let archiveRevision = split.displayedRows(sortedBy: .status, ascending: true).revision
    let savedView = TrafficStore(sharing: store)
    let savedRecord = Transaction()
    store.add(savedRecord)
    store.selectManually([savedRecord.id])
    store.saveSelection()
    let savedDeadline = Date().addingTimeInterval(2)
    while savedView.saved.isEmpty, Date() < savedDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    var saveFinished = false
    if store.finishSaving({ _ in saveFinished = true }) {
        while !saveFinished, Date() < savedDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
    store.clear()
    savedView.filterMode = .saved
    let savedRevision = savedView.displayedRows(sortedBy: .status, ascending: true).revision
    let baseline = store.displayedRows(sortedBy: .status, ascending: true).revision
    var publications = 0
    let subscription = store.objectWillChange.sink { publications += 1 }
    let first = Transaction()
    first.statusCode = 200
    first.responseBytes = 10
    let second = Transaction()
    second.statusCode = 100
    second.responseBytes = 20
    let third = Transaction()
    third.statusCode = 300
    third.responseBytes = 30
    store.ingestCaptured(first)
    store.ingestCaptured(second)
    store.ingestCaptured(third)
    test.equal(publications, 0, "Capture burst delays publication")
    test.equal(store.transactions.map(\.id), [second.id, third.id], "Live ring keeps the newest records in sequence order")
    test.expect(store.transaction(id: first.id) == nil, "Ring eviction removes the transaction index entry")
    second.statusCode = 404
    second.clientName = "Updated App"
    second.responseBytes = 25
    store.ingestUpdated(second)
    let deadline = Date().addingTimeInterval(2)
    while store.displayedRows(sortedBy: .status, ascending: true).revision == baseline, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    test.equal(publications, 1, "Capture burst and metadata update publish together")
    test.equal(store.displayedRows(sortedBy: .status, ascending: true).rows.map(\.id),
               [third.id, second.id], "Batch keeps sorted rows in updated key order")
    test.equal(store.clientApps.map(\.name), ["Updated App"], "Batched attribution invalidates the client summary")
    test.equal(store.transferredBytes.response, 55, "Transferred bytes reflect eviction and metadata updates")
    test.equal(split.displayedRows(sortedBy: .status, ascending: true).revision, archiveRevision,
               "Live batches leave the archive list cache intact")
    test.equal(savedView.displayedRows(sortedBy: .status, ascending: true).revision, savedRevision,
               "Live batches leave the Saved list cache intact")
    store.ingestCaptured(Transaction())
    store.clear()
    RunLoop.current.run(until: Date().addingTimeInterval(0.08))
    test.expect(store.visible.isEmpty && store.transactions.isEmpty && store.transferredBytes.response == 0,
                "Clearing during a pending publication cannot restore evicted records or byte totals")
    let selected = Transaction()
    selected.host = "evicted.test"
    selected.responseBytes = 7
    store.add(selected)
    _ = store.displayedRows(sortedBy: .status, ascending: true)

    let queued = Transaction()
    queued.host = "queued.test"
    queued.responseBytes = 11
    store.ingestCaptured(queued)
    let immediate = Transaction()
    immediate.host = "immediate.test"
    immediate.responseBytes = 13
    let beforeAppend = publications
    store.add(immediate)
    test.equal(publications, beforeAppend + 1, "Synchronous add publishes pending capture changes together")
    test.equal(store.displayedRows(sortedBy: .status, ascending: true).rows.map(\.id), [queued.id, immediate.id],
               "Synchronous add keeps the visible list current")
    test.equal(store.transferredBytes.response, 24, "Synchronous eviction updates totals")
    test.equal(store.domainSummary.map(\.host), ["queued.test", "immediate.test"], "Synchronous eviction preserves domain order")
    RunLoop.current.run(until: Date().addingTimeInterval(0.08))
    test.equal(publications, beforeAppend + 1, "Flushed capture batch does not publish again")
    store.selectManually([queued.id])
    let replacement = Transaction()
    replacement.host = "replacement.test"
    replacement.responseBytes = 17
    store.add(replacement)
    test.expect(store.selectedIDs.isEmpty && store.selectedID == nil, "Synchronous eviction clears the selection immediately")
    test.equal(store.displayedRows(sortedBy: .status, ascending: true).rows.map(\.id), [immediate.id, replacement.id],
               "Single synchronous append invalidates warm sorted rows")
    test.equal(store.transferredBytes.response, 30, "Single synchronous append evicts old byte totals")
    test.equal(store.domainSummary.map(\.host), ["immediate.test", "replacement.test"],
               "Single synchronous append preserves surviving domain order")

    store.followLatest = true
    store.maxTransactions = 0
    store.add(Transaction())
    test.expect(store.transactions.isEmpty && store.selectedID == nil && store.transferredBytes.response == 0,
                "Synchronous add honors reduced retention and clears old selection and totals")
    let beforeFilter = publications
    store.filter.searchText = "fixture"
    test.equal(publications, beforeFilter + 1, "Published filter and manual changes use the same publisher")
    withExtendedLifetime(subscription) {}
}
