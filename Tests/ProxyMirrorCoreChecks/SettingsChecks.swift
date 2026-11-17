@testable import ProxyMirrorCore
import ProxyMirrorSystemProxy

func checkSettings(_ test: CoreAssertions) {
    let original: [String: Any] = ["HTTPEnable": 0, "HTTPProxy": "original", "HTTPPort": 8888]
    let current: [String: Any] = [
        "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 9090,
        "HTTPSEnable": 1, "HTTPSProxy": "external", "HTTPSPort": 8080, "ExceptionsList": ["localhost"]
    ]
    let restored = SystemProxySettings.restoredConfiguration(current, original: original, ownedPort: 9090)
    test.equal(restored["HTTPEnable"] as? Int, 0, "Restores previous HTTP enabled flag")
    test.equal(restored["HTTPProxy"] as? String, "original", "Restores previous HTTP endpoint")
    test.equal(restored["HTTPSProxy"] as? String, "external", "Preserves external HTTPS change")
    test.equal(restored["ExceptionsList"] as? [String], ["localhost"], "Preserves exception list")

    let capturedHTTPS: [String: Any] = ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 9090,
                                       "ProxyAutoConfigEnable": 1]
    let restoredHTTPS = SystemProxySettings.restoredConfiguration(capturedHTTPS, original: [:], ownedPort: 9090)
    test.expect(restoredHTTPS["HTTPSEnable"] == nil && restoredHTTPS["HTTPSProxy"] == nil &&
                restoredHTTPS["HTTPSPort"] == nil, "Removes HTTPS keys absent before takeover")
    test.equal(restoredHTTPS["ProxyAutoConfigEnable"] as? Int, 1, "Preserves automatic proxy configuration")

    let upstream = ExternalProxyConfig(enabled: true, host: "[::1]", port: 9090,
                                       bypassHosts: ["*.example.test", "[::1]"])
    test.expect(upstream.targetsLoopback(port: 9090), "Detects upstream proxy loop")
    test.expect(!upstream.targetsLoopback(port: 9091), "Distinct local port does not loop")
    test.expect(!upstream.applies(to: "api.example.test"), "Bypass matches subdomain")
    test.expect(upstream.applies(to: "example.test"), "Subdomain bypass excludes apex")
    test.expect(!upstream.applies(to: "0:0:0:0:0:0:0:1"), "Bypass normalizes IPv6")
    test.equal(ClientTLSIdentities.hostPattern(" *.Example.Test. "), "*.example.test", "Client certificate host normalization")

    test.equal(SettingsSearchTarget.results(for: "HTTP/2").first, .http2, "Settings search locates HTTP/2")
    test.equal(SettingsSearchTarget.results(for: "PAC 自动代理配置").first, .upstreamProxy, "Settings search locates PAC")
    test.expect(SettingsSearchTarget.results(for: "no-matching-setting").isEmpty, "Settings search reports no results")
}
