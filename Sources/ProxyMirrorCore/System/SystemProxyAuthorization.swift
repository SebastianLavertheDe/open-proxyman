import Darwin
import Foundation
import ProxyMirrorAuthorizedInstaller
import ProxyMirrorSystemProxy
import Security

enum SystemProxyAuthorization {
    enum Operation {
        case install(uid: uid_t, appHash: String)
        case uninstall

        var arguments: [String] {
            switch self {
            case .install(let uid, let appHash): ["--install", String(uid), appHash]
            case .uninstall: ["--uninstall"]
            }
        }

        var prompt: String {
            switch self {
            case .install: "ProxyMirror 需要管理员授权来安装系统代理后台服务。"
            case .uninstall: "ProxyMirror 需要管理员授权来移除系统代理后台服务。"
            }
        }
    }

    // This is a one-time installer. Ordinary takeover and restoration use the
    // installed launchd service through an authenticated XPC connection.
    static func run(_ operation: Operation, helper: URL, hash: String) throws {
        var reference: AuthorizationRef?
        try check(AuthorizationCreate(nil, nil, [], &reference))
        guard let reference else { throw SystemProxyError("无法创建 macOS 授权会话。") }
        defer { AuthorizationFree(reference, [.destroyRights]) }

        // Request the right from the app process so macOS can identify ProxyMirror.
        let status = withItem(kAuthorizationRightExecute, value: tool) { right in
            withItem(kAuthorizationEnvironmentPrompt, value: operation.prompt) { prompt in
                var rights = AuthorizationRights(count: 1, items: right)
                var environment = AuthorizationEnvironment(count: 1, items: prompt)
                return AuthorizationCopyRights(reference, &rights, &environment,
                                               [.interactionAllowed, .extendRights, .preAuthorize], nil)
            }
        }
        try check(status)

        let requirement = SystemProxyService.requirement(identifier: SystemProxyService.name, hash: hash)
        let arguments = ["-i", "PATH=/usr/bin:/bin:/usr/sbin", "/bin/sh", "-p", "-c", installerScript,
                         "ProxyMirror", helper.path, requirement] + operation.arguments
        var pointers: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        guard pointers.allSatisfy({ $0 != nil }) else { throw SystemProxyError("无法准备系统代理服务的安装参数。") }
        pointers.append(nil)

        var pipe: UnsafeMutablePointer<FILE>?
        // Authorization Services launches only the Apple-supplied env tool. The
        // fixed script verifies a root-owned copy before it executes our helper.
        let launched = pointers.withUnsafeBufferPointer { argv in
            PMExecuteAuthorizedSystemProxyInstaller(reference, argv.baseAddress!, &pipe)
        }
        defer { if let pipe { fclose(pipe) } }
        try check(launched)
        guard let pipe else { throw SystemProxyError("无法读取系统代理服务安装结果。") }
        let output = try FileHandle(fileDescriptor: fileno(pipe), closeOnDealloc: false).readToEnd() ?? Data()
        let result = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.split(whereSeparator: \.isNewline).last == Substring(successMarker) else {
            throw SystemProxyError(result.isEmpty ? "系统代理后台服务更新失败。" : result)
        }
    }

    private static func withItem<T>(_ name: String, value: String,
                                    _ body: (UnsafeMutablePointer<AuthorizationItem>) -> T) -> T {
        name.withCString { nameBytes in
            value.withCString { valueBytes in
                var item = AuthorizationItem(name: nameBytes, valueLength: value.utf8.count,
                                             value: UnsafeMutableRawPointer(mutating: valueBytes), flags: 0)
                return withUnsafeMutablePointer(to: &item, body)
            }
        }
    }

    private static func check(_ status: OSStatus) throws {
        guard status != errAuthorizationSuccess else { return }
        if status == errAuthorizationCanceled { throw SystemProxyError("已取消管理员授权。") }
        throw SystemProxyError("macOS 无法授权更新系统代理后台服务（\(status)）。")
    }

    private static let tool = "/usr/bin/env"
    private static let successMarker = "ProxyMirror installer finished successfully"
    private static let installerScript = #"""
    set -eu
    exec </dev/null 2>&1
    umask 077
    directory=$(/usr/bin/mktemp -d /private/tmp/ProxyMirrorHelper.XXXXXX)
    trap '/bin/rm -rf -- "$directory"' EXIT
    helper="$directory/ProxyMirrorSystemProxyHelper"
    /bin/cp "$1" "$helper"
    if ! /usr/bin/codesign --verify --strict -R "=$2" "$helper"; then
        echo "系统代理服务在授权期间发生了变更，请重试。"
        exit 1
    fi
    /bin/chmod 700 "$helper"
    shift 2
    "$helper" "$@"
    printf '\n%s\n' '\#(successMarker)'
    """#
}
