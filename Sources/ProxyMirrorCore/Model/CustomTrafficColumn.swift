import Foundation
import Combine
import ProxyMirrorFoundation

extension Notification.Name {
    static let pmGraphQLValueReady = Notification.Name("ProxyMirror.graphqlValueReady")
    static let pmJSONColumnCacheWillClear = Notification.Name("ProxyMirror.jsonColumnCacheWillClear")
}

struct CustomTrafficColumn: Codable, Hashable, Identifiable {
    enum Source: String, Codable, CaseIterable {
        case requestHeader, responseHeader, query
        case requestJSON, responseJSON
        var localizedTitle: String {
            switch self {
            case .requestHeader: return Strings.Models.columnSourceRequestHeader
            case .responseHeader: return Strings.Models.columnSourceResponseHeader
            case .query: return Strings.Models.columnSourceQuery
            case .requestJSON: return Strings.Models.columnSourceRequestJSON
            case .responseJSON: return Strings.Models.columnSourceResponseJSON
            }
        }
    }

    var id = UUID()
    var title = ""
    var source = Source.responseHeader
    var key = ""

    static let defaultsKey = "ui.customTrafficColumns"

    var readsJSON: Bool { source == .requestJSON || source == .responseJSON }

    @MainActor
    func value(for tx: Transaction) -> String {
        switch source {
        case .requestHeader: return tx.requestHeaders.values(of: key).joined(separator: ", ")
        case .responseHeader: return tx.responseHeaders.values(of: key).joined(separator: ", ")
        case .query:
            return (URLComponents(string: "?\(tx.query)")?.queryItems ?? [])
                .filter { $0.name == key }.compactMap(\.value).joined(separator: ", ")
        case .requestJSON, .responseJSON:
            return CustomColumnValues.shared.value(for: tx, request: source == .requestJSON, path: key)
        }
    }

    @MainActor
    func snapshot(for tx: Transaction) -> CustomJSONSnapshot {
        CustomColumnValues.shared.snapshot(for: tx, request: source == .requestJSON)
    }
}

/// Every byte and header used by a worker belongs to this immutable snapshot.
/// Observable Transaction objects stay on the main actor.
struct CustomJSONSnapshot: Sendable {
    let key: JSONFieldCache.Key
    let body: Data

    func values(paths: [String]) async -> [String: String] {
        await JSONFieldCache.shared.scalarValues(for: key, paths: paths) { [self] in decodedBody() }
    }

    func decodedBody(limit: Int = JSONFieldCache.maximumInputBytes) -> Data? {
        guard !Task.isCancelled else { return nil }
        let encodings = key.encodings.flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0 != "identity" }
        if encodings.isEmpty { return body.count <= limit ? body : nil }
        guard key.complete, !key.truncated else { return nil }
        if case .success(let decoded) = ContentCoding.decodeIfCompressed(body, encodings: encodings,
            maxOutputBytes: limit) { return decoded.0 }
        return nil
    }
}

struct GraphQLColumnSnapshot: Sendable {
    let inspection: CustomJSONSnapshot
    let path: String
    let query: String
    let contentType: String
    var key: JSONFieldCache.Key { inspection.key }

    func value() async -> String {
        let cached = await DerivedFieldCache.shared.lookup(key)
        if let value = cached.values["$graphql.name"] { return value }
        let value = await JSONFieldCache.shared.derivedValue(for: key) { [self] in
            guard !key.truncated else { return "" }
            let body = inspection.decodedBody(limit: GraphQLColumnValue.maximumInputBytes) ?? Data()
            return GraphQLColumnValue.operationNameForMatching(path: path, query: query, contentType: contentType, body: body)
        }
        await DerivedFieldCache.shared.store(["$graphql.name": value], for: key, generation: cached.generation)
        return value
    }
}

enum BackgroundColumnSnapshot: Sendable {
    case json(CustomJSONSnapshot, path: String)
    case graphql(GraphQLColumnSnapshot)
    var key: JSONFieldCache.Key {
        switch self { case .json(let snapshot, _): return snapshot.key; case .graphql(let snapshot): return snapshot.key }
    }
    func value() async -> String {
        switch self {
        case .json(let snapshot, let path): return await snapshot.values(paths: [path])[path] ?? ""
        case .graphql(let snapshot): return GraphQLColumnValue.displayName(await snapshot.value())
        }
    }
}

@MainActor
final class CustomColumnValues: ObservableObject {
    static let shared = CustomColumnValues()
    let objectWillChange = ObservableObjectPublisher()
    private final class Identity { let id = UUID() }
    private var identities = NSMapTable<Transaction, Identity>(keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)
    private var cached: [JSONFieldCache.Key: [String: String]] = [:]
    private var order: [JSONFieldCache.Key] = []
    private var costs: [JSONFieldCache.Key: Int] = [:]
    private var bytes = 0
    private final class Request {
        let key: JSONFieldCache.Key
        weak var transaction: Transaction?
        let graphql: Bool
        var paths: Set<String>
        var task: Task<Void, Never>?
        init(key: JSONFieldCache.Key, transaction: Transaction, graphql: Bool, paths: Set<String>) {
            self.key = key; self.transaction = transaction; self.graphql = graphql; self.paths = paths
        }
    }
    private var jobs: [JSONFieldCache.Key: Request] = [:]
    private var queue: [Request?] = []
    private var queueHead = 0
    private var activeWorkers = 0
    private let maximumWorkers = 4
    private let maximumQueued = 1024
    enum GraphQLState { case pending, ready(String) }
    final class GraphQLReady {
        let transaction: Transaction
        let key: JSONFieldCache.Key
        let value: String
        init(_ transaction: Transaction, key: JSONFieldCache.Key, value: String) {
            self.transaction = transaction; self.key = key; self.value = value
        }
    }
    private var generation: UInt64 = 0
    private var publicationScheduled = false
    private var columns: [CustomTrafficColumn] = []
    private let byteLimit = 8 * 1024 * 1024
    private let entryLimit = 4096

    var workCounts: (active: Int, retained: Int) { (activeWorkers, jobs.count) }

    func configure(_ columns: [CustomTrafficColumn]) { self.columns = columns }

    func key(for tx: Transaction, request: Bool, context: [String] = []) -> JSONFieldCache.Key {
        let identity = identities.object(forKey: tx) ?? Identity()
        identities.setObject(identity, forKey: tx)
        return .init(owner: identity.id,
            revision: request ? tx.requestBodyRevision : tx.responseBodyRevision,
            request: request, encodings: (request ? tx.requestHeaders : tx.responseHeaders).values(of: "Content-Encoding"),
            complete: request ? tx.requestBodyComplete : tx.responseBodyComplete,
            truncated: request ? tx.requestTruncated : tx.responseTruncated, context: context)
    }

    func snapshot(for tx: Transaction, request: Bool, context: [String] = []) -> CustomJSONSnapshot {
        let before = key(for: tx, request: request, context: context)
        let body = request ? tx.requestBody : tx.responseBody
        let after = key(for: tx, request: request, context: context)
        // Eviction can retire a body from another connection's event loop.
        return CustomJSONSnapshot(key: after, body: before == after ? body : Data())
    }

    func graphqlKey(for tx: Transaction) -> JSONFieldCache.Key {
        key(for: tx, request: true, context: ["graphql", tx.path, tx.query, tx.requestHeaders.value(of: "Content-Type") ?? ""])
    }

    func graphqlSnapshot(for tx: Transaction) -> GraphQLColumnSnapshot {
        let path = tx.path, query = tx.query, type = tx.requestHeaders.value(of: "Content-Type") ?? ""
        return GraphQLColumnSnapshot(inspection: snapshot(for: tx, request: true, context: ["graphql", path, query, type]),
                                     path: path, query: query, contentType: type)
    }

    func graphqlState(for tx: Transaction) -> GraphQLState {
        let key = graphqlKey(for: tx)
        if let value = cached[key]?["$graphql.name"] { return .ready(value) }
        enqueue(key: key, transaction: tx, graphql: true, paths: [])
        return .pending
    }

    func graphqlValue(for tx: Transaction) -> String {
        if case .ready(let value) = graphqlState(for: tx) { return GraphQLColumnValue.displayName(value) }
        return ""
    }

    func value(for tx: Transaction, request: Bool, path: String) -> String {
        guard path.utf8.count <= 8192 else { return "" }
        let key = key(for: tx, request: request)
        if let ready = cached[key]?[path] { return ready }
        let paths = Set(columns.filter { $0.readsJSON && ($0.source == .requestJSON) == request }
            .map(\.key).filter { $0.utf8.count <= 8192 } + [path])
        enqueue(key: key, transaction: tx, graphql: false, paths: paths)
        return ""
    }

    private func enqueue(key: JSONFieldCache.Key, transaction: Transaction, graphql: Bool, paths: Set<String>) {
        if let existing = jobs[key] { existing.paths.formUnion(paths); return }
        // Queue entries hold weak transactions, never captured bodies. A full
        // queue is retried on the next bounded publication/refilter batch.
        guard jobs.count < maximumQueued else { return }
        let request = Request(key: key, transaction: transaction, graphql: graphql, paths: paths)
        jobs[key] = request; queue.append(request); drain()
    }

    private func drain() {
        while activeWorkers < maximumWorkers, queueHead < queue.count {
            let request = queue[queueHead]; queue[queueHead] = nil; queueHead += 1
            guard let request, let transaction = request.transaction else {
                if let request, jobs[request.key] === request { jobs[request.key] = nil }; continue
            }
            let key = request.key
            let current = request.graphql ? graphqlKey(for: transaction) : self.key(for: transaction, request: key.request)
            guard current == key, jobs[key] === request else { if jobs[key] === request { jobs[key] = nil }; continue }
            let epoch = generation
            let paths = Array(request.paths)
            // Read the body only when one of the four workers can start.
            let snapshot: BackgroundColumnSnapshot = request.graphql
                ? .graphql(graphqlSnapshot(for: transaction))
                : .json(snapshot(for: transaction, request: key.request), path: "")
            let worker = Task.detached(priority: .utility) { () -> [String: String] in
                switch snapshot {
                case .graphql(let value): return ["$graphql.name": await value.value()]
                case .json(let value, _): return await value.values(paths: paths)
                }
            }
            activeWorkers += 1
            request.task = Task { [weak self, weak transaction] in
                let values = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                guard let self else { return }
                self.activeWorkers -= 1
                request.task = nil
                defer { self.schedulePublication(); self.drain() }
                guard self.jobs[key] === request else { return }
                self.jobs[key] = nil
                guard !Task.isCancelled, self.generation == epoch, let transaction else { return }
                let current = request.graphql ? self.graphqlKey(for: transaction) : self.key(for: transaction, request: key.request)
                guard current == key else { return }
                self.store(values, for: key)
                if request.graphql, let name = values["$graphql.name"] {
                    NotificationCenter.default.post(name: .pmGraphQLValueReady,
                        object: GraphQLReady(transaction, key: key, value: name))
                }
            }
        }
        if queueHead > 1024 && queueHead * 2 >= queue.count { queue.removeFirst(queueHead); queueHead = 0 }
    }

    private func store(_ values: [String: String], for key: JSONFieldCache.Key) {
        let superseded = order.filter {
            $0.owner == key.owner && $0.request == key.request && $0.context.first == key.context.first && $0 != key
        }
        for old in superseded {
            cached[old] = nil; bytes -= costs.removeValue(forKey: old) ?? 0
        }
        if !superseded.isEmpty { order.removeAll { superseded.contains($0) } }
        let merged = (cached[key] ?? [:]).merging(values) { _, new in new }
        let charge = merged.reduce(key.estimatedCost) { $0 + $1.key.utf8.count + $1.value.utf8.count + 128 }
        bytes -= costs.removeValue(forKey: key) ?? 0
        cached[key] = nil; order.removeAll { $0 == key }
        guard charge <= byteLimit else { return }
        while !order.isEmpty && (order.count >= entryLimit || bytes + charge > byteLimit) {
            let removed = order.removeFirst()
            cached[removed] = nil; bytes -= costs.removeValue(forKey: removed) ?? 0
        }
        cached[key] = merged; costs[key] = charge; order.append(key); bytes += charge
        schedulePublication()
    }

    private func schedulePublication() {
        guard !publicationScheduled else { return }
        publicationScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40)) { [weak self] in
            self?.publicationScheduled = false
            self?.objectWillChange.send()
        }
    }

    func clear() {
        // Sort owners must cancel their immutable snapshot batches before the
        // actor cache is cleared, otherwise an old batch can fill it again.
        NotificationCenter.default.post(name: .pmJSONColumnCacheWillClear, object: self)
        generation &+= 1
        for job in jobs.values { job.task?.cancel() }
        jobs.removeAll(); queue.removeAll(); queueHead = 0; cached.removeAll(); order.removeAll(); costs.removeAll(); bytes = 0
        objectWillChange.send()
        Task { await JSONFieldCache.shared.clear(); await DerivedFieldCache.shared.clear() }
    }
}
