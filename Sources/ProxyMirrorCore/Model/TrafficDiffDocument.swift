import Foundation
import ProxyMirrorFoundation

/// Bounded comparison input. Captured wire bytes remain unchanged.
enum TrafficDiffDocument {
    enum Component: String, CaseIterable, Identifiable, Sendable {
        case url, request, response
        case requestHeaders, responseHeaders
        case requestBody, responseBody
        var id: String { rawValue }
        var localizedTitle: String {
            switch self {
            case .url: return Strings.Models.diffComponentUrl
            case .request: return Strings.Models.diffComponentRequest
            case .response: return Strings.Models.diffComponentResponse
            case .requestHeaders: return Strings.Models.diffComponentRequestHeaders
            case .responseHeaders: return Strings.Models.diffComponentResponseHeaders
            case .requestBody: return Strings.Models.diffComponentRequestBody
            case .responseBody: return Strings.Models.diffComponentResponseBody
            }
        }
    }

    enum Change: Equatable, Sendable { case equal, removed, inserted }
    struct Line: Sendable {
        let text: String
        let change: Change
    }
    struct Pair: Sendable {
        let left: String?
        let right: String?
        let changed: Bool
        let leftNumber: Int?
        let rightNumber: Int?
    }
    struct Result: Sendable {
        var unified: [Line]
        var pairs: [Pair]
        var inserted: Int
        var removed: Int
    }

    static let bodyLimit = BoundedDiffDocument.bodyLimit
    static let lineLimit = BoundedDiffDocument.lineLimit

    struct Identity: Hashable, Sendable {
        let owner: ObjectIdentifier
        let startLine: String?
        let headers: [BoundedDiffDocument.Header]
        let encodings: [String]
        let includesBody: Bool
        let revision: UInt64
        let complete: Bool
        let truncated: Bool
        let capturedBytes: Int
    }

    struct Snapshot: Sendable {
        let identity: Identity
        let wireBody: Data
    }

    /// Only immutable metadata and COW bytes leave the main actor. Computing a
    /// task key never decodes, formats or compares a captured message.
    @MainActor
    static func identity(_ transaction: Transaction, component: Component) -> Identity {
        if component == .url {
            return Identity(owner: ObjectIdentifier(transaction), startLine: transaction.originalURL ?? transaction.fullURL,
                            headers: [], encodings: [], includesBody: false, revision: 0, complete: true,
                            truncated: false, capturedBytes: 0)
        }
        let request = [.request, .requestHeaders, .requestBody].contains(component)
        let headersOnly = component == .requestHeaders || component == .responseHeaders
        let bodyOnly = component == .requestBody || component == .responseBody
        let headers = request ? transaction.requestHeaders : transaction.responseHeaders
        let start = bodyOnly || headersOnly ? nil : (request
            ? "\(transaction.method) \(transaction.originalURL ?? transaction.fullURL) \(transaction.requestVersion)"
            : "\(transaction.responseVersion) \(transaction.statusText)")
        return Identity(owner: ObjectIdentifier(transaction), startLine: start,
            headers: bodyOnly ? [] : headers.pairs.map { .init($0.name, $0.value) },
            encodings: headers.values(of: "Content-Encoding").flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty && $0 != "identity" },
            includesBody: !headersOnly,
            revision: headersOnly ? 0 : (request ? transaction.requestBodyRevision : transaction.responseBodyRevision),
            complete: headersOnly || (request ? transaction.requestBodyComplete : transaction.responseBodyComplete),
            truncated: !headersOnly && (request ? transaction.requestTruncated : transaction.responseTruncated),
            capturedBytes: headersOnly ? 0 : (request ? transaction.requestBody.count : transaction.responseBody.count))
    }

    @MainActor
    static func snapshot(_ transaction: Transaction, component: Component) -> Snapshot {
        let before = identity(transaction, component: component)
        let request = [.request, .requestHeaders, .requestBody].contains(component)
        let body = before.includesBody ? (request ? transaction.requestBody : transaction.responseBody) : Data()
        let after = identity(transaction, component: component)
        return Snapshot(identity: after, wireBody: before == after ? body : Data())
    }

    static func lines(_ snapshot: Snapshot, sortJSON: Bool, sortHeaders: Bool) throws -> [String] {
        try Task.checkCancellation()
        let key = snapshot.identity
        let body: Data?
        if !key.includesBody { body = nil }
        else if key.encodings.isEmpty { body = Data(snapshot.wireBody.prefix(bodyLimit)) }
        else if key.complete && !key.truncated {
            if snapshot.wireBody.isEmpty { body = Data() }
            else if case .success(let decoded) = ContentCoding.decodeIfCompressed(snapshot.wireBody, encodings: key.encodings,
                maxOutputBytes: bodyLimit, allowTruncatedOutput: true) { body = decoded.0 }
            else { body = nil }
        } else { body = nil }
        try Task.checkCancellation()
        return try BoundedDiffDocument.lines(.init(startLine: key.startLine, headers: key.headers,
            includesBody: key.includesBody, body: body,
            bodyWasLimited: key.truncated || key.capturedBytes >= bodyLimit || (body?.count ?? 0) >= bodyLimit),
            sortJSON: sortJSON, sortHeaders: sortHeaders,
            messages: .init(unavailable: Strings.Models.diffBodyUndecodable, bodyLimited: Strings.Models.diffBodyLimit,
                            linesLimited: Strings.Models.diffLineLimit(lineLimit), outputLimited: Strings.Models.diffOutputLimit))
    }

    /// Explicit synchronous adapter retained for model checks and non-UI callers.
    @MainActor
    static func lines(_ transaction: Transaction, component: Component, sortJSON: Bool, sortHeaders: Bool) -> [String] {
        (try? lines(snapshot(transaction, component: component), sortJSON: sortJSON, sortHeaders: sortHeaders)) ?? []
    }

    static func compare(_ before: [String], _ after: [String]) -> Result {
        guard !Task.isCancelled else { return Result(unified: [], pairs: [], inserted: 0, removed: 0) }
        let differences = after.difference(from: before)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in differences {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result = Result(unified: [], pairs: [], inserted: inserted.count, removed: removed.count)
        var left = 0, right = 0
        while left < before.count || right < after.count {
            guard !Task.isCancelled else { return Result(unified: [], pairs: [], inserted: 0, removed: 0) }
            var removals: [(Int, String)] = [], additions: [(Int, String)] = []
            while left < before.count, removed.contains(left) {
                result.unified.append(Line(text: before[left], change: .removed))
                removals.append((left + 1, before[left])); left += 1
            }
            while right < after.count, inserted.contains(right) {
                result.unified.append(Line(text: after[right], change: .inserted))
                additions.append((right + 1, after[right])); right += 1
            }
            if !removals.isEmpty || !additions.isEmpty {
                for index in 0..<max(removals.count, additions.count) {
                    let old = index < removals.count ? removals[index] : nil
                    let new = index < additions.count ? additions[index] : nil
                    result.pairs.append(Pair(left: old?.1, right: new?.1, changed: true,
                                             leftNumber: old?.0, rightNumber: new?.0))
                }
            } else if left < before.count, right < after.count {
                result.unified.append(Line(text: before[left], change: .equal))
                result.pairs.append(Pair(left: before[left], right: after[right], changed: false,
                                         leftNumber: left + 1, rightNumber: right + 1))
                left += 1; right += 1
            } else {
                // CollectionDifference contains every unmatched tail; this protects callers from a stalled loop.
                break
            }
        }
        return result
    }
}
