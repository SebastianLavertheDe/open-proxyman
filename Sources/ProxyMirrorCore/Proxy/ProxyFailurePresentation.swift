import Foundation

extension ProxyError: OperationIssueProviding {
    var operationIssue: OperationIssue {
        switch self {
        case .shutdown: return .networkProxyShutdown
        case .invalidLANAccess: return .networkInvalidLanAccess
        case .unapprovedDevice: return .networkUnapprovedDevice
        }
    }
}

extension ProxyHTTP2Error: OperationIssueProviding {
    var operationIssue: OperationIssue {
        switch self {
        case .invalidHeaders: return .networkHttp2InvalidHeaders
        case .invalidAuthority: return .networkHttp2InvalidAuthority
        case .invalidMessage: return .networkHttp2InvalidMessage
        case .negotiationTimeout: return .networkTlsNegotiationTimeout
        case .responseTimeout: return .networkUpstreamResponseTimeout
        case .connectionClosed: return .networkUpstreamClosed
        case .pushUnsupported: return .networkPushUnsupported
        case .connectionLimit: return .networkConnectionLimit
        }
    }
}
