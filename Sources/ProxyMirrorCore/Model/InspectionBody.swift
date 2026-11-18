import Foundation

/// A bounded decoded view of captured bytes. Capture and replay always retain the wire body.
enum InspectionBody {
    private struct Key: Hashable {
        let transaction: ObjectIdentifier
        let request: Bool
        let limit: Int
        let prefix: Bool
    }

    private final class Entry {
        weak var owner: Transaction?
        let revision: UInt64
        let encodings: [String]
        let data: Data?

        init(owner: Transaction, revision: UInt64, encodings: [String], data: Data?) {
            self.owner = owner
            self.revision = revision
            self.encodings = encodings
            self.data = data
        }
    }

    private static let lock = NSLock()
    private static var cache: [Key: Entry] = [:]
    private static var order: [Key] = []
    private static var cachedBytes = 0
    private static let byteLimit = 8 * 1024 * 1024

    static func data(for tx: Transaction, request: Bool, limit: Int, prefix: Bool = false) -> Data? {
        guard !Task.isCancelled else { return nil }
        let limit = max(0, limit)
        let headers = request ? tx.requestHeaders : tx.responseHeaders
        let encodings = headers.values(of: "Content-Encoding").flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0 != "identity" }
        let body = request ? tx.requestBody : tx.responseBody
        if encodings.isEmpty {
            return prefix ? Data(body.prefix(limit)) : (body.count <= limit ? body : nil)
        }
        // A partial compressed stream must not masquerade as decoded application data.
        guard request ? tx.requestBodyComplete && !tx.requestTruncated
                      : tx.responseBodyComplete && !tx.responseTruncated else { return nil }
        let revision = request ? tx.requestBodyRevision : tx.responseBodyRevision
        let key = Key(transaction: ObjectIdentifier(tx), request: request, limit: limit, prefix: prefix)
        lock.lock()
        if let entry = cache[key], entry.owner === tx, entry.revision == revision, entry.encodings == encodings {
            let result = entry.data
            lock.unlock()
            return result
        }
        lock.unlock()

        let result: Data?
        if body.isEmpty {
            result = Data()
        } else if case .success(let decoded) = ContentCoding.decodeIfCompressed(
            body, encodings: encodings, maxOutputBytes: limit, allowTruncatedOutput: prefix) {
            result = decoded.0
        } else {
            result = nil
        }
        // Decoder cancellation is transient, unlike an invalid body at a fixed revision.
        guard !Task.isCancelled else { return nil }
        lock.lock()
        if let previous = cache.removeValue(forKey: key) { cachedBytes -= previous.data?.count ?? 0 }
        order.removeAll { $0 == key }
        while !order.isEmpty && (order.count >= 64 || cachedBytes + (result?.count ?? 0) > byteLimit) {
            let oldest = order.removeFirst()
            cachedBytes -= cache.removeValue(forKey: oldest)?.data?.count ?? 0
        }
        if (result?.count ?? 0) <= byteLimit {
            cache[key] = Entry(owner: tx, revision: revision, encodings: encodings, data: result)
            order.append(key)
            cachedBytes += result?.count ?? 0
        }
        lock.unlock()
        return result
    }
}
