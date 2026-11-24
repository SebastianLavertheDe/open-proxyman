import Foundation
import ProxyMirrorFoundation

/// Own failures keep their identity until the GUI renders them. Foreign system,
/// curl and user-script diagnostics remain verbatim, including after persistence.
struct NetworkFailure: LocalizedError, OperationIssueProviding {
    let operationIssue: OperationIssue
    init(_ issue: OperationIssue) { operationIssue = issue }
    var errorDescription: String? { operationIssue.diagnostic }

    static func capture(_ error: Error) -> CapturedFailure {
        if let failure = error as? CapturedFailure { return failure }
        if let known = error as? OperationIssueProviding { return known.operationIssue.capturedFailure }
        if error is CancellationError { return OperationIssue.networkRequestCancelled.capturedFailure }
        return CapturedFailure(code: "external_detail", diagnostic: error.localizedDescription)
    }
}

extension DeviceCommandRunner.Failure: OperationIssueProviding {
    var operationIssue: OperationIssue {
        switch self {
        case .timedOut: return .deviceCommandTimeout
        case .cancelled: return .deviceCommandCancelled
        case .outputTooLarge: return .deviceCommandOutputLimit
        case .unsuccessful(let status, let detail): return .deviceCommandFailed(Int(status), detail)
        }
    }
}

extension HTTPRequestTransport.Failure: OperationIssueProviding {
    var operationIssue: OperationIssue {
        switch self {
        case .cancelled: return .networkRequestCancelled
        case .timedOut: return .networkRequestTimeout
        case .invalidRequestHeaders: return .networkRequestHeadersInvalid
        case .responseHeadersTooLarge(let limit): return .networkResponseHeadersTooLarge(limit)
        case .redirectLimit(let limit): return .networkRedirectLimit(limit)
        case .invalidRedirect: return .networkInvalidRedirect
        case .noResponse: return .networkNoHttpResponse
        case .curlFailure(let code, let detail):
            return detail.isEmpty ? .networkCurlFailed(Int(code)) : .technical(detail)
        }
    }
}

extension HTTPParseError: OperationIssueProviding {
    var operationIssue: OperationIssue {
        switch self {
        case .incomplete: return .networkHttpIncomplete
        case .malformed(let detail): return .networkHttpMalformed(detail)
        }
    }
}

extension OperationIssue {
    var capturedFailure: CapturedFailure {
        CapturedFailure(code: code, arguments: arguments, diagnostic: diagnostic)
    }
}

extension CapturedFailure {
    var localizedPresentation: String {
        if let validation = externalProxyValidationPresentation { return validation }
        return OperationIssue.restored(code: code, arguments: arguments, diagnostic: diagnostic).localizedPresentation
    }

    private var externalProxyValidationPresentation: String? {
        guard code.hasPrefix("external_proxy.") else { return nil }
        let key = String(code.dropFirst("external_proxy.".count))
        if ["external_invalid_target", "external_invalid_bypass"].contains(key) {
            guard arguments.count == 1 else { return diagnostic }
            return key == "external_invalid_target" ? Strings.Integration.externalInvalidTarget(arguments[0])
                : Strings.Integration.externalInvalidBypass(arguments[0])
        }
        guard arguments.isEmpty else { return diagnostic }
        switch key {
        case "external_target_limit": return Strings.Integration.externalTargetLimit
        case "external_inclusive_required": return Strings.Integration.externalInclusiveRequired
        case "external_pac_required": return Strings.Integration.externalPacRequired
        case "external_host_required": return Strings.Integration.externalHostRequired
        case "external_port_range": return Strings.Integration.externalPortRange
        case "external_credentials_required": return Strings.Integration.externalCredentialsRequired
        case "external_socks_credentials_size": return Strings.Integration.externalSocksCredentialsSize
        case "external_basic_credentials": return Strings.Integration.externalBasicCredentials
        case "external_control_characters": return Strings.Integration.externalControlCharacters
        default: return diagnostic
        }
    }
}
