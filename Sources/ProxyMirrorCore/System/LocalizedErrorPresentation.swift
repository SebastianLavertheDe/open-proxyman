import Foundation
#if canImport(ProxyMirrorFoundation)
import ProxyMirrorFoundation
#endif
#if canImport(ProxyMirrorSystemProxy)
import ProxyMirrorSystemProxy
#endif

/// 技术诊断与界面文案分别渲染；日志、CLI 和会话文件始终使用 diagnostic。
struct OperationIssue: Sendable, Equatable {
    let code: String
    let arguments: [String]
    let diagnostic: String
    private let render: @Sendable () -> String

    init(code: String, arguments: [String] = [], diagnostic: String, render: @escaping @Sendable () -> String) {
        self.code = code
        self.arguments = arguments
        self.diagnostic = diagnostic
        self.render = render
    }

    var localizedPresentation: String { render() }
    func withPresentation(_ renderer: @escaping @Sendable () -> String) -> Self {
        Self(code: code, arguments: arguments, diagnostic: diagnostic, render: renderer)
    }
    static func technical(_ detail: String) -> Self {
        Self(code: "technical_detail", diagnostic: detail, render: { detail })
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.code == rhs.code && lhs.arguments == rhs.arguments && lhs.diagnostic == rhs.diagnostic
    }
}

protocol OperationIssueProviding: Error {
    var operationIssue: OperationIssue { get }
}

/// 任意系统返回的错误保留其技术详情；已知操作错误则按稳定 code 渲染。
enum LocalizedErrorPresentation {
    static func message(for error: Error) -> String {
        #if canImport(ProxyMirrorFoundation)
        if let failure = error as? CapturedFailure {
            return OperationIssue.restored(code: failure.code, arguments: failure.arguments,
                                           diagnostic: failure.diagnostic).localizedPresentation
        }
        #endif
        if let error = error as? OperationIssueProviding {
            return error.operationIssue.localizedPresentation
        }
        #if canImport(ProxyMirrorSystemProxy)
        if let error = error as? SystemProxyError {
            return helperMessage(error)
        }
        #endif
        return error.localizedDescription
    }

    #if canImport(ProxyMirrorSystemProxy)
    private static func helperMessage(_ error: SystemProxyError) -> String {
        switch error.code {
        case .invalidPort: return Strings.Errors.helperInvalidPort
        case .busy: return Strings.Errors.helperBusy
        case .notOwner: return Strings.Errors.helperNotOwner
        case .authorizationRequired: return Strings.Errors.helperAuthorizationRequired
        case .invalidArguments: return Strings.Errors.helperInvalidArguments
        case .signatureInvalid: return Strings.Errors.helperSignatureInvalid
        case .lockUnavailable: return Strings.Errors.helperLockUnavailable
        case .restoreRecordInvalid: return Strings.Errors.helperRestoreRecordInvalid
        case .bypassRecordInvalid: return Strings.Errors.helperBypassRecordInvalid
        case .takeoverRequired: return Strings.Errors.helperTakeoverRequired
        case .bypassUpdateLimit: return Strings.Errors.helperBypassUpdateLimit
        case .noOwnedServices: return Strings.Errors.helperNoOwnedServices
        case .installationFailed: return Strings.Errors.helperInstallationFailed
        case .invalidDirectory: return Strings.Errors.helperInvalidDirectory
        case .permissionsFailed: return Strings.Errors.helperPermissionsFailed
        case .stopFailed: return Strings.Errors.helperStopFailed
        case .loadFailed: return Strings.Errors.helperLoadFailed
        case .bypassTooLarge: return Strings.Errors.helperBypassTooLarge
        case .bypassInvalid: return Strings.Errors.helperBypassInvalid(error.arguments.first ?? "")
        case .none: return error.localizedDescription
        }
    }
    #endif
}

/// Core 自有系统代理错误；跨 XPC 的共享错误仍使用 SystemProxyError。
struct SystemProxyOperationError: LocalizedError, OperationIssueProviding {
    let operationIssue: OperationIssue
    init(_ issue: OperationIssue) { operationIssue = issue }
    init(_ detail: String) { operationIssue = .technical(detail) }
    var message: String { operationIssue.diagnostic }
    var errorDescription: String? { operationIssue.diagnostic }
}
