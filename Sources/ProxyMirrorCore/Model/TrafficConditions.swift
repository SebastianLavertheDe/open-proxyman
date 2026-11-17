import Foundation

struct TrafficCondition: Codable, Equatable, Identifiable {
    private static let bodyLimit = 1_048_576

    enum Field: String, Codable, CaseIterable {
        case url = "URL", method = "方法", status = "状态码", requestHeader = "请求头", responseHeader = "响应头"
        case requestBody = "请求正文", responseBody = "响应正文", client = "客户端", duration = "耗时 (ms)"
        case httpVersion = "HTTP 协议", graphql = "GraphQL 操作名"
    }

    enum Comparison: String, Codable, CaseIterable {
        case contains = "包含", equals = "等于", regex = "正则", atLeast = "至少"
    }

    var id = UUID()
    var field = Field.url
    var comparison = Comparison.contains
    var value = ""

    var isValid: Bool {
        guard !value.isEmpty else { return false }
        switch comparison {
        case .regex: return (try? NSRegularExpression(pattern: value, options: [.caseInsensitive])) != nil
        case .atLeast: return (field == .duration || field == .status) && Double(value)?.isFinite == true
        default: return true
        }
    }

    func compile() -> (Transaction) -> Bool {
        let pattern = comparison == .regex ? try? NSRegularExpression(pattern: value, options: [.caseInsensitive]) : nil
        let threshold = Double(value)
        let test: (Transaction) -> Bool = { tx in
            if comparison == .atLeast, let threshold {
                if field == .duration { return tx.state == .completed && tx.duration * 1000 >= threshold }
                if field == .status { return tx.statusCode > 0 && Double(tx.statusCode) >= threshold }
            }
            let values: [String]
            switch field {
            case .url: values = [tx.fullURL, tx.originalURL].compactMap { $0 }
            case .method: values = [tx.method]
            case .status: values = tx.statusCode > 0 ? [String(tx.statusCode)] : []
            case .requestHeader: values = tx.requestHeaders.pairs.map { "\($0.name): \($0.value)" }
            case .responseHeader: values = tx.responseHeaders.pairs.map { "\($0.name): \($0.value)" }
            case .requestBody: values = [String(decoding: tx.requestBody.prefix(Self.bodyLimit), as: UTF8.self)]
            case .responseBody: values = [String(decoding: tx.responseBody.prefix(Self.bodyLimit), as: UTF8.self)]
            case .client: values = [tx.clientName, tx.clientBundle].compactMap { $0 }
            case .duration: values = tx.state == .completed ? [String(Int((tx.duration * 1000).rounded()))] : []
            case .httpVersion:
                values = [tx.requestVersion, tx.statusCode > 0 ? tx.responseVersion : nil, tx.upstreamProtocol].compactMap { $0 }
            case .graphql: values = tx.graphqlOperationName.map { [$0] } ?? []
            }
            return values.contains { fieldValue in
                switch comparison {
                case .contains: return fieldValue.localizedCaseInsensitiveContains(value)
                case .equals: return fieldValue.caseInsensitiveCompare(value) == .orderedSame
                case .regex:
                    let range = NSRange(fieldValue.startIndex..., in: fieldValue)
                    return pattern?.firstMatch(in: fieldValue, range: range) != nil
                case .atLeast: return false
                }
            }
        }
        guard field == .requestBody || field == .responseBody else { return test }
        let request = field == .requestBody
        let matches = NSMapTable<Transaction, BodyMatch>(
            keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)
        return { tx in
            let generation = request ? tx.requestBodyGeneration : tx.responseBodyGeneration
            let count = min(Self.bodyLimit, request ? tx.requestBody.count : tx.responseBody.count)
            if let cached = matches.object(forKey: tx), cached.generation == generation, cached.count == count {
                return cached.matches
            }
            let result = test(tx)
            matches.setObject(BodyMatch(generation: generation, count: count, matches: result), forKey: tx)
            return result
        }
    }

    private final class BodyMatch {
        let generation: UInt64
        let count: Int
        let matches: Bool

        init(generation: UInt64, count: Int, matches: Bool) {
            self.generation = generation
            self.count = count
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

    var readsBody: Bool {
        conditions.contains { $0.field == .requestBody || $0.field == .responseBody || $0.field == .graphql }
    }

    func compile() -> (Transaction) -> Bool {
        let tests = conditions.map { $0.compile() }
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

    static let defaultsKey = "ui.savedTrafficFilters"
}

