import Foundation
import ProxyMirrorFoundation

extension RulesSnapshot {
    /// A passthrough CONNECT exposes its authority, but never its HTTP paths.
    /// Evaluate both the authority URL and its root so the normal host/* form works.
    func tunnelRejection(host: String, port: Int, serverName: String? = nil) -> String? {
        tunnelFailure(host: host, port: port, serverName: serverName)?.diagnostic
    }

    func tunnelFailure(host: String, port: Int, serverName: String? = nil) -> CapturedFailure? {
        let urls = ([host] + (serverName.map { [$0] } ?? [])).flatMap { name -> [String] in
            let authority = "https://" + URLParser.authority(host: name, port: port, scheme: "https")
            return [authority, authority + "/"]
        }
        if urls.contains(where: { isBlocked(url: $0) }) {
            return CapturedFailure(code: OperationIssue.networkRouteBlocked.code,
                                   diagnostic: "ProxyMirror: blocked by Block List (HTTPS tunnel)")
        }
        if !urls.contains(where: { isAllowed(url: $0) }) {
            return CapturedFailure(code: OperationIssue.networkRouteNotAllowed.code,
                                   diagnostic: "ProxyMirror: not in Allow List (HTTPS tunnel)")
        }
        return nil
    }
}
