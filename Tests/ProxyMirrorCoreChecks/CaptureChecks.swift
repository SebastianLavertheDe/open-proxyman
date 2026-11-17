import Combine
import Foundation
import NIOEmbedded
@testable import ProxyMirrorCore

@MainActor
func checkCapture(_ test: CoreAssertions) {
    let loop = EmbeddedEventLoop()
    let transaction = Transaction()
    let chunk = Data(repeating: 0xA5, count: 16 * 1024)
    let byteCount = 512 * chunk.count
    transaction.captureLimit = byteCount
    let capture = TransactionCapture(transaction: transaction, on: loop)
    var publications = 0
    let observer = transaction.objectWillChange.sink { publications += 1 }
    defer { observer.cancel() }

    for _ in 0..<512 {
        capture.append(chunk, direction: .downstream)
    }
    loop.advanceTime(by: .milliseconds(39))
    test.equal(publications, 0, "Capture coalesces chunks before the timer fires")
    loop.advanceTime(by: .milliseconds(1))
    test.equal(publications, 1, "512 chunks publish as one response body update")
    test.equal(transaction.responseBodyRevision, 1, "One batch advances the body revision once")
    test.expect(transaction.responseBody == Data(repeating: 0xA5, count: byteCount),
                "Batched capture preserves response bytes")
    test.expect(!transaction.responseTruncated, "An exact fit is not truncated")

    capture.append(chunk, direction: .downstream)
    capture.flush()
    loop.advanceTime(by: .milliseconds(40))
    test.equal(publications, 2, "A final flush cancels its pending timer")
    test.equal(transaction.responseBytes, byteCount + chunk.count, "Truncated capture counts all wire bytes")
    test.equal(transaction.responseBody.count, byteCount, "Capture keeps the configured body limit")
    test.equal(transaction.responseBodyRevision, 1, "A byte-count-only update keeps the body revision")
    test.expect(transaction.responseTruncated, "An over-limit response is marked truncated")

    let budget = CaptureBudget(limit: 5)
    do {
        let first = Transaction(captureBudget: budget)
        let second = Transaction(captureBudget: budget)
        first.appendResponseBody(Data([1, 2, 3]))
        second.appendResponseBody(Data([4, 5, 6]))
        test.equal(first.responseBody, Data([1, 2, 3]), "First capture reserves its bytes")
        test.equal(second.responseBody, Data([4, 5]), "Second capture shares the global budget")
        test.expect(second.responseTruncated, "The global budget can truncate a response")
    }
    let next = Transaction(captureBudget: budget)
    next.appendResponseBody(Data([1, 2, 3, 4, 5]))
    test.equal(next.responseBody.count, 5, "Releasing transactions returns their budget")
    test.expect(!next.responseTruncated, "Released budget is available to new captures")

    let reuse = CaptureBudget(limit: 15)
    let oldest = Transaction(captureBudget: reuse)
    oldest.statusCode = 200
    oldest.responseHeaders = HTTPHeaders([("X-Keep", "metadata")])
    oldest.appendRequestBody(Data([1, 2, 3]))
    oldest.requestBodyComplete = true
    oldest.appendResponseBody(Data(repeating: 1, count: 6))
    let newer = Transaction(captureBudget: reuse)
    newer.appendResponseBody(Data(repeating: 2, count: 6))
    // Completion may occur in a different order from capture creation.
    newer.state = .completed
    oldest.state = .completed
    let revision = oldest.responseBodyRevision
    let generation = oldest.responseBodyGeneration
    let snapshot = SessionRecord(oldest)
    let queuedReplay = ComposeService.replayRequest(from: oldest)
    let incoming = Transaction(captureBudget: reuse)
    let incomingCapture = TransactionCapture(transaction: incoming, on: loop)
    incomingCapture.append(Data([3, 4, 5, 6]), direction: .downstream)
    incomingCapture.flush()

    test.equal(incoming.responseBody, Data([3, 4, 5, 6]), "New network capture reuses the oldest retained body's budget")
    test.expect(!incoming.responseTruncated, "Newest capture keeps its full prefix")
    test.expect(oldest.responseBody.isEmpty && oldest.responseTruncated && oldest.responseBytes == 6,
                "Old capture keeps wire counts and marks the discarded preview as truncated")
    test.equal(oldest.responseBodyRevision, revision + 1, "Reclamation invalidates body previews")
    test.equal(oldest.responseBodyGeneration, generation + 1, "Reclamation invalidates body filters")
    test.equal(oldest.responseHeaders.value(of: "X-Keep"), "metadata", "Reclamation preserves transaction metadata")
    test.equal(oldest.state, .completed, "Reclamation preserves transaction state")
    test.equal(newer.responseBody.count, 6, "Reclamation keeps newer captures when one victim is sufficient")
    test.equal(snapshot.responseBody, Data(repeating: 1, count: 6), "An existing archive snapshot retains its payload")
    test.equal(queuedReplay?.body, Data([1, 2, 3]), "An already queued replay keeps its complete request body")
    test.expect(ComposeService.replayRequest(from: oldest) == nil, "Replays cannot send a request whose body was reclaimed")

    let pendingBudget = CaptureBudget(limit: 8)
    let pending = Transaction(captureBudget: pendingBudget)
    let pendingCapture = TransactionCapture(transaction: pending, on: loop)
    pendingCapture.append(Data([1, 2, 3, 4]), direction: .downstream)
    pendingCapture.flush()
    pendingCapture.append(Data([5, 6, 7, 8]), direction: .downstream)
    pending.state = .completed
    let priority = Transaction(captureBudget: pendingBudget)
    priority.appendResponseBody(Data([9, 10, 11, 12, 13]))
    test.equal(priority.responseBody, Data([9, 10, 11, 12]), "Reclamation cannot reuse bytes still pending publication")
    pendingCapture.flush()
    test.expect(pending.responseBody.isEmpty && pending.responseBytes == 8,
                "A pending batch cannot restore evicted bytes or lose its wire counts")
    let following = Transaction(captureBudget: pendingBudget)
    following.appendResponseBody(Data([14, 15, 16, 17]))
    test.equal(following.responseBody, Data([14, 15, 16, 17]), "Dropped pending bytes return their charge after publication")
}
