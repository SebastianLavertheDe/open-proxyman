import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The public release check never downloads or executes an update. Signed installation
/// remains Sparkle's responsibility when a distribution supplies its signing key/feed.
struct ReleaseVersion: Comparable {
    let components: [Int]
    let prerelease: String?

    init?(_ value: String) {
        var tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if tag.first == "v" || tag.first == "V" { tag.removeFirst() }
        let version = tag.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = version.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(numbers.count), numbers.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              numbers.allSatisfy({ Int($0) != nil }), parts.count == 1 || !parts[1].isEmpty else { return nil }
        components = numbers.map { Int($0)! } + Array(repeating: 0, count: 4 - numbers.count)
        prerelease = parts.count == 2 ? String(parts[1]) : nil
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.components != rhs.components { return lhs.components.lexicographicallyPrecedes(rhs.components) }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, _): return false
        case (_, nil): return true
        case (.some(let left), .some(let right)):
            let a = left.split(separator: "."), b = right.split(separator: ".")
            for (x, y) in zip(a, b) where x != y {
                if let nx = Int(x), let ny = Int(y) { return nx < ny }
                if Int(x) != nil { return true }
                if Int(y) != nil { return false }
                return x < y
            }
            return a.count < b.count
        }
    }
}

struct ReleaseUpdate: Decodable, Equatable {
    let tag: String
    let name: String?
    let page: URL
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name", name, page = "html_url", draft, prerelease
    }

    static let apiURL = URL(string: "https://api.github.com/repos/SebastianLavertheDe/open-proxyman/releases/latest")!

    static func request() -> URLRequest {
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ProxyMirror-UpdateCheck", forHTTPHeaderField: "User-Agent")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1_048_576 else { throw Failure.invalidResponse }
        let release = try JSONDecoder().decode(Self.self, from: data)
        guard release.page.scheme == "https", release.page.host?.lowercased() == "github.com",
              release.page.user == nil, release.page.password == nil,
              release.page.path.hasPrefix("/SebastianLavertheDe/open-proxyman/releases/"),
              ReleaseVersion(release.tag) != nil else { throw Failure.invalidResponse }
        return release
    }

    func isNewer(than current: String) -> Bool {
        guard !draft, !prerelease, let latest = ReleaseVersion(tag), let installed = ReleaseVersion(current) else { return false }
        return latest > installed
    }

    enum Failure: LocalizedError, OperationIssueProviding {
        case invalidResponse, http(Int)
        var errorDescription: String? { operationIssue.diagnostic }
        var operationIssue: OperationIssue {
            switch self {
            case .invalidResponse: return OperationIssue.releaseUpdateTheUpdateServiceReturnedInvalidReleaseInformation
            case .http(let code): return OperationIssue.releaseUpdateTheUpdateCheckFailedHttp(String(code))
            }
        }
    }
}
