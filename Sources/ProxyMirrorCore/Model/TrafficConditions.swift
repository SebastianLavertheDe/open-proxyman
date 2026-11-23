import Foundation

struct TrafficCondition: Codable, Equatable, Identifiable {
    private static let bodyLimit = 1_048_576

    enum Field: String, Codable, CaseIterable {
        case url = "URL", host = "Host", ip = "IP", method = "方法", status = "状态码"
        case requestHeader = "请求头", responseHeader = "响应头", requestBody = "请求正文", responseBody = "响应正文"
        case query = "Query", client = "客户端", comment = "注释", duration = "耗时 (ms)"
        case requestSize = "请求大小 (bytes)", responseSize = "响应大小 (bytes)", scheme = "Scheme"
        case contentType = "Content-Type", httpVersion = "HTTP 协议", graphql = "GraphQL 操作名"

        var isNumeric: Bool { [.status, .duration, .requestSize, .responseSize].contains(self) }
    }

    enum Comparison: String, Codable, CaseIterable {
        case contains = "包含", notContains = "不包含", equals = "等于", notEquals = "不等于"
        case startsWith = "前缀", notStartsWith = "非前缀", endsWith = "后缀", notEndsWith = "非后缀"
        case wildcard = "通配", notWildcard = "非通配"
        case regex = "正则", notRegex = "非正则", atLeast = "至少", atMost = "至多"
        case greaterThan = "大于", lessThan = "小于", between = "区间"

        var isNumeric: Bool { [.atLeast, .atMost, .greaterThan, .lessThan, .between].contains(self) }
        var isNegative: Bool { [.notContains, .notEquals, .notStartsWith, .notEndsWith, .notWildcard, .notRegex].contains(self) }
        var usesRegex: Bool { [.regex, .notRegex, .wildcard, .notWildcard].contains(self) }
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
        let pattern = comparison.usesRegex ? try? NSRegularExpression(pattern: expression, options: options) : nil
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
            let matched = values.contains { fieldValue in
                switch comparison {
                case .contains, .notContains: return fieldValue.localizedCaseInsensitiveContains(value)
                case .equals, .notEquals: return fieldValue.caseInsensitiveCompare(value) == .orderedSame
                case .startsWith, .notStartsWith: return fieldValue.lowercased().hasPrefix(value.lowercased())
                case .endsWith, .notEndsWith: return fieldValue.lowercased().hasSuffix(value.lowercased())
                case .regex, .notRegex, .wildcard, .notWildcard:
                    let range = NSRange(fieldValue.startIndex..., in: fieldValue)
                    return pattern?.firstMatch(in: fieldValue, range: range) != nil
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
        case all = "全部匹配 (AND)", any = "任一匹配 (OR)"
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
