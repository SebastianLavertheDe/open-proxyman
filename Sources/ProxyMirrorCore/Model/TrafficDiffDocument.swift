import Foundation

/// Bounded comparison input. Captured wire bytes remain unchanged.
enum TrafficDiffDocument {
    enum Component: String, CaseIterable, Identifiable {
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

    static let bodyLimit = 262_144
    static let lineLimit = 1200

    static func lines(_ transaction: Transaction, component: Component, sortJSON: Bool, sortHeaders: Bool) -> [String] {
        if component == .url { return [transaction.originalURL ?? transaction.fullURL] }
        let request = [.request, .requestHeaders, .requestBody].contains(component)
        let headersOnly = component == .requestHeaders || component == .responseHeaders
        let bodyOnly = component == .requestBody || component == .responseBody
        var result: [String] = []
        if !bodyOnly {
            if !headersOnly {
                result.append(request
                    ? "\(transaction.method) \(transaction.originalURL ?? transaction.fullURL) \(transaction.requestVersion)"
                    : "\(transaction.responseVersion) \(transaction.statusText)")
            }
            let headers = request ? transaction.requestHeaders : transaction.responseHeaders
            var entries = headers.pairs.map { ($0.name, $0.value) }
            if sortHeaders {
                entries = entries.sorted { lhs, rhs in
                    let order = lhs.0.localizedCaseInsensitiveCompare(rhs.0)
                    return order == .orderedSame ? lhs.1 < rhs.1 : order == .orderedAscending
                }
            }
            result += entries.map { "\($0.0): \($0.1)" }
        }
        guard !headersOnly else { return bounded(result) }
        if !bodyOnly { result.append("") }
        guard let data = InspectionBody.data(for: transaction, request: request, limit: bodyLimit, prefix: true) else {
            return result + [Strings.Models.diffBodyUndecodable]
        }
        let text: String
        if sortJSON, let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed]),
           let formattedText = String(data: formatted, encoding: .utf8) {
            text = formattedText
        } else if let decoded = String(data: data, encoding: .utf8) {
            text = decoded.replacingOccurrences(of: "\r\n", with: "\n")
        } else {
            text = stride(from: 0, to: data.count, by: 16).map { offset in
                String(format: "%08x  ", offset) + data[offset..<min(data.count, offset + 16)]
                    .map { String(format: "%02x", $0) }.joined(separator: " ")
            }.joined(separator: "\n")
        }
        result += text.components(separatedBy: "\n")
        let truncated = request ? transaction.requestTruncated : transaction.responseTruncated
        let capturedCount = request ? transaction.requestBody.count : transaction.responseBody.count
        if truncated || capturedCount > bodyLimit || data.count >= bodyLimit {
            result.append(Strings.Models.diffBodyLimit)
        }
        return bounded(result)
    }

    private static func bounded(_ lines: [String]) -> [String] {
        guard lines.count > lineLimit else { return lines }
        return Array(lines.prefix(lineLimit)) + [Strings.Models.diffLineLimit(lineLimit)]
    }

    static func compare(_ before: [String], _ after: [String]) -> Result {
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
