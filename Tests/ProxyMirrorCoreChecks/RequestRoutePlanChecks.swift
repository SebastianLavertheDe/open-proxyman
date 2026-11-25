import Foundation
import NIOCore
import NIOEmbedded
@testable import ProxyMirrorCore

@MainActor
func checkRequestRoutePlans(_ test: CoreAssertions) throws {
    for method in ["GET", "HEAD"] {
        for scheme in ["http", "https"] {
            let input = RequestRouteMetadata(method: method, scheme: scheme, host: "original.test", port: scheme == "https" ? 443 : 80,
                path: "/item%2Fname", query: "old=1", headers: HTTPHeaders([("Host", "wrong.test"), ("If-None-Match", "v1"), ("X-Preserve", "yes")]))
            let remote = ProxyRule(pattern: "*", target: "https://[2001:db8::7]:8443/base?new=2")
            let rules = RulesSnapshot(mapRemote: [remote], noCaching: true)
            var order: [String] = []
            let plan = RequestRoutePlan(request: input, rules: rules)
            let routed = plan.upstream(resolve: { host in order.append("dns:" + host); return "192.0.2.8" },
                                       sample: { host in order.append("latency:" + host); return LatencySimulation() })
            test.expect(plan.rejection == nil, "Common route permits an unrestricted \(scheme) \(method)")
            test.equal(routed.request.headers.value(of: "Host"), "[2001:db8::7]:8443", "Both protocols use the mapped authority")
            test.equal(routed.request.target, "/base/item%2Fname?new=2", "Both protocols preserve encoded path and map query")
            test.equal(routed.request.headers.value(of: "If-None-Match"), nil, "No-cache removes request validators")
            test.equal(routed.request.headers.value(of: "X-Preserve"), "yes", "Route changes preserve application headers")
            test.equal(order, ["dns:2001:db8::7", "latency:2001:db8::7"], "Mapping precedes DNS and weak-network sampling")
            test.equal(input.headers.value(of: "Host"), "wrong.test", "Routing never mutates its input snapshot")
            let block = RequestRoutePlan(request: input, rules: RulesSnapshot(blockList: [ProxyRule(pattern: "*")], allowList: [ProxyRule(pattern: "*")]))
            test.equal(block.rejection, .blocked, "Block is evaluated before Allow")
            let deny = RequestRoutePlan(request: input, rules: RulesSnapshot(allowList: [ProxyRule(pattern: "other.test")]))
            test.equal(deny.rejection, .notAllowed, "An allow-list miss is a separate common decision")
            for action in RuleBlockAction.allCases {
                var entry = ProxyRule(pattern: "*")
                entry.blockAction = action
                let configured = RequestRoutePlan(request: input, rules: RulesSnapshot(blockList: [entry]))
                test.equal(configured.blockAction, action, "HTTP/1 and HTTP/2 routing carry the selected Block action")
            }
            test.equal(deny.blockAction.statusCode, 403, "Allow List misses retain HTTP 403 regardless of Block actions")
        }
    }
    let response = HTTPHeaders([("Cache-Control", "max-age=60"), ("eTaG", "v1"), ("X-Preserve", "yes")])
    let cleared = RequestRoutePlan.responseHeaders(response, noCaching: true)
    test.equal(cleared.value(of: "ETag"), nil, "Both protocols remove response validators case-insensitively")
    test.equal(cleared.value(of: "X-Preserve"), "yes", "No-cache preserves unrelated response fields")
    test.equal(RequestRoutePlan.responseHeaders(response, noCaching: false).rawBytes, response.rawBytes,
               "A request retains its original no-cache snapshot if settings later change")
}
