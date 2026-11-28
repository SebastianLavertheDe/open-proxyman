import Foundation
import Combine
import ProxyMirrorFoundation

struct TrafficCondition: Codable, Equatable, Identifiable {
    private static let bodyLimit = 1_048_576

    enum Field: String, Codable, CaseIterable {
        case url, host, ip, method, status
        case requestHeader, responseHeader, requestBody, responseBody
        case query, client, comment, duration
        case requestSize, responseSize, scheme
        case contentType, httpVersion, graphql

        var isNumeric: Bool { [.status, .duration, .requestSize, .responseSize].contains(self) }
        var localizedTitle: String {
            switch self {
            case .url: return Strings.Models.fieldUrl
            case .host: return Strings.Models.fieldHost
            case .ip: return Strings.Models.fieldIp
            case .method: return Strings.Models.fieldMethod
            case .status: return Strings.Models.fieldStatus
            case .requestHeader: return Strings.Models.fieldRequestHeader
            case .responseHeader: return Strings.Models.fieldResponseHeader
            case .requestBody: return Strings.Models.fieldRequestBody
            case .responseBody: return Strings.Models.fieldResponseBody
            case .query: return Strings.Models.fieldQuery
            case .client: return Strings.Models.fieldClient
            case .comment: return Strings.Models.fieldComment
            case .duration: return Strings.Models.fieldDuration
            case .requestSize: return Strings.Models.fieldRequestSize
            case .responseSize: return Strings.Models.fieldResponseSize
            case .scheme: return Strings.Models.fieldScheme
            case .contentType: return Strings.Models.fieldContentType
            case .httpVersion: return Strings.Models.fieldHttpVersion
            case .graphql: return Strings.Models.fieldGraphql
            }
        }
    }

    enum Comparison: String, Codable, CaseIterable {
        case contains, notContains, equals, notEquals
        case startsWith, notStartsWith, endsWith, notEndsWith
        case wildcard, notWildcard
        case regex, notRegex, atLeast, atMost
        case greaterThan, lessThan, between

        var isNumeric: Bool { [.atLeast, .atMost, .greaterThan, .lessThan, .between].contains(self) }
        var isNegative: Bool { [.notContains, .notEquals, .notStartsWith, .notEndsWith, .notWildcard, .notRegex].contains(self) }
        var usesRegex: Bool { [.regex, .notRegex, .wildcard, .notWildcard].contains(self) }
        var localizedTitle: String {
            switch self {
            case .contains: return Strings.Models.comparisonContains
            case .notContains: return Strings.Models.comparisonNotContains
            case .equals: return Strings.Models.comparisonEquals
            case .notEquals: return Strings.Models.comparisonNotEquals
            case .startsWith: return Strings.Models.comparisonStartsWith
            case .notStartsWith: return Strings.Models.comparisonNotStartsWith
            case .endsWith: return Strings.Models.comparisonEndsWith
            case .notEndsWith: return Strings.Models.comparisonNotEndsWith
            case .wildcard: return Strings.Models.comparisonWildcard
            case .notWildcard: return Strings.Models.comparisonNotWildcard
            case .regex: return Strings.Models.comparisonRegex
            case .notRegex: return Strings.Models.comparisonNotRegex
            case .atLeast: return Strings.Models.comparisonAtLeast
            case .atMost: return Strings.Models.comparisonAtMost
            case .greaterThan: return Strings.Models.comparisonGreaterThan
            case .lessThan: return Strings.Models.comparisonLessThan
            case .between: return Strings.Models.comparisonBetween
            }
        }
    }

    var id = UUID()
    var field = Field.url
    var comparison = Comparison.contains
    var value = ""

    private var range: [Double]? {
        let parts = value.components(separatedBy: "...").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lower = Double(parts[0]), let upper = Double(parts[1]),
              lower.isFinite, upper.isFinite, lower <= upper else { return nil }
        return [lower, upper]
    }

    private var expression: String {
        if comparison == .wildcard || comparison == .notWildcard {
            return "^" + value.map { character in
                switch character {
                case "*": return ".*"
                case "?": return "."
                default: return NSRegularExpression.escapedPattern(for: String(character))
                }
            }.joined() + "$"
        }
        return value
    }

    var isValid: Bool {
        guard !value.isEmpty else { return false }
        if comparison.isNumeric {
            guard field.isNumeric else { return false }
            return comparison == .between ? range != nil : Double(value)?.isFinite == true
        }
        if comparison.usesRegex {
            return value.utf8.count <= 4096 && (try? NSRegularExpression(pattern: expression, options: [.caseInsensitive])) != nil
        }
        return true
    }

    func compile() -> (Transaction) -> Bool {
        guard isValid else { return { _ in false } }
        let options: NSRegularExpression.Options = comparison == .wildcard || comparison == .notWildcard
            ? [.caseInsensitive, .dotMatchesLineSeparators] : [.caseInsensitive]
        let pattern = comparison.usesRegex ? try? BoundedTrafficRegex(pattern: expression, options: options) : nil
        let threshold = Double(value)
        let bounds = range
        let test: (Transaction) -> Bool = { tx in
            if comparison.isNumeric {
                let number: Double?
                switch field {
                case .duration: number = tx.state == .completed ? tx.duration * 1000 : nil
                case .status: number = tx.statusCode > 0 ? Double(tx.statusCode) : nil
                case .requestSize: number = Double(tx.requestBytes)
                case .responseSize: number = Double(tx.responseBytes)
                default: number = nil
                }
                guard let number else { return false }
                if comparison == .between, let bounds { return bounds[0] <= number && number <= bounds[1] }
                guard let threshold else { return false }
                switch comparison {
                case .atLeast: return number >= threshold
                case .atMost: return number <= threshold
                case .greaterThan: return number > threshold
                case .lessThan: return number < threshold
                default: return false
                }
            }
            let values: [String]
            switch field {
            case .url: values = [tx.fullURL, tx.originalURL].compactMap { $0 }
            case .host: values = [tx.host]
            case .ip: values = [tx.resolvedAddress, tx.clientAddress].compactMap { $0 }
            case .method: values = [tx.method]
            case .status: values = tx.statusCode > 0 ? [String(tx.statusCode)] : []
            case .requestHeader: values = tx.requestHeaders.pairs.map { "\($0.name): \($0.value)" }
            case .responseHeader: values = tx.responseHeaders.pairs.map { "\($0.name): \($0.value)" }
            case .requestBody:
                values = InspectionBody.data(for: tx, request: true, limit: Self.bodyLimit, prefix: true)
                    .map { [String(decoding: $0, as: UTF8.self)] } ?? []
            case .responseBody:
                values = InspectionBody.data(for: tx, request: false, limit: Self.bodyLimit, prefix: true)
                    .map { [String(decoding: $0, as: UTF8.self)] } ?? []
            case .query: values = [tx.query]
            case .client: values = [tx.clientName, tx.clientBundle].compactMap { $0 }
            case .comment: values = [tx.comment]
            case .duration: values = tx.state == .completed ? [String(Int((tx.duration * 1000).rounded()))] : []
            case .requestSize: values = [String(tx.requestBytes)]
            case .responseSize: values = [String(tx.responseBytes)]
            case .scheme:
                values = [tx.scheme, tx.isWebSocket ? "WS" : "", tx.graphqlOperationName != nil ? "GraphQL" : ""]
            case .contentType: values = [tx.contentType, tx.requestHeaders.value(of: "Content-Type")].compactMap { $0 }
            case .httpVersion:
                values = [tx.requestVersion, tx.statusCode > 0 ? tx.responseVersion : nil, tx.upstreamProtocol].compactMap { $0 }
            case .graphql: values = tx.graphqlOperationName.map { [$0] } ?? []
            }
            if comparison.usesRegex {
                guard let matched = pattern?.matchesAny(in: values) else { return false }
                return comparison.isNegative ? !matched : matched
            }
            let matched = values.contains { fieldValue in
                switch comparison {
                case .contains, .notContains: return fieldValue.localizedCaseInsensitiveContains(value)
                case .equals, .notEquals: return fieldValue.caseInsensitiveCompare(value) == .orderedSame
                case .startsWith, .notStartsWith: return fieldValue.lowercased().hasPrefix(value.lowercased())
                case .endsWith, .notEndsWith: return fieldValue.lowercased().hasSuffix(value.lowercased())
                default: return false
                }
            }
            return comparison.isNegative ? !matched : matched
        }
        guard field == .requestBody || field == .responseBody else { return test }
        let request = field == .requestBody
        let matches = NSMapTable<Transaction, BodyMatch>(
            keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)
        return { tx in
            guard !Task.isCancelled else { return false }
            let encodings = (request ? tx.requestHeaders : tx.responseHeaders).values(of: "Content-Encoding")
            let generation = encodings.isEmpty
                ? (request ? tx.requestBodyGeneration : tx.responseBodyGeneration)
                : (request ? tx.requestBodyRevision : tx.responseBodyRevision)
            let count = min(Self.bodyLimit, request ? tx.requestBody.count : tx.responseBody.count)
            let complete = request ? tx.requestBodyComplete : tx.responseBodyComplete
            let truncated = request ? tx.requestTruncated : tx.responseTruncated
            if let cached = matches.object(forKey: tx), cached.generation == generation, cached.count == count,
               cached.encodings == encodings, cached.complete == complete, cached.truncated == truncated {
                return cached.matches
            }
            let result = test(tx)
            guard !Task.isCancelled else { return false }
            matches.setObject(BodyMatch(generation: generation, count: count, encodings: encodings,
                                       complete: complete, truncated: truncated, matches: result), forKey: tx)
            return result
        }
    }

    /// List predicates defer only GraphQL-derived metadata. Pending is a third
    /// state, so negative comparisons and nested AND/OR cannot lose rows.
    @MainActor
    func compileForPresentation() -> (Transaction) -> PresentationPredicateResult {
        guard isValid else { return { _ in .notMatched } }
        guard field == .graphql || field == .scheme else {
            let test = compile()
            return { test($0) ? .matched : .notMatched }
        }
        let matcher = compileStrings()
        let condition = PresentedGraphQLCondition(scheme: field == .scheme, matches: matcher)
        return { condition.evaluate($0) }
    }

    private func compileStrings() -> ([String]) -> Bool {
        let options: NSRegularExpression.Options = comparison == .wildcard || comparison == .notWildcard
            ? [.caseInsensitive, .dotMatchesLineSeparators] : [.caseInsensitive]
        let pattern = comparison.usesRegex ? try? BoundedTrafficRegex(pattern: expression, options: options) : nil
        return { values in
            if comparison.usesRegex {
                guard let matched = pattern?.matchesAny(in: values) else { return false }
                return comparison.isNegative ? !matched : matched
            }
            let matched = values.contains { fieldValue in
                switch comparison {
                case .contains, .notContains: return fieldValue.localizedCaseInsensitiveContains(value)
                case .equals, .notEquals: return fieldValue.caseInsensitiveCompare(value) == .orderedSame
                case .startsWith, .notStartsWith: return fieldValue.lowercased().hasPrefix(value.lowercased())
                case .endsWith, .notEndsWith: return fieldValue.lowercased().hasSuffix(value.lowercased())
                default: return false
                }
            }
            return comparison.isNegative ? !matched : matched
        }
    }

    private final class BodyMatch {
        let generation: UInt64
        let count: Int
        let encodings: [String]
        let complete: Bool
        let truncated: Bool
        let matches: Bool

        init(generation: UInt64, count: Int, encodings: [String], complete: Bool, truncated: Bool, matches: Bool) {
            self.generation = generation
            self.count = count
            self.encodings = encodings
            self.complete = complete
            self.truncated = truncated
            self.matches = matches
        }
    }
}

struct TrafficConditionGroup: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        case all, any
        var localizedTitle: String {
            switch self {
            case .all: return Strings.Models.conditionGroupAll
            case .any: return Strings.Models.conditionGroupAny
            }
        }
    }

    var mode = Mode.all
    var conditions: [TrafficCondition] = []
    var groups: [TrafficConditionGroup]?

    var isValid: Bool { conditions.allSatisfy(\.isValid) && (groups ?? []).allSatisfy(\.isValid) }
    var isEmpty: Bool { conditions.isEmpty && (groups ?? []).allSatisfy(\.isEmpty) }
    var conditionCount: Int { conditions.count + (groups ?? []).reduce(0) { $0 + $1.conditionCount } }

    var readsBody: Bool {
        conditions.contains { [.requestBody, .responseBody, .graphql, .scheme].contains($0.field) } || (groups ?? []).contains { $0.readsBody }
    }

    @MainActor
    func compileForPresentation() -> (Transaction) -> PresentationPredicateResult {
        let tests = conditions.map { $0.compileForPresentation() } + (groups ?? []).map { $0.compileForPresentation() }
        guard !tests.isEmpty else { return { _ in .matched } }
        switch mode {
        case .all: return { tx in PresentationPredicateResult.all(tests.lazy.map { $0(tx) }) }
        case .any: return { tx in PresentationPredicateResult.any(tests.lazy.map { $0(tx) }) }
        }
    }

    func compile() -> (Transaction) -> Bool {
        let tests = conditions.map { $0.compile() } + (groups ?? []).map { $0.compile() }
        if tests.isEmpty { return { _ in true } }
        switch mode {
        case .all: return { tx in tests.allSatisfy { $0(tx) } }
        case .any: return { tx in tests.contains { $0(tx) } }
        }
    }
}

struct SavedTrafficFilter: Codable, Identifiable {
    var id = UUID()
    let name: String
    let group: TrafficConditionGroup
    var highlightName: String? = nil

    static let defaultsKey = "ui.savedTrafficFilters"
}

/// Per-predicate Boolean memo survives scalar-cache eviction. The immediate
/// completion event is consumed before a throttled list refilter can run; a
/// 50k-row filter therefore progresses even with an 8 MiB metadata cache.
@MainActor
private final class PresentedGraphQLCondition {
    private final class Stamp {
        let key: JSONFieldCache.Key
        let scheme: String
        let webSocket: Bool
        var matched: Bool?
        init(_ tx: Transaction, key: JSONFieldCache.Key, matched: Bool? = nil) {
            self.key = key; scheme = tx.scheme; webSocket = tx.isWebSocket; self.matched = matched
        }
        func isCurrent(_ tx: Transaction, key: JSONFieldCache.Key) -> Bool {
            self.key == key && scheme == tx.scheme && webSocket == tx.isWebSocket
        }
    }
    private let scheme: Bool
    private let matches: ([String]) -> Bool
    private let memo = NSMapTable<Transaction, Stamp>(keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)
    private var changes: AnyCancellable?
    init(scheme: Bool, matches: @escaping ([String]) -> Bool) {
        self.scheme = scheme; self.matches = matches
        changes = NotificationCenter.default.publisher(for: .pmGraphQLValueReady).sink { [weak self] notification in
            guard let self, let event = notification.object as? CustomColumnValues.GraphQLReady,
                  let stamp = self.memo.object(forKey: event.transaction), stamp.matched == nil,
                  stamp.isCurrent(event.transaction, key: event.key) else { return }
            stamp.matched = self.match(event.transaction, name: event.value)
        }
    }
    private func match(_ tx: Transaction, name: String) -> Bool {
        matches(scheme ? [tx.scheme, tx.isWebSocket ? "WS" : "", name.isEmpty ? "" : "GraphQL"] : (name.isEmpty ? [] : [name]))
    }
    func evaluate(_ tx: Transaction) -> PresentationPredicateResult {
        if scheme {
            let absent = match(tx, name: ""), present = match(tx, name: "GraphQL")
            if absent == present { return absent ? .matched : .notMatched }
        }
        let key = CustomColumnValues.shared.graphqlKey(for: tx)
        if let stamp = memo.object(forKey: tx), stamp.isCurrent(tx, key: key), let matched = stamp.matched {
            return matched ? .matched : .notMatched
        }
        switch CustomColumnValues.shared.graphqlState(for: tx) {
        case .pending:
            memo.setObject(Stamp(tx, key: key), forKey: tx)
            return .pending
        case .ready(let name):
            let matched = match(tx, name: name)
            memo.setObject(Stamp(tx, key: key, matched: matched), forKey: tx)
            return matched ? .matched : .notMatched
        }
    }
}
