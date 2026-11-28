import Foundation
@testable import ProxyMirrorCore

func checkPendingSaves(_ test: CoreAssertions) throws {
    let directory = try makeCheckDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("rules.json")
    var latest = "initial"
    var commits = 0
    let save = PendingSave(commit: {
        try Data(latest.utf8).write(to: destination, options: .atomic)
        commits += 1
    }, reportFailure: { _ in test.expect(false, "Successful rule save does not report an error") })

    latest = "first edit"
    save.schedule()
    latest = "last edit"
    save.schedule()
    test.expect(!FileManager.default.fileExists(atPath: destination.path), "Edits remain coalesced before the timer")
    try save.flush()
    test.equal(try String(contentsOf: destination, encoding: .utf8), "last edit",
               "Immediate shutdown flush persists the latest edit before the debounce expires")
    test.expect(!save.hasChanges, "Successful shutdown flush clears pending edits")
    try save.flush()
    test.equal(commits, 1, "Repeated shutdown flush does not rewrite committed rules")
    latest = "edit during shutdown"
    save.schedule()
    try save.flush()
    test.equal(try String(contentsOf: destination, encoding: .utf8), latest,
               "Final termination flush includes edits made while awaiting other shutdown work")

    var shouldFail = true
    var failureReports = 0
    let retry = PendingSave(delay: 0.01, commit: {
        if shouldFail { throw CocoaError(.fileWriteNoPermission) }
        try Data("retried edit".utf8).write(to: destination, options: .atomic)
    }, reportFailure: { _ in failureReports += 1 })
    retry.schedule()
    test.rejects(try retry.flush(), with: CocoaError.self, "Shutdown receives a failed rule write")
    test.expect(retry.hasChanges, "Failed shutdown write retains pending edits")
    test.equal(try String(contentsOf: destination, encoding: .utf8), latest, "Failed save preserves prior file")
    let deadline = Date().addingTimeInterval(0.5)
    while failureReports == 0 && Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    test.equal(failureReports, 1, "Debounced failure reports an error")
    test.expect(retry.hasChanges, "A failed timer keeps edits available for shutdown retry")
    shouldFail = false
    try retry.flush()
    test.equal(try String(contentsOf: destination, encoding: .utf8), "retried edit", "A later shutdown retry persists the edits")
    test.expect(!retry.hasChanges, "Successful retry clears pending edits")

    var staleWrites = 0
    let installed = PendingSave(delay: 0.01, commit: { staleWrites += 1 }, reportFailure: { _ in })
    installed.schedule()
    installed.didCommit()
    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
    try installed.flush()
    test.equal(staleWrites, 0, "Immediate rule installation cancels an older timer and shutdown write")
}
