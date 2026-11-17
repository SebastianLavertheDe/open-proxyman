import SwiftUI

/// 轻量 JSON 语法高亮器（分段拼接，避免索引换算）
enum JSONHighlighter {
    // Proxyman 实测色板（Assets.car: treeview-*/raw-content-*，见 UI-SPEC.md）
    static let keyColor = ProxymanTheme.jsonKey
    static let stringColor = ProxymanTheme.jsonString
    static let numberColor = ProxymanTheme.jsonNumber
    static let boolNullColor = ProxymanTheme.jsonBoolNull
    static let punctColor = Color.secondary

    static func highlight(_ text: String) -> AttributedString {
        var out = AttributedString()
        for (piece, color) in tokenize(text) {
            var seg = AttributedString(piece)
            if let color {
                seg.foregroundColor = color
            }
            out += seg
        }
        return out
    }

    private static func tokenize(_ text: String) -> [(String, Color?)] {
        var result: [(String, Color?)] = []
        var current = String()
        let chars = Array(text)

        func flush() {
            if !current.isEmpty {
                result.append((current, nil))
                current = String()
            }
        }

        var i = 0
        while i < chars.count {
            let c = chars[i]

            if c == "\"" {
                // 字符串 token（处理转义）
                var j = i + 1
                while j < chars.count {
                    if chars[j] == "\\" {
                        j += 2
                        continue
                    }
                    if chars[j] == "\"" {
                        break
                    }
                    j += 1
                }
                let end = min(j + 1, chars.count)
                let token = String(chars[i..<end])
                // 判断 key（后面第一个非空白是冒号）
                var k = end
                while k < chars.count, chars[k] == " " {
                    k += 1
                }
                let isKey = k < chars.count && chars[k] == ":"
                flush()
                result.append((token, isKey ? keyColor : stringColor))
                i = end
            } else if c.isNumber {
                // 数字 token
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." || chars[j] == "e" || chars[j] == "E" {
                    j += 1
                }
                flush()
                result.append((String(chars[i..<j]), numberColor))
                i = j
            } else if c == "t" || c == "f" || c == "n" {
                let kw = keyword(at: i, in: chars)
                if let kw {
                    flush()
                    result.append((kw, boolNullColor))
                    i += kw.count
                } else {
                    current.append(c)
                    i += 1
                }
            } else if "{}[],:".contains(c) {
                flush()
                result.append((String(c), punctColor))
                i += 1
            } else {
                current.append(c)
                i += 1
            }
        }
        flush()
        return result
    }

    private static func keyword(at i: Int, in chars: [Character]) -> String? {
        let candidates = ["true", "false", "null"]
        for kw in candidates {
            let letters = Array(kw)
            guard i + letters.count <= chars.count else { continue }
            guard (i + letters.count == chars.count) || !isIdentChar(chars[i + letters.count]) else { continue }
            var match = true
            for (off, ch) in letters.enumerated() where chars[i + off] != ch {
                match = false
                break
            }
            if match { return kw }
        }
        return nil
    }

    private static func isIdentChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }
}
