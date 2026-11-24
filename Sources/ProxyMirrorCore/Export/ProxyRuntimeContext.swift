import Foundation
import ProxyMirrorFoundation

/// A request keeps the runtime it was created for, including its CA and the
/// preference values used by background transport and command generation.
struct ProxyRuntimeContext: Sendable {
    let engine: ProxyEngine
    let configuredPort: UInt16
    let captureLimit: Int
    let noCacheOnRepeat: Bool
    let appendProxyToCommands: Bool
    let preserveOriginalHeaders: Bool
    let redactSensitiveHeaders: Bool

    init(engine: ProxyEngine, settings: AppSettings) {
        self.engine = engine
        configuredPort = settings.port
        captureLimit = settings.maxBodyMB * 1024 * 1024
        noCacheOnRepeat = settings.noCacheOnRepeat
        appendProxyToCommands = settings.appendProxyToCommands
        preserveOriginalHeaders = settings.preserveOriginalHeaders
        redactSensitiveHeaders = settings.redactSensitiveHeaders
    }

    /// Standalone services without an AppState use the production runtime.
    static var shared: Self { Self(engine: .shared, settings: .shared) }

    var certificateAuthority: CertificateAuthority { engine.certificateAuthority }
    var listenerPort: UInt16 { engine.isRunning ? engine.port : configuredPort }

    func trustedCA(for request: HTTPRequest) throws -> URL? {
        guard let target = URLParser.parse(target: request.url), target.scheme == "https",
              let host = target.host, ConnState(engine: engine).shouldMITM(host: host) else { return nil }
        try certificateAuthority.ensureCA()
        return certificateAuthority.caCertPath
    }
}
