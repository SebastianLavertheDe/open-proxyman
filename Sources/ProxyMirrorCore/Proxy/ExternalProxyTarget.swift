import Foundation

/// An inclusive target is a numeric/domain host glob, or an HTTP(S) URL glob.
/// Host matching ignores case. URL paths and queries preserve case; * is the
/// URL wildcard and ? remains the query delimiter.
struct ExternalProxyTarget {
    let pattern: String
    let isURL: Bool
    private static let cache: NSCache<NSString, NSRegularExpression> = {
        let cache = NSCache<NSString, NSRegularExpression>()
        cache.countLimit = 512
        return cache
    }()

    init?(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 2048,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        if trimmed.contains("://") {
            let probe = trimmed.replacingOccurrences(of: "*", with: "x")
            guard let parts = URLComponents(string: probe), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
                  parts.user == nil, parts.password == nil, parts.fragment == nil,
                  let host = parts.host, ExternalProxyHost(host) != nil else { return nil }
            if let port = parts.port, !(1...65535).contains(port) { return nil }
            pattern = Self.canonicalURL(trimmed)
            isURL = true
        } else {
            let probe = trimmed.replacingOccurrences(of: "*", with: "x").replacingOccurrences(of: "?", with: "x")
            guard ExternalProxyHost(probe) != nil else { return nil }
            pattern = trimmed.contains("*") || trimmed.contains("?")
                ? trimmed.lowercased() : ExternalProxyHost(trimmed)?.name ?? trimmed.lowercased()
            isURL = false
        }
    }

    func matches(host: String, url: String?) -> Bool {
        let value: String
        if isURL {
            guard let url else { return false }
            value = Self.canonicalURL(url)
        } else {
            guard let host = ExternalProxyHost(host) else { return false }
            value = host.name
        }
        let key = (isURL ? "url:" : "host:") + pattern
        let expression: NSRegularExpression
        if let found = Self.cache.object(forKey: key as NSString) { expression = found }
        else {
            var source = "^"
            for character in pattern {
                if character == "*" { source += ".*" }
                else if character == "?", !isURL { source += "." }
                else { source += NSRegularExpression.escapedPattern(for: String(character)) }
            }
            source += "$"
            guard let compiled = try? NSRegularExpression(pattern: source) else { return false }
            Self.cache.setObject(compiled, forKey: key as NSString)
            expression = compiled
        }
        return expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    private static func canonicalURL(_ value: String) -> String {
        guard let separator = value.range(of: "://") else { return value }
        let scheme = value[..<separator.lowerBound].lowercased()
        let tail = value[separator.upperBound...]
        let boundary = tail.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? tail.endIndex
        var authority = tail[..<boundary].lowercased()
        if scheme == "http", authority.hasSuffix(":80") { authority.removeLast(3) }
        if scheme == "https", authority.hasSuffix(":443") { authority.removeLast(4) }
        let suffix = String(tail[boundary...])
        return scheme + "://" + authority + (suffix.isEmpty || suffix.hasPrefix("?") ? "/" + suffix : suffix)
    }
}
