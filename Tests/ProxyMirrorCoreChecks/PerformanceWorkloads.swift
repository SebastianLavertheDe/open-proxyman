import Foundation
@testable import ProxyMirrorCore

@MainActor
package final class BodyAppendWorkload {
    private let chunk = Data(repeating: 0xA5, count: 16 * 1024)
    private let count: Int
    private let expected: Data
    private var transaction = Transaction()

    package init(chunks: Int) {
        count = chunks
        expected = Data(repeating: 0xA5, count: chunks * chunk.count)
    }

    package func prepare() {
        transaction = Transaction()
        transaction.captureLimit = expected.count
    }

    package func append() {
        for _ in 0..<count {
            transaction.appendResponseBody(chunk)
        }
    }

    package var isCorrect: Bool {
        transaction.responseBody == expected && transaction.responseBytes == expected.count
            && !transaction.responseTruncated
    }
}

@MainActor
package final class TrafficTableWorkload {
    private let store: TrafficStore
    private let expected: [[UUID]]
    private var result: [Transaction] = []

    package init(directory: URL) {
        let trafficStore = TrafficStore(sourceFolderFile: directory.appendingPathComponent("folders.json"),
                                        savedFile: directory.appendingPathComponent("saved.json"))
        trafficStore.followLatest = false
        trafficStore.setWorkspaceVisible(false)

        var identifiers = Array(repeating: UUID(), count: 5_000)
        for index in 0..<5_000 {
            let key = index * 73 % 5_000
            let transaction = Transaction()
            transaction.host = "benchmark.pm.test"
            transaction.path = "/items/\(key)"
            transaction.method = key.isMultiple(of: 2) ? "GET" : "POST"
            transaction.statusCode = key.isMultiple(of: 3) ? 404 : 200
            transaction.state = .completed
            identifiers[key] = transaction.id
            trafficStore.add(transaction)
        }
        expected = [
            (0..<5_000).filter { $0.isMultiple(of: 6) }.map { identifiers[$0] },
            (0..<5_000).filter { !$0.isMultiple(of: 2) && !$0.isMultiple(of: 3) }
                .reversed().map { identifiers[$0] },
        ]
        trafficStore.setWorkspaceVisible(true)
        store = trafficStore
    }

    package func filterAndSort(iteration: Int) {
        let first = iteration.isMultiple(of: 2)
        var filter = TrafficFilter()
        filter.methods = first ? ["GET"] : ["POST"]
        filter.statusBuckets = first ? ["clientError"] : ["success"]
        filter.searchText = "/items/"
        store.filter = filter
        result = TrafficColumn.url.sorted(store.visible, ascending: first)
    }

    package func isCorrect(iteration: Int) -> Bool {
        result.map(\.id) == expected[iteration % 2]
    }
}
