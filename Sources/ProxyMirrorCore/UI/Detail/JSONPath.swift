import Foundation

enum JSONPath {
    static let maxInputBytes = 1_048_576

    static func select(_ expression: String, from data: Data) throws -> [Any] {
        guard data.count <= maxInputBytes else { throw QueryError(Strings.Detail.jsonpathQueriesSupportBodiesUpTo1Mib) }
        guard expression.utf8.count <= 8192 else { throw QueryError(Strings.Detail.theJsonpathExpressionIsTooLong) }
        var parser = Parser(expression)
        let segments = try parser.parse()
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw QueryError(Strings.Detail.unableToParseTheBodyAsJson)
        }

        var nodes = [root]
        var remainingWork = 200_000
        for segment in segments {
            var next: [Any] = []
            for node in nodes {
                var pending = [node]
                while let candidate = pending.popLast() {
                    remainingWork -= segment.selectors.count
                    guard remainingWork >= 0 else { throw QueryError(Strings.Detail.theQueryScopeIsTooLargeNarrowTheJsonpathSelection) }
                    try Task.checkCancellation()
                    for selector in segment.selectors {
                        try selector.appendMatches(in: candidate, to: &next)
                    }
                    if segment.descendant {
                        pending.append(contentsOf: children(of: candidate).reversed())
                    }
                }
            }
            nodes = next
        }
        try Task.checkCancellation()
        return nodes
    }

    private static func children(of node: Any) -> [Any] {
        if let list = node as? [Any] { return list }
        guard let map = node as? [String: Any] else { return [] }
        return map.keys.sorted().compactMap { map[$0] }
    }

    private struct Segment {
        let descendant: Bool
        let selectors: [Selector]
    }

    private enum Selector {
        case name(String)
        case index(Int)
        case wildcard
        case slice(start: Int?, end: Int?, step: Int)

        func appendMatches(in node: Any, to matches: inout [Any]) throws {
            switch self {
            case .name(let key):
                if let value = (node as? [String: Any])?[key] { try append([value], to: &matches) }
            case .index(let index):
                guard let list = node as? [Any] else { return }
                let offset = index < 0 ? list.count + index : index
                if list.indices.contains(offset) { try append([list[offset]], to: &matches) }
            case .wildcard:
                try append(JSONPath.children(of: node), to: &matches)
            case .slice(let start, let end, let step):
                guard let list = node as? [Any], step != 0 else { return }
                let ascending = step > 0
                let lower = ascending ? 0 : -1
                let upper = ascending ? list.count : list.count - 1
                func clamp(_ index: Int) -> Int {
                    min(upper, max(lower, index < 0 ? list.count + index : index))
                }
                var index = start.map(clamp) ?? (ascending ? lower : upper)
                let limit = end.map(clamp) ?? (ascending ? upper : lower)
                while ascending ? index < limit : index > limit {
                    try append([list[index]], to: &matches)
                    index += step
                }
            }
        }

        private func append(_ values: [Any], to matches: inout [Any]) throws {
            guard matches.count + values.count <= 5000 else {
                throw QueryError(Strings.Detail.moreThan5000NodesMatchedNarrowTheJsonpathSelection)
            }
            matches.append(contentsOf: values)
        }
    }

    private struct Parser {
        private let input: [Unicode.Scalar]
        private var position = 0

        init(_ text: String) {
            input = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars)
        }

        private var current: Unicode.Scalar? { position < input.count ? input[position] : nil }

        mutating func parse() throws -> [Segment] {
            guard take("$") else { throw QueryError(Strings.Detail.aJsonpathExpressionMustStartWith) }
            var segments: [Segment] = []
            skipSpace()
            while current != nil {
                guard segments.count < 128 else { throw syntax(Strings.Detail.tooManyPathLevels) }
                if take(".") {
                    let descendant = take(".")
                    if descendant, take("[") {
                        segments.append(Segment(descendant: true, selectors: try bracket()))
                    } else {
                        let selector: Selector = take("*") ? .wildcard : .name(try member())
                        segments.append(Segment(descendant: descendant, selectors: [selector]))
                    }
                } else if take("[") {
                    segments.append(Segment(descendant: false, selectors: try bracket()))
                } else {
                    throw syntax(Strings.Detail.expectedAMemberIndexOrWildcard)
                }
                skipSpace()
            }
            return segments
        }

        private mutating func bracket() throws -> [Selector] {
            var selectors: [Selector] = []
            repeat {
                skipSpace()
                guard selectors.count < 128 else { throw syntax(Strings.Detail.tooManySelectors) }
                if take("*") {
                    selectors.append(.wildcard)
                } else if let quote = current, quote == "'" || quote == "\"" {
                    position += 1
                    selectors.append(.name(try quoted(quote)))
                } else if current == "?" {
                    throw syntax(Strings.Detail.useJqForFilterExpressions)
                } else {
                    let start = try integer()
                    skipSpace()
                    if take(":") {
                        skipSpace()
                        let end = try integer()
                        skipSpace()
                        var step: Int?
                        if take(":") {
                            skipSpace()
                            step = try integer()
                        }
                        selectors.append(.slice(start: start, end: end, step: step ?? 1))
                    } else if let start {
                        selectors.append(.index(start))
                    } else {
                        throw syntax(Strings.Detail.expectedAQuotedMemberNameIndexOrSlice)
                    }
                }
                skipSpace()
            } while take(",")
            guard take("]") else { throw syntax(Strings.Detail.missing) }
            return selectors
        }

        private mutating func member() throws -> String {
            guard let first = current, isNameStart(first) else { throw syntax(Strings.Detail.missingMemberName) }
            let start = position
            position += 1
            while let scalar = current, isNameStart(scalar) || isDigit(scalar) {
                position += 1
            }
            return String(String.UnicodeScalarView(input[start..<position]))
        }

        private func isNameStart(_ scalar: Unicode.Scalar) -> Bool {
            (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
                || scalar == "_" || scalar.value >= 128
        }

        private func isDigit(_ scalar: Unicode.Scalar) -> Bool { (48...57).contains(scalar.value) }

        private mutating func integer() throws -> Int? {
            let start = position
            let negative = take("-")
            let digits = position
            while let scalar = current, isDigit(scalar) { position += 1 }
            guard digits < position else {
                if negative { throw syntax(Strings.Detail.expectedANumber) }
                return nil
            }
            if input[digits] == "0" && (negative || position - digits > 1) {
                throw syntax(Strings.Detail.invalidNumericIndex)
            }
            let text = String(String.UnicodeScalarView(input[start..<position]))
            guard let value = Int(text), (-9_007_199_254_740_991...9_007_199_254_740_991).contains(value) else {
                throw syntax(Strings.Detail.indexOutOfRange)
            }
            return value
        }

        private mutating func quoted(_ quote: Unicode.Scalar) throws -> String {
            var json = "\""
            while let scalar = current {
                position += 1
                if scalar == quote {
                    json += "\""
                    guard let value = try? JSONSerialization.jsonObject(
                        with: Data(json.utf8), options: [.fragmentsAllowed]
                    ) as? String else { throw syntax(Strings.Detail.invalidEscapeInMemberName) }
                    return value
                }
                if scalar == "\\" {
                    guard let escaped = current else { throw syntax(Strings.Detail.incompleteMemberNameEscape) }
                    position += 1
                    if escaped == "'" && quote == "'" { json += "'" }
                    else {
                        json += "\\"
                        json.unicodeScalars.append(escaped)
                    }
                } else {
                    if scalar == "\"" { json += "\\" }
                    json.unicodeScalars.append(scalar)
                }
            }
            throw syntax(Strings.Detail.missingClosingQuoteInMemberName)
        }

        private mutating func take(_ scalar: Unicode.Scalar) -> Bool {
            guard current == scalar else { return false }
            position += 1
            return true
        }

        private mutating func skipSpace() {
            while let scalar = current, CharacterSet.whitespacesAndNewlines.contains(scalar) { position += 1 }
        }

        private func syntax(_ message: String) -> QueryError {
            QueryError(Strings.Detail.jsonpathNearCharacter(position + 1, message))
        }
    }
}

struct QueryError: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
