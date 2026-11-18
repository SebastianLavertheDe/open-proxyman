import Foundation
import NIOEmbedded
@testable import ProxyMirrorCore

@MainActor
func checkSSEInspection(_ test: CoreAssertions) throws {
    let headers = HTTPHeaders([("Content-Type", "text/event-stream")])
    let wire = Data("data: first\n\nid: shared\ndata: second\n\ndata: third\n\n".utf8)
    let arrival = Date(timeIntervalSince1970: 1_700_000_000)
    let stream = SSEBodyStream(headers: headers)
    stream.append(wire, at: arrival)
    test.equal(stream.snapshot.events.map(\.data), ["first", "second", "third"], "SSE retains separate events with missing or repeated protocol IDs")
    test.equal(stream.snapshot.events.map(\.index), [0, 1, 2], "SSE row identity uses a unique event index")

    let tx = Transaction()
    tx.host = "example.test"
    tx.path = "/events"
    tx.statusCode = 200
    tx.state = .completed
    tx.contentType = "text/event-stream"
    tx.responseHeaders = headers
    tx.responseBody = wire
    tx.responseBodyComplete = true
    tx.applySSESnapshot(stream.snapshot)
    let session = SessionFile(transactions: [tx], pinnedDomains: [], selected: [])
    let encoded = try JSONEncoder().encode(session)
    let restored = try SessionFile.decode(encoded).records[0].transaction()
    test.equal(restored.sseEvents, tx.sseEvents, "Session preserves actual SSE events and arrival times")

    let directory = try makeCheckDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TrafficStore(sourceFolderFile: directory.appendingPathComponent("folders.json"),
                             savedFile: directory.appendingPathComponent("saved.proxymirror"))
    store.add(tx)
    store.selectedIDs = [tx.id]
    store.saveSelection()
    let savedDeadline = Date().addingTimeInterval(2)
    while store.saved.isEmpty, Date() < savedDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    store.filterMode = .saved
    store.selectedIDs = [tx.id]
    test.equal(store.selectedTransactions.first?.sseEvents, tx.sseEvents,
               "Saved snapshot preserves SSE events without reopening a file")

    var saveComplete = false
    if store.finishSaving({ _ in saveComplete = true }) {
        let deadline = Date().addingTimeInterval(2)
        while !saveComplete, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        test.expect(saveComplete, "Saved SSE persistence completes before its fixture directory is removed")
    }

    var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    var records = legacy["records"] as! [[String: Any]]
    records[0].removeValue(forKey: "sse")
    legacy["records"] = records
    let legacyData = try JSONSerialization.data(withJSONObject: legacy)
    let rebuilt = try SessionFile.decode(legacyData).records[0].transaction()
    test.equal(rebuilt.sseEvents.map(\.data), ["first", "second", "third"], "Legacy sessions rebuild SSE from captured bodies")
    test.expect(rebuilt.sseEvents.allSatisfy { $0.at == nil }, "Legacy reconstruction does not invent event arrival timestamps")
    let har = try JSONSerialization.data(withJSONObject: ExportService.buildHAR([tx]))
    let imported = try SessionFile.importHAR(har)[0]
    test.equal(imported.sseEvents.map(\.data), ["first", "second", "third"], "HAR import rebuilds SSE from the response body")
    test.expect(imported.sseEvents.allSatisfy { $0.at == nil }, "HAR imports have no fabricated per-event timings")

    let fixtures: [(String, String, String)] = [
        ("gzip", "H4sIAAAAAAAAA0pJLEm0UkjLLCou4eICAAAA//8=", "SwFzilOT8/NSuLgAaL6WWhsAAAA="),
        ("deflate", "eJxKSSxJtFJIyywqLuHiAgAAAP//", "SwFzilOT8/NSuLgAgCkItQ=="),
        ("deflate", "SkksSbRSSMssKi7h4gIAAAD//w==", "SwFzilOT8/NSuLgA"),
    ]
    for (encoding, prefix, suffix) in fixtures {
        let first = Data(base64Encoded: prefix)!
        let last = Data(base64Encoded: suffix)!
        let encodedHeaders = HTTPHeaders([("Content-Type", "text/event-stream"), ("Content-Encoding", encoding)])
        let compressed = SSEBodyStream(headers: encodedHeaders)
        // Split the container header and stream across individual TCP bytes.
        for byte in first { compressed.append(CollectionOfOne(byte), at: arrival) }
        test.equal(compressed.snapshot.events.map(\.data), ["first"], "\(encoding) SSE emits an event before stream EOF")
        compressed.append(last, at: arrival.addingTimeInterval(2))
        compressed.finish()
        test.equal(compressed.snapshot.events.map(\.data), ["first", "second"], "\(encoding) SSE incrementally decodes every event")
        test.equal(compressed.snapshot.issue, nil, "\(encoding) SSE validates the complete compressed stream")
        let recovered = SSEBodyRecovery.recover(first + last, headers: encodedHeaders, complete: true, truncated: false)
        test.equal(recovered.events.map(\.data), ["first", "second"], "\(encoding) imported SSE is decoded")
        test.expect(recovered.events.allSatisfy { $0.at == nil }, "\(encoding) recovered events have unknown arrival times")

        let loop = EmbeddedEventLoop()
        let captured = Transaction()
        captured.contentType = "text/event-stream"
        let capture = TransactionCapture(transaction: captured, on: loop)
        capture.setResponseHeadersForSSE(encodedHeaders)
        capture.append(first, direction: .downstream)
        capture.flush()
        test.equal(captured.sseEvents.first?.data, "first", "\(encoding) live capture publishes events before EOF")
        capture.append(last, direction: .downstream)
        capture.flush()
        test.equal(captured.sseEvents.count, 2, "\(encoding) live capture appends new events without duplication")
    }
    // A legal raw stored block can begin with bytes that also resemble a zlib header.
    let ambiguousPayload = Data(("data: raw fallback\n\n" + String(repeating: ":", count: 136)).utf8)
    test.equal(ambiguousPayload.count, 156, "Raw-deflate ambiguity fixture has the declared stored-block length")
    let ambiguousRaw = Data([0x78, 0x9c, 0x00, 0x63, 0xff]) + ambiguousPayload + Data([1, 0, 0, 255, 255])
    let ambiguous = SSEBodyStream(headers: HTTPHeaders([("Content-Encoding", "deflate")]))
    for byte in ambiguousRaw { ambiguous.append(CollectionOfOne(byte)) }
    ambiguous.finish()
    test.equal(ambiguous.snapshot.events.map(\.data), ["raw fallback"], "Raw SSE deflate can recover from an ambiguous wrapped-looking header before emitting bytes")
    test.equal(ambiguous.snapshot.issue, nil, "A valid raw stored block is not mislabeled as corrupt zlib")

    let gzipHeaders = HTTPHeaders([("Content-Type", "text/event-stream"), ("Content-Encoding", "gzip")])
    let first = Data(base64Encoded: fixtures[0].1)!
    let last = Data(base64Encoded: fixtures[0].2)!
    let gzipTx = Transaction()
    gzipTx.host = "gzip.example.test"
    gzipTx.statusCode = 200
    gzipTx.state = .completed
    gzipTx.contentType = "text/event-stream"
    gzipTx.responseHeaders = gzipHeaders
    gzipTx.responseBody = first + last
    gzipTx.responseBodyComplete = true
    let gzipHAR = try JSONSerialization.data(withJSONObject: ExportService.buildHAR([gzipTx]))
    let importedGzip = try SessionFile.importHAR(gzipHAR)[0]
    test.equal(importedGzip.sseEvents.map(\.data), ["first", "second"], "HAR import recovers gzip SSE events without changing captured bytes")
    test.equal(importedGzip.responseBody, first + last, "SSE HAR reconstruction preserves the encoded response body")

    let incomplete = SSEBodyRecovery.recover(first, headers: gzipHeaders, complete: true, truncated: false)
    test.expect(incomplete.issue != nil, "A completed HTTP body with an unfinished gzip stream reports the incomplete encoding")
    let finalLoop = EmbeddedEventLoop()
    let finalTx = Transaction()
    let finalCapture = TransactionCapture(transaction: finalTx, on: finalLoop)
    finalCapture.setResponseHeadersForSSE(gzipHeaders)
    finalCapture.append(first, direction: .downstream)
    finalCapture.flush()
    test.equal(finalTx.sseParseIssue, nil, "An open gzip SSE stream does not claim truncation")
    finalCapture.finishSSE()
    test.expect(finalTx.sseParseIssue != nil, "Live terminal validation publishes an incomplete gzip issue after the body batch was already flushed")
    let concatenated = SSEBodyRecovery.recover(first + last + first + last, headers: gzipHeaders, complete: true, truncated: false)
    test.equal(concatenated.events.map(\.data), ["first", "second", "first", "second"], "SSE accepts concatenated gzip members")
    var invalid = first + last
    invalid[invalid.count - 8] ^= 1
    test.expect(SSEBodyRecovery.recover(invalid, headers: gzipHeaders, complete: true, truncated: false).issue != nil,
                "Corrupt gzip checksums are shown as SSE decoding failures")
    let unsupported = SSEBodyStream(headers: HTTPHeaders([("Content-Encoding", "zstd")]))
    test.expect(unsupported.snapshot.issue?.contains("zstd") == true && !unsupported.snapshot.deferred,
                "Unsupported SSE encodings have an explicit reason instead of an empty waiting page")

    let combinedHeaders = HTTPHeaders([("Content-Encoding", "gzip, gzip")])
    let combined = Data(base64Encoded: "H4sIAAAAAAACA5Pv5mAAASZmb08dzy1BGl6+5/S9db18Hz5iYiid9URMECgJAEWj+IolAAAA")!
    let waitingCombined = SSEBodyRecovery.recover(combined, headers: combinedHeaders, complete: false, truncated: false)
    test.expect(waitingCombined.deferred && waitingCombined.events.isEmpty,
                "Combined SSE content encodings disclose that parsing requires the complete body")
    let recoveredCombined = SSEBodyRecovery.recover(combined, headers: combinedHeaders, complete: true, truncated: false)
    test.equal(recoveredCombined.events.first?.data, "recovered", "Completed SSE bodies decode every layer of Content-Encoding")
    test.equal(recoveredCombined.issue, nil, "Successful deferred SSE recovery clears the waiting explanation")

    let deferred = SSEBodyStream(headers: HTTPHeaders([("Content-Encoding", "br")]))
    test.expect(deferred.snapshot.deferred, "Brotli SSE explains that event recovery waits for a complete body")
    deferred.finish(complete: false)
    test.expect(!deferred.snapshot.deferred && deferred.snapshot.issue?.contains("连接已结束") == true,
                "A failed deferred SSE stream stops waiting and explains that the body cannot be recovered")
    let failedRecovery = SSEBodyRecovery.recover(Data([1]), headers: HTTPHeaders([("Content-Encoding", "br")]),
                                                complete: false, truncated: false, failed: true)
    test.expect(!failedRecovery.deferred && failedRecovery.issue?.contains("连接已结束") == true,
                "Old failed compressed SSE captures do not promise future event recovery")
    let limited = SSEBodyStream(headers: gzipHeaders)
    limited.append(Data(base64Encoded: "H4sIAAAAAAAAA+zBMQ0AMAgAsB8V6JgbEiRwTD7BR9uuqZcfAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAATsQCAAD//w==")!)
    test.expect(limited.snapshot.truncated, "Oversized gzip SSE events stop at the event preview limit")
    limited.append(Data(base64Encoded: "AwACAJoRCQABAA==")!)
    limited.finish()
    test.equal(limited.snapshot.issue, nil,
               "An intentionally truncated event preview does not accuse a valid gzip stream of being incomplete")

    var oversized = SSEStreamState()
    oversized.append(Data(("data: " + String(repeating: "x", count: SSEStreamState.maxDataPerEvent + 1) + "\n\n").utf8))
    test.expect(oversized.truncated, "Dropped oversized SSE events report the preview limit")
}
