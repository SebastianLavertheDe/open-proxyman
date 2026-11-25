import Foundation

/// 阻断规则的传输行为。缺省的旧规则仍返回 HTTP 403。
public enum RuleBlockAction: String, Codable, CaseIterable, Sendable {
    case forbidden, serviceUnavailable, tooManyRequests, disconnect

    public var statusCode: Int? {
        switch self {
        case .forbidden: return 403
        case .serviceUnavailable: return 503
        case .tooManyRequests: return 429
        case .disconnect: return nil
        }
    }
}
