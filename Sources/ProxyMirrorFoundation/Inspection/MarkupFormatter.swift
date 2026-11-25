import Foundation

/// A bounded lexical formatter. Mixed text and whitespace-sensitive elements keep
/// their original bytes; invalid input is returned unchanged.
package enum MarkupFormatter {
    package struct Result: Sendable, Equatable {
        package let text: String
        package let formatted: Bool
    }
    private struct Token {
        enum Kind { case open(String), close(String), single, text }
        let kind: Kind
        let range: Range<String.Index>
    }

    package static func format(_ source: String, html: Bool = false) -> Result {
        guard source.utf8.count <= 2_097_152, let tokens = tokenize(source, html: html) else {
            return Result(text: source, formatted: false)
        }
        var stack: [Int] = [], ends: [Int: Int] = [:], inline: Set<Int> = []
        var roots = 0
        for (index, token) in tokens.enumerated() {
            switch token.kind {
            case .open:
                if stack.isEmpty { roots += 1 }
                guard stack.count < 256 else { return Result(text: source, formatted: false) }
                stack.append(index)
            case .close(let name):
                guard let opening = stack.popLast(), case .open(let expected) = tokens[opening].kind,
                      name == expected else { return Result(text: source, formatted: false) }
                ends[opening] = index
            case .text:
                let text = String(source[token.range])
                if !html, !text.hasPrefix("<![CDATA["), (!validEntities(text) || text.contains("]]>")) { return Result(text: source, formatted: false) }
                if !source[token.range].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard let parent = stack.last else { return Result(text: source, formatted: false) }
                    inline.insert(parent)
                }
            case .single:
                if stack.isEmpty, source[token.range].hasPrefix("<"),
                   !source[token.range].hasPrefix("<!"), !source[token.range].hasPrefix("<?") { roots += 1 }
            }
        }
        guard stack.isEmpty, roots == 1 else { return Result(text: source, formatted: false) }
        var lines: [String] = [], depth = 0, index = 0
        while index < tokens.count {
            let token = tokens[index]
            let text = String(source[token.range])
            switch token.kind {
            case .text:
                break // Non-whitespace text is emitted with its containing element.
            case .close:
                depth -= 1
                lines.append(String(repeating: "  ", count: max(0, depth)) + text)
            case .single:
                lines.append(String(repeating: "  ", count: depth) + text)
            case .open(let name):
                if let end = ends[index], inline.contains(index) || ["pre", "textarea", "script", "style"].contains(name.lowercased()) {
                    lines.append(String(repeating: "  ", count: depth) + source[token.range.lowerBound..<tokens[end].range.upperBound])
                    index = end
                } else if let end = ends[index], end == index + 1 {
                    lines.append(String(repeating: "  ", count: depth) + source[token.range.lowerBound..<tokens[end].range.upperBound])
                    index = end
                } else {
                    lines.append(String(repeating: "  ", count: depth) + text)
                    depth += 1
                }
            }
            index += 1
        }
        return Result(text: lines.joined(separator: "\n"), formatted: true)
    }

    private static func tokenize(_ source: String, html: Bool) -> [Token]? {
        let voids: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
        var result: [Token] = [], index = source.startIndex
        func append(_ kind: Token.Kind, _ end: String.Index) { result.append(Token(kind: kind, range: index..<end)); index = end }
        while index < source.endIndex {
            guard result.count < 100_000 else { return nil }
            if source[index] != "<" {
                let end = source[index...].firstIndex(of: "<") ?? source.endIndex
                append(.text, end); continue
            }
            let tail = source[index...]
            if tail.hasPrefix("<!--") || tail.hasPrefix("<![CDATA[") || tail.hasPrefix("<?") {
                let terminator = tail.hasPrefix("<!--") ? "-->" : tail.hasPrefix("<?") ? "?>" : "]]>"
                guard let closing = tail.range(of: terminator) else { return nil }
                let end = closing.upperBound
                if tail.hasPrefix("<!--"), source[source.index(index, offsetBy: 4)..<closing.lowerBound].contains("--") { return nil }
                append(tail.hasPrefix("<![CDATA[") ? .text : .single, end); continue
            }
            // HTML's inert doctype is retained. XML internal subsets and external
            // entities are deliberately outside this formatter's bounded grammar.
            if html, tail.prefix(14).lowercased().hasPrefix("<!doctype html"), let end = tail.firstIndex(of: ">"),
               !tail[..<end].contains("[") {
                append(.single, source.index(after: end)); continue
            }
            if tail.hasPrefix("<!") { return nil }
            var cursor = source.index(after: index), quote: Character?
            while cursor < source.endIndex {
                let character = source[cursor]
                if let current = quote { if character == current { quote = nil } }
                else if character == "\"" || character == "'" { quote = character }
                else if character == ">" { break }
                else if character == "<" { return nil }
                cursor = source.index(after: cursor)
            }
            guard cursor < source.endIndex, quote == nil else { return nil }
            let end = source.index(after: cursor)
            let tagContent = String(source[source.index(after: index)..<cursor])
            guard tagContent.first?.isWhitespace == false else { return nil }
            var inside = tagContent.trimmingCharacters(in: .whitespacesAndNewlines)
            let closing = inside.hasPrefix("/")
            if closing { inside.removeFirst(); if inside.first?.isWhitespace != false { return nil } }
            let single = inside.hasSuffix("/")
            if single { guard tagContent.hasSuffix("/") else { return nil }; inside.removeLast() }
            let pieces = inside.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard let nameSlice = pieces.first, let first = nameSlice.first,
                  first.isLetter || first == "_" || first == ":",
                  nameSlice.allSatisfy({ $0.isLetter || $0.isNumber || "_:-.".contains($0) }) else { return nil }
            let name = html ? nameSlice.lowercased() : String(nameSlice)
            if closing, pieces.count != 1 || single { return nil }
            if pieces.count > 1, !validAttributes(String(pieces[1]), html: html) { return nil }
            append(closing ? .close(name) : single || (html && voids.contains(name)) ? .single : .open(name), end)
            if !closing, !single, ["pre", "textarea", "script", "style"].contains(name.lowercased()) {
                guard let closingRange = source[index...].range(of: "</\(name)>", options: html ? [.caseInsensitive] : []) else { return nil }
                if closingRange.lowerBound > index { append(.text, closingRange.lowerBound) }
                append(.close(name), closingRange.upperBound)
            }
        }
        return result
    }

    private static func validAttributes(_ text: String, html: Bool) -> Bool {
        var remainder = text[...], names: Set<String> = []
        while !remainder.isEmpty {
            remainder = remainder.drop(while: { $0.isWhitespace })
            if remainder.isEmpty { return true }
            let name = remainder.prefix(while: { !$0.isWhitespace && $0 != "=" })
            guard let first = name.first, first.isLetter || first == "_" || first == ":", name.allSatisfy({ $0.isLetter || $0.isNumber || "_:-.".contains($0) }), names.insert(String(name)).inserted else { return false }
            remainder = remainder.dropFirst(name.count).drop(while: { $0.isWhitespace })
            if !remainder.hasPrefix("=") { if html { continue }; return false }
            remainder = remainder.dropFirst().drop(while: { $0.isWhitespace })
            guard let quote = remainder.first else { return false }
            if quote == "\"" || quote == "'" {
                remainder = remainder.dropFirst()
                guard let end = remainder.firstIndex(of: quote) else { return false }
                let value = String(remainder[..<end])
                if !html, value.contains("<") || !validEntities(value) { return false }
                remainder = remainder[remainder.index(after: end)...]
                if !remainder.isEmpty, remainder.first?.isWhitespace == false { return false }
            } else {
                guard html else { return false }
                remainder = remainder.drop(while: { !$0.isWhitespace })
            }
        }
        return true
    }

    private static func validEntities(_ text: String) -> Bool {
        var tail = text[...]
        while let start = tail.firstIndex(of: "&") {
            let after = tail.index(after: start)
            guard let end = tail[after...].firstIndex(of: ";") else { return false }
            let entity = String(tail[after..<end])
            if !["amp", "lt", "gt", "apos", "quot"].contains(entity) {
                let number = entity.hasPrefix("#x") ? UInt32(entity.dropFirst(2), radix: 16)
                    : entity.hasPrefix("#") ? UInt32(entity.dropFirst(), radix: 10) : nil
                guard let number, UnicodeScalar(number) != nil,
                      number == 9 || number == 10 || number == 13 || number >= 32,
                      number != 0xFFFE, number != 0xFFFF else { return false }
            }
            tail = tail[tail.index(after: end)...]
        }
        return true
    }

}
