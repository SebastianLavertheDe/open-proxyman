import Foundation
@testable import ProxyMirrorCore

func checkRules(_ test: CoreAssertions) throws {
    let request = "https://api.example.test/a%2Fb?id=1&id=2"
    let disabled = ProxyRule(enabled: false, pattern: "*", target: "http://127.0.0.1:9901/")
    let enabled = ProxyRule(pattern: "https://api.example.test/*", target: "https://[::1]:9443/base/")
    let rules = RulesSnapshot(mapRemote: [disabled, enabled], blockList: [disabled],
                              allowList: [enabled], sslProxyingList: [ProxyRule(pattern: "https://*.example.test/*")])
    let remote = rules.mapRemoteTarget(for: request)
    test.equal(remote?.host, "::1", "Map Remote skips disabled match")
    test.equal(remote?.port, 9443, "Map Remote destination port")
    test.equal(remote?.requestTarget(path: "/a%2Fb", query: "id=1&id=2"), "/base/a%2Fb?id=1&id=2",
               "Map Remote preserves encoded path and original query")
    test.expect(!rules.isBlocked(url: request), "Disabled Block rule has no effect")
    test.expect(RulesSnapshot(blockList: [enabled]).isBlocked(url: request), "Enabled Block rule matches")
    test.expect(rules.isAllowed(url: request), "Allow rule matches")
    test.expect(!rules.isAllowed(url: "https://other.test/sample"), "Nonmatching URL is denied by active Allow list")
    test.expect(RulesSnapshot(allowList: [disabled]).isAllowed(url: request), "No active Allow rules permits requests")
    test.expect(rules.shouldSSLProxy(host: "api.example.test"), "SSL accepts legacy URL host pattern")
    test.expect(!rules.shouldSSLProxy(host: "example.test"), "SSL subdomain pattern excludes apex")

    var applicationRules = rules
    applicationRules.sslApplications = [
        SSLApplicationRule(bundleID: "test.fixture.transit", action: .passthrough),
        SSLApplicationRule(bundleID: "test.fixture.capture", action: .decrypt)
    ]
    test.expect(!applicationRules.shouldSSLProxy(host: "api.example.test", application: "TEST.FIXTURE.TRANSIT"),
                "Application passthrough takes precedence over domain")
    test.expect(applicationRules.shouldSSLProxy(host: "other.test", application: "test.fixture.capture"),
                "Application decrypt takes precedence over domain")
    let dns = DNSSpoofRule(hostPattern: "*.example.test", ip: "127.0.0.1")
    test.expect(dns.matches(host: "api.example.test"), "DNS wildcard matches a subdomain")
    test.expect(!dns.matches(host: "unrelated.test"), "DNS wildcard excludes unrelated host")

    let directory = try makeCheckDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let body = Data([13, 10, 0, 255])
    let fixture = directory.appendingPathComponent("fixture.bin")
    try body.write(to: fixture)
    let local = ProxyRule(pattern: "https://api.example.test/*", target: directory.path,
                          responseStatus: 202,
                          responseHeaders: HTTPHeaders([("Content-Type", "application/test"),
                                                        ("Content-Length", "1234"), ("X-Rule", "sample")]))
    let localRules = RulesSnapshot(mapLocal: [local])
    let mapped = localRules.mapLocalResponse(for: "https://api.example.test/fixture.bin")
    test.equal(mapped?.data, body, "Map Local resolves directory entry")
    test.equal(mapped?.contentType, "application/test", "Map Local honors custom content type")
    test.equal(mapped?.status, 202, "Map Local honors custom status")
    test.equal(mapped?.headers.value(of: "X-Rule"), "sample", "Map Local preserves custom header")
    test.expect(mapped?.headers.value(of: "Content-Length") == nil, "Map Local delegates framing to response writer")
    test.expect(localRules.mapLocalResponse(for: "https://api.example.test/missing.bin") == nil,
                "Map Local missing file does not synthesize a response")

    let persistedRules = directory.appendingPathComponent("pending-rules.json")
    let editedStore = RulesStore(storageURL: persistedRules)
    editedStore.noCaching = true
    try editedStore.flushPendingSave()
    let reopenedStore = RulesStore(storageURL: persistedRules)
    test.expect(reopenedStore.noCaching, "Immediate rule flush survives reopening before the debounce timer")
    editedStore.noCaching = false
    try editedStore.flushPendingSave()
    test.expect(!RulesStore(storageURL: persistedRules).noCaching, "A final shutdown flush persists later edits")
}
