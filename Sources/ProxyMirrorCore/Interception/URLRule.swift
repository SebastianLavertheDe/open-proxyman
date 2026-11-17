import Foundation

// MARK: - URL 匹配规则（对齐 Proxyman 语义：Wildcard * ? / Regex / 包含子路径）

/// 通用 URL 匹配规则：供 Map Local / Rewrite / Breakpoint / DNS Spoofing 复用。
/// 规则字段为空或 "ANY" 表示不限制。
struct URLRule: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var enabled: Bool = true
    var name: String = ""

    var method: String = "ANY"          // ANY / GET / POST ...
    var scheme: String = "ANY"          // ANY / http / https
    var host: String = ""               // wildcard：api.example.com / *.example.com；空 = 任意
    var path: String = "*"              // wildcard：/v1/* ；plain + includeSubpaths 时前缀匹配
    var query: String = ""              // 非空时子串匹配
    var includeSubpaths: Bool = true    // 「包含此 URL 的所有子路径」
    var matchMode: MatchMode = .wildcard
    var regexPattern: String = ""       // matchMode == .regex 时对完整 URL 匹配
    var graphqlQueryName: String = ""   // 非空时要求 GraphQL 操作名匹配

    enum MatchMode: String, Codable, CaseIterable {
        case wildcard   // * 和 ?
        case plain      // 精确文本（路径仍可启用子路径）
        case regex      // 完整 URL 正则
    }

    // MARK: 匹配

    func matches(tx: Transaction) -> Bool {
        return matches(method: tx.method, scheme: tx.isTunnel ? "https" : tx.scheme,
                       host: tx.host, path: tx.path, query: tx.query, fullURL: tx.fullURL,
                       graphqlName: tx.graphqlOperationName)
    }

    func matches(method: String, scheme: String, host: String, path: String,
                 query: String, fullURL: String, graphqlName: String? = nil) -> Bool {
        if self.method != "ANY" && self.method.uppercased() != method.uppercased() { return false }
        if self.scheme != "ANY" && self.scheme.lowercased() != scheme.lowercased() { return false }
        if !graphqlQueryName.isEmpty {
            guard graphqlName == graphqlQueryName else { return false }
        }

        if matchMode == .regex {
            guard let re = Self.regexCache(regexPattern) else { return false }
            let range = re.rangeOfFirstMatch(in: fullURL, range: NSRange(fullURL.startIndex..., in: fullURL))
            return range.location != NSNotFound
        }

        // wildcard / plain
        if !self.host.isEmpty && !Self.wildcardMatch(self.host, value: host) { return false }

        let pattern = self.path
        if matchMode == .plain {
            if pattern != "*" {
                let p = pattern.hasSuffix("/") && pattern.count > 1 ? String(pattern.dropLast()) : pattern
                if path != p {
                    if !(includeSubpaths && path.hasPrefix(p.hasSuffix("/") ? p : p + "/")) { return false }
                }
            }
        } else if !Self.wildcardMatch(pattern, value: path) {
            // wildcard 模式下，纯前缀 pattern（无通配符）且启用子路径时做前缀匹配
            if includeSubpaths && !pattern.contains("*") && !pattern.contains("?") {
                let p = pattern.hasSuffix("/") ? pattern : pattern + "/"
                if !(path == pattern || path.hasPrefix(p)) { return false }
            } else {
                return false
            }
        }

        if !self.query.isEmpty && !query.lowercased().contains(self.query.lowercased()) {
            return false
        }
        return true
    }

    // MARK: 工具

    private static let wildcardCache: NSCache<NSString, NSRegularExpression> = {
        let cache = NSCache<NSString, NSRegularExpression>()
        cache.countLimit = 256
        return cache
    }()

    /// wildcard（* 任意串，? 单字符）→ 锚定正则匹配
    static func wildcardMatch(_ pattern: String, value: String) -> Bool {
        let p = pattern.lowercased()
        if p.isEmpty || p == "*" { return true }
        let v = value.lowercased()
        if !p.contains("*") && !p.contains("?") { return p == v }
        guard let re = wildcardExpression(p) else { return false }
        return re.firstMatch(in: v, range: NSRange(v.startIndex..., in: v)) != nil
    }

    private static func wildcardExpression(_ pattern: String) -> NSRegularExpression? {
        let key = pattern as NSString
        if let cached = wildcardCache.object(forKey: key) { return cached }
        var regex = "^"
        for ch in pattern {
            switch ch {
            case "*": regex += ".*"
            case "?": regex += "."
            default: regex += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        regex += "$"
        guard let re = try? NSRegularExpression(pattern: regex, options: [.dotMatchesLineSeparators]) else { return nil }
        wildcardCache.setObject(re, forKey: key)
        return re
    }

    private static var _regexCache: [String: NSRegularExpression] = [:]
    private static let _regexLock = NSLock()
    static func regexCache(_ pattern: String) -> NSRegularExpression? {
        _regexLock.lock(); defer { _regexLock.unlock() }
        if let re = _regexCache[pattern] { return re }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        _regexCache[pattern] = re
        return re
    }

    // MARK: 预设

    static func ruleFor(url: String) -> URLRule {
        var r = URLRule()
        // 从 URL 提取 host/path 预填
        if let u = URL(string: url), let h = u.host {
            r.host = h
            var p = u.path
            if p.isEmpty { p = "/" }
            r.path = p
        } else {
            r.path = url
        }
        return r
    }

    /// 规则的人类可读摘要（列表显示）
    var summary: String {
        if matchMode == .regex { return "regex: \(regexPattern)" }
        var parts: [String] = []
        if method != "ANY" { parts.append(method) }
        if !host.isEmpty { parts.append(host) }
        if path != "*" { parts.append(path) }
        if !query.isEmpty { parts.append("?\(query)") }
        return parts.isEmpty ? "*" : parts.joined(separator: " ")
    }
}

