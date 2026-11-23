import Foundation
@testable import ProxyMirrorCore
#if canImport(ProxyMirrorCore)
import NIOPosix
#endif

func checkExternalInclusiveRouting(_ test: CoreAssertions) throws {
    var config = ExternalProxyConfig(enabled: true, host: "proxy.example.test", bypassHosts: ["direct.example.test"])
    test.equal(config.effectiveRoutingMode, .bypass, "Old external proxy configuration retains bypass semantics")
    test.expect(config.applies(to: "other.example.test", respectGlobalSwitch: false), "Legacy bypass sends unlisted hosts upstream")
    test.expect(!config.applies(to: "direct.example.test", respectGlobalSwitch: false), "Legacy bypass excludes listed hosts")
    let oldData = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(ExternalProxyConfig.self, from: oldData)
    test.equal(decoded.effectiveRoutingMode, .bypass, "Omitted routing mode decodes with backward-compatible behavior")
    config.routingMode = .all
    test.expect(config.applies(to: "direct.example.test", respectGlobalSwitch: false), "All mode ignores the stored bypass list")
    config.routingMode = .inclusive
    config.includedTargets = ["*.example.test", "https://api.other.test/v1/*"]
    test.expect(config.applies(to: "api.example.test", respectGlobalSwitch: false), "Inclusive host wildcard selects a subdomain")
    test.expect(!config.applies(to: "example.test", respectGlobalSwitch: false), "Inclusive subdomain wildcard does not select apex")
    test.expect(!config.applies(to: "unlisted.other.test", respectGlobalSwitch: false), "Unlisted host goes direct")
    test.expect(config.couldApply(to: "api.other.test", respectGlobalSwitch: false), "URL-inclusive candidate survives the host-only decision")
    test.expect(!config.applies(to: "api.other.test", respectGlobalSwitch: false), "URL-inclusive matching requires a full URL")
    test.expect(config.applies(to: "api.other.test", url: "https://api.other.test/v1/items?q=a", respectGlobalSwitch: false), "Inclusive URL pattern selects a matching request path")
    test.expect(!config.applies(to: "api.other.test", url: "https://api.other.test/v2/items", respectGlobalSwitch: false), "Same-host URL outside the included path goes direct")
    test.expect(!config.applies(to: "api.other.test", url: "https://api.other.test/V1/items", respectGlobalSwitch: false), "URL paths preserve case")
    config.includedTargets = ["*"]
    for host in ["localhost", "app.localhost", "127.0.0.2", "::1", "::ffff:127.0.0.2"] {
        test.expect(!config.applies(to: host, url: "http://\(host)/", respectGlobalSwitch: false), "Localhost always goes direct: \(host)")
    }
    config.includedTargets = []
    test.expect(config.validationError != nil, "Enabled inclusive mode requires a target")
    config.includedTargets = ["https://API.Example.Test/Api/*?Key=*"]
    test.expect(config.validationError == nil, "Valid host/URL wildcard is accepted")
    let target = ExternalProxyTarget("https://API.Example.Test/Api/*?Key=*")
    test.expect(target?.matches(host: "api.example.test", url: "https://api.example.test/Api/a?Key=one") == true, "URL scheme and host normalize without changing query case")
    test.expect(target?.matches(host: "api.example.test", url: "https://api.example.test/Api/a?key=one") == false, "URL query delimiter stays literal and query case is preserved")
    for invalid in ["", "https://user:password@example.test/*", "ftp://example.test/*", "example.test/path", "https://example.test/#fragment", "bad host"] {
        test.expect(ExternalProxyTarget(invalid) == nil, "Malformed inclusive target is rejected: \(invalid)")
    }
    test.expect(ExternalProxyTarget("https://API.Example.Test:443/*")?.matches(host: "api.example.test", url: "https://api.example.test/item") == true, "Default HTTPS port normalizes in URL matching")
    let roundTrip = try JSONDecoder().decode(ExternalProxyConfig.self, from: JSONEncoder().encode(config))
    test.equal(roundTrip.routingMode, .inclusive, "Inclusive mode round-trips through configuration JSON")
    test.equal(roundTrip.includedTargets, config.includedTargets, "Included target list round-trips through configuration JSON")
    #if canImport(ProxyMirrorCore)
    try checkHTTPOriginInclusiveRouting(test)
    #endif
}

#if canImport(ProxyMirrorCore)
/// Exercises the actual NIO origin decision, including its host-only preflight
/// and once-per-request resolution flag. The App integration additionally checks
/// which sockets reach the CONNECT upstream.
private func checkHTTPOriginInclusiveRouting(_ test: CoreAssertions) throws {
    let previous = InterceptionConfig.shared.externalProxy.value
    defer { InterceptionConfig.shared.externalProxy.set(previous) }
    var config = ExternalProxyConfig(enabled: true, host: "upstream.example.test")
    config.routingMode = .inclusive
    config.includedTargets = ["http://api.origin-inclusive.test:8080/selected/*"]
    InterceptionConfig.shared.externalProxy.set(config)
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { try? group.syncShutdownGracefully() }
    let gate = RuleOrganizationStore.shared.isEnabled("external")
    let origin = HTTPOrigin(host: "api.origin-inclusive.test", dialHost: "127.0.0.1", port: 8080, tls: false)
    test.equal(origin.external != nil, gate, "HTTPOrigin retains URL-inclusive candidate until a request path is known")
    let included = try origin.resolvingProxy(path: "/selected/item", on: group.next()).wait()
    test.equal(included.external != nil, gate, "Actual HTTPOrigin selects upstream for matching path")
    test.equal(included.proxyResolved, gate, "Selected origin marks routing resolved to prevent exchange recursion")
    let excluded = try origin.resolvingProxy(path: "/outside/item", on: group.next()).wait()
    test.expect(excluded.external == nil, "Actual HTTPOrigin selects direct for same-host unmatched path")
    test.equal(excluded.proxyResolved, gate, "Direct result also marks routing resolved when external routing was considered")
    config.includedTargets = ["https://api.origin-inclusive.test/selected/*"]
    InterceptionConfig.shared.externalProxy.set(config)
    let secure = HTTPOrigin(host: "api.origin-inclusive.test", dialHost: "127.0.0.1", port: 443, tls: true)
    test.equal(try secure.resolvingProxy(path: "/selected/item?key=value", on: group.next()).wait().external != nil, gate,
               "HTTPS origin resolution preserves path and query for inclusive matching")
    test.expect(try secure.resolvingProxy(path: "/outside/item", on: group.next()).wait().external == nil,
                "HTTPS unmatched path goes direct before upstream dialing")
}
#endif
