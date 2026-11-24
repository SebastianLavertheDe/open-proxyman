import Foundation
import ProxyMirrorFoundation
import XCTest

final class InspectionPipelineTests: XCTestCase {
    private func key(_ owner: UUID = UUID(), revision: UInt64 = 1) -> JSONFieldCache.Key {
        .init(owner: owner, revision: revision, request: false, encodings: [], complete: true, truncated: false)
    }

    func testJSONFieldsShareOneParseAtTheSameRevision() async {
        let cache = JSONFieldCache()
        let owner = UUID(), body = Data(#"{"id":7,"user":{"name":"Ada"},"items":[{"count":2}]}"#.utf8)
        let first = await cache.values(for: key(owner), paths: ["id", "user.name"]) { body }
        XCTAssertEqual(first, ["id": "7", "user.name": "Ada"])
        let next = await cache.values(for: key(owner), paths: ["items.0.count", "missing"]) { XCTFail("cached revision was loaded twice"); return nil }
        XCTAssertEqual(next, ["items.0.count": "2", "missing": ""])
        var statistics = await cache.statistics
        XCTAssertEqual(statistics.parses, 1)
        let replacement = await cache.values(for: key(owner, revision: 2), paths: ["id"]) { Data(#"{"id":9}"#.utf8) }
        XCTAssertEqual(replacement["id"], "9")
        statistics = await cache.statistics
        XCTAssertEqual(statistics.parses, 2)
    }

    func testJSONCacheStorageAndDisplayedValuesAreBoundedAndClearable() async {
        let cache = JSONFieldCache(byteLimit: 4096, entryLimit: 2)
        for index in 0..<10 {
            _ = await cache.values(for: key(), paths: ["id"]) { Data("{\"id\":\(index)}".utf8) }
        }
        var statistics = await cache.statistics
        XCTAssertLessThanOrEqual(statistics.entries, 2)
        XCTAssertLessThanOrEqual(statistics.cost, 4096)
        await cache.clear()
        statistics = await cache.statistics
        XCTAssertEqual(statistics.entries, 0)
        XCTAssertEqual(statistics.cost, 0)
        let combining = "a" + String(repeating: "\u{0301}", count: 10_000)
        let body = try! JSONSerialization.data(withJSONObject: ["text": combining])
        let values = await JSONFieldCache().values(for: key(), paths: ["text"]) { body }
        XCTAssertLessThanOrEqual(values["text"]!.utf8.count, 2002)
        let headerKey = JSONFieldCache.Key(owner: UUID(), revision: 1, request: false,
            encodings: [String(repeating: "unknown", count: 10_000)], complete: true, truncated: false)
        _ = await cache.values(for: headerKey, paths: ["id"]) { nil }
        statistics = await cache.statistics
        XCTAssertEqual(statistics.entries, 0, "encoding identity metadata must fit the cache budget even when decoding fails")
    }

    func testMessagePackOutputExpansionStopsAndPreservesCapturedBytes() {
        var wire = Data([0xdb, 0, 4, 0, 0])
        wire.append(Data(repeating: 1, count: 262_144))
        let result = MessagePackBody.inspect(wire, contentType: "application/msgpack")
        XCTAssertFalse(result.decoded)
        XCTAssertEqual(result.issue, .outputLimit)
        XCTAssertEqual(result.data, wire)
        XCTAssertEqual(result.contentType, "application/msgpack")
        XCTAssertThrowsError(try MessagePackBody.decodeToJSON(Data([0x92, 1, 2]), maximumOutputBytes: 4)) {
            XCTAssertEqual($0 as? MessagePackBody.DecodeError, .outputLimit)
        }
        XCTAssertEqual(try? MessagePackBody.decodeToJSON(Data([0x81, 0xa1, 0x61, 1]), maximumOutputBytes: 7), #"{"a":1}"#)
    }

    func testMessagePackConversionCanBeCancelledDuringAString() async throws {
        var wire = Data([0xdb, 0, 16, 0, 0])
        wire.append(Data(repeating: 97, count: 1_048_576))
        let input = wire
        let worker = Task.detached { try MessagePackBody.decodeToJSON(input, maximumOutputBytes: 2 * 1024 * 1024) }
        try await Task.sleep(nanoseconds: 1_000_000)
        worker.cancel()
        switch await worker.result {
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        case .success: XCTFail("conversion ignored cancellation")
        }
    }

    func testMessagePackRepresentationsRemainValidJSON() throws {
        let map = Data([0x82, 1, 0xa1, 0x78, 0xa1, 0x31, 0xca, 0x7f, 0xc0, 0, 0])
        let result = MessagePackBody.inspect(map, contentType: "application/msgpack")
        XCTAssertTrue(result.decoded)
        XCTAssertEqual(String(decoding: result.data, as: UTF8.self), #"{"_map":[[1,"x"],["1",{"_float":"NaN"}]]}"#)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: result.data))
    }

    func testJSONSortUsesNaturalKeysAndRejectsObsoletePublicationTickets() async {
        let keys = [key(), key(), key()]
        let inputs = zip(keys, [(10, 1), (2, 3), (2, 2)]).map { key, values in
            JSONColumnSort.Input(key: key, sequence: values.1) { Data("{\"id\":\(values.0)}".utf8) }
        }
        let ordered = await JSONColumnSort.indices(inputs, path: "id", ascending: true, cache: JSONFieldCache())
        XCTAssertEqual(ordered, [2, 1, 0])
        let generation = UUID()
        let ticket = JSONColumnSort.Ticket(generation: generation, keys: keys)
        XCTAssertTrue(ticket.isCurrent(generation: generation, keys: keys))
        XCTAssertFalse(ticket.isCurrent(generation: UUID(), keys: keys), "a later filter or sort supersedes the completed worker")
        var replacements = keys
        replacements[0] = key(keys[0].owner, revision: 2)
        XCTAssertFalse(ticket.isCurrent(generation: generation, keys: replacements), "new captured bytes supersede a completed worker")
        XCTAssertFalse(ticket.isCurrent(generation: generation, keys: Array(keys.reversed())), "a changed row source supersedes a completed worker")
    }

    func testCancelledJSONSortDoesNotPublishOrPopulateCache() async {
        let cache = JSONFieldCache()
        let started = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        let input = JSONColumnSort.Input(key: key(), sequence: 1) {
            started.signal(); proceed.wait()
            return Data(#"{"id":1}"#.utf8)
        }
        let worker = Task.detached { await JSONColumnSort.indices([input], path: "id", ascending: true, cache: cache) }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        worker.cancel()
        let cleanup = Task { await cache.clear() }
        proceed.signal()
        await cleanup.value
        let result = await worker.value
        XCTAssertNil(result)
        let statistics = await cache.statistics
        XCTAssertEqual(statistics.entries, 0)
        XCTAssertEqual(statistics.parses, 0)
    }

    func testBodyInspectionIdentityIncludesHeadersCompletionAndPressureEpoch() {
        final class Owner {}
        let owner = Owner()
        func identity(encoding: String = "gzip", type: String = "application/msgpack", complete: Bool = true,
                      truncated: Bool = false, epoch: UInt64 = 0) -> BodyInspectionKey {
            .init(transaction: ObjectIdentifier(owner), revision: 7, encodings: [encoding], contentType: type,
                  complete: complete, truncated: truncated, epoch: epoch)
        }
        let original = identity()
        XCTAssertEqual(original, identity())
        XCTAssertNotEqual(original, identity(encoding: "br"))
        XCTAssertNotEqual(original, identity(type: "application/json"))
        XCTAssertNotEqual(original, identity(complete: false))
        XCTAssertNotEqual(original, identity(truncated: true))
        XCTAssertNotEqual(original, identity(epoch: 1))
    }

    func testGraphQLColumnDerivedCacheUsesTheCompleteRequestIdentity() async {
        let cache = JSONFieldCache()
        let owner = UUID()
        let key = JSONFieldCache.Key(owner: owner, revision: 1, request: true, encodings: [], complete: true, truncated: false,
                                     context: ["graphql", "/graphql", "operationName=First", "application/json"])
        let first = await cache.derivedValue(for: key) {
            GraphQLColumnValue.operationName(path: "/graphql", query: "operationName=First", contentType: "application/json", body: Data())
        }
        XCTAssertEqual(first, "First")
        let cached = await cache.derivedValue(for: key) { XCTFail("the same GraphQL request was parsed twice"); return "wrong" }
        XCTAssertEqual(cached, "First")
        let updated = JSONFieldCache.Key(owner: owner, revision: 1, request: true, encodings: [], complete: true, truncated: false,
                                         context: ["graphql", "/graphql", "operationName=Second", "application/json"])
        let second = await cache.derivedValue(for: updated) {
            GraphQLColumnValue.operationName(path: "/graphql", query: "operationName=Second", contentType: "application/json", body: Data())
        }
        XCTAssertEqual(second, "Second")
        let tiny = JSONFieldCache(byteLimit: 4096)
        let hugeMetadata = JSONFieldCache.Key(owner: owner, revision: 1, request: true, encodings: [], complete: true, truncated: false,
                                              context: [String(repeating: "x", count: 8192)])
        _ = await tiny.derivedValue(for: hugeMetadata) { "name" }
        let statistics = await tiny.statistics
        XCTAssertEqual(statistics.entries, 0, "GraphQL query and path metadata must count toward the storage budget")
    }

    @MainActor
    func testColdGraphQLColumnBatchDoesNotOccupyTheMainActor() async throws {
        let cache = JSONFieldCache()
        let data = Data(("{\"query\":\"query Viewer { viewer { id } }\",\"variables\":{\"padding\":\""
            + String(repeating: "x", count: 122_700) + "\"}}").utf8)
        let inputs = (0..<1000).map { index in
            let identity = JSONFieldCache.Key(owner: UUID(), revision: 1, request: true, encodings: [], complete: true, truncated: false,
                                              context: ["graphql", "/graphql", "", "application/json"])
            return JSONColumnSort.ValueInput(sequence: index) {
                await cache.derivedValue(for: identity) {
                    GraphQLColumnValue.operationName(path: "/graphql", query: "", contentType: "application/json", body: data)
                }
            }
        }
        let started = ProcessInfo.processInfo.systemUptime
        let worker = Task.detached { await JSONColumnSort.indices(values: inputs, ascending: true) }
        try await Task.sleep(nanoseconds: 2_000_000)
        let heartbeat = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThan(heartbeat, 0.2, "GraphQL list extraction occupied the main actor")
        let result = await worker.value
        XCTAssertEqual(result, Array(0..<1000))
        print("GraphQL columns: 1000 x \(data.count) bytes; main-actor heartbeat \(heartbeat)s; batch \(ProcessInfo.processInfo.systemUptime - started)s")
    }

    @MainActor
    func testColdJSONBatchDoesNotOccupyTheMainActor() async throws {
        let cache = JSONFieldCache()
        let data = Data(("{\"id\":7,\"padding\":\"" + String(repeating: "x", count: 122_800) + "\"}").utf8)
        let inputs = (0..<1000).map { index in JSONColumnSort.Input(key: key(), sequence: index) { data } }
        let started = ProcessInfo.processInfo.systemUptime
        let worker = Task.detached {
            await JSONColumnSort.indices(inputs, path: "id", ascending: true, cache: cache)
        }
        try await Task.sleep(nanoseconds: 2_000_000)
        let heartbeat = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThan(heartbeat, 0.2, "JSON parsing occupied the main actor")
        let complete = await worker.value
        XCTAssertEqual(complete, Array(0..<1000))
        let statistics = await cache.statistics
        XCTAssertEqual(statistics.parses, 1000)
        XCTAssertLessThanOrEqual(statistics.cost, 16 * 1024 * 1024)
        print("JSON columns: 1000 x \(data.count) bytes; main-actor heartbeat \(heartbeat)s; batch \(ProcessInfo.processInfo.systemUptime - started)s; parses \(statistics.parses)")
    }
}
