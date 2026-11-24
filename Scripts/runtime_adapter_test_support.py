"""Platform dependencies for compiling the unchanged Core runtime adapter.

Foundation request/transport policies are imported from the real module. Native
Core checks exercise the actual NIO engine and certificate authority; portable
generator fixtures only need these platform contracts for type checking.
"""

RUNTIME_STUBS = r'''
import Foundation
final class AppSettings {
    static let shared = AppSettings()
    var port: UInt16 = 9090
    var maxBodyMB = 20
    var noCacheOnRepeat = false
    var appendProxyToCommands = false
    var preserveOriginalHeaders = false
    var redactSensitiveHeaders = false
}
final class CertificateAuthority: @unchecked Sendable {
    let caCertPath = URL(fileURLWithPath: "/unused-portable-\(UUID().uuidString).pem")
    func ensureCA() throws {}
}
final class ProxyEngine: @unchecked Sendable {
    static let shared = ProxyEngine()
    var isRunning = false
    var port: UInt16 = 9090
    let certificateAuthority = CertificateAuthority()
}
struct ConnState {
    let engine: ProxyEngine
    func shouldMITM(host: String) -> Bool { true }
}
'''
