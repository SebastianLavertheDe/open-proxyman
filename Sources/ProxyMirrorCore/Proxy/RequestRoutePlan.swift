import Foundation
import ProxyMirrorFoundation
import NIOCore

/// Engine-owned value metadata. A published Transaction is never the routing
/// state machine's mutable working copy.
struct RequestRouteMetadata {
    var method: String
    var scheme: String
    var host: String
    var port: Int
    var path: String
    var query: String
    var headers: HTTPHeaders

    var target: String { path + (query.isEmpty ? "" : "?" + query) }
    var url: String { "\(scheme)://\(URLParser.authority(host: host, port: port, scheme: scheme))\(target)" }
}

/// Both wire protocols use this exact rule order and request transformation.
/// Protocol-specific buffering, connection management and flow control stay in
/// their handlers. DNS and weak-network sampling happen only after Map Local misses.
struct RequestRoutePlan {
    enum Rejection: Equatable {
        case blocked, notAllowed

        var diagnostic: String {
            self == .blocked ? "ProxyMirror: blocked by Block List" : "ProxyMirror: not in Allow List"
        }
    }

    struct Upstream {
        let request: RequestRouteMetadata
        let originalURL: String
        let mappedRemote: Bool
        let noCaching: Bool
        let resolvedAddress: String?
        let simulation: LatencySimulation
    }

    let request: RequestRouteMetadata
    let rules: RulesSnapshot
    let rejection: Rejection?

    init(request: RequestRouteMetadata, rules: RulesSnapshot) {
        self.request = request
        self.rules = rules
        rejection = rules.isBlocked(url: request.url) ? .blocked : (rules.isAllowed(url: request.url) ? nil : .notAllowed)
    }

    func prepareLocal(on loop: EventLoop) -> EventLoopFuture<PreparedMapLocalResponse?>? {
        guard rejection == nil else { return nil }
        return rules.prepareMapLocalResponse(for: request.url, includeBody: request.method != "HEAD", on: loop)
    }

    func upstream(resolve: (String) -> String? = { InterceptionConfig.shared.mappedIP(for: $0) },
                  sample: (String) -> LatencySimulation = { LatencyConditions.snapshot().sample(for: $0) }) -> Upstream {
        var routed = request
        let remote = rules.mapRemoteTarget(for: request.url)
        if let remote {
            routed.host = remote.host
            routed.port = remote.port
            routed.scheme = remote.scheme
            (routed.path, routed.query) = splitQueryPath(remote.requestTarget(path: request.path, query: request.query))
        }
        routed.headers.set(name: "Host", value: URLParser.authority(host: routed.host, port: routed.port, scheme: routed.scheme))
        if rules.noCaching {
            for name in ["If-None-Match", "If-Modified-Since", "If-Unmodified-Since"] { routed.headers.remove(name: name) }
        }
        return Upstream(request: routed, originalURL: request.url, mappedRemote: remote != nil,
                        noCaching: rules.noCaching, resolvedAddress: resolve(routed.host), simulation: sample(routed.host))
    }

    static func responseHeaders(_ headers: HTTPHeaders, noCaching: Bool) -> HTTPHeaders {
        guard noCaching else { return headers }
        var fields = headers
        for name in ["Cache-Control", "ETag", "Last-Modified", "Expires", "Age"] { fields.remove(name: name) }
        return fields
    }
}
