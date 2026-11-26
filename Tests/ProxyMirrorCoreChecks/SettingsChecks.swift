import Foundation
@testable import ProxyMirrorCore
import ProxyMirrorSystemProxy

func checkSettings(_ test: CoreAssertions) {
    checkNetworkAccessPolicy(test)
    do {
        try checkExternalInclusiveRouting(test)
        try checkRuleMutations(test)
    } catch { test.expect(false, "External routing/rule mutation checks: \(error.localizedDescription)") }
    checkSystemBypassSettings(test)
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
    let disabled = SystemProxySettings.restoredConfiguration(current, original: original,
                                                             ownedPort: 9090, restorePrevious: false)
    test.expect(disabled["HTTPEnable"] as? Int == 0 && disabled["HTTPProxy"] == nil && disabled["HTTPPort"] == nil,
                "Disabling previous-proxy restoration removes only the application's owned HTTP endpoint")
    test.equal(disabled["HTTPSProxy"] as? String, "external", "Disable-owned preserves a third-party HTTPS change")
    test.equal(disabled["HTTPSPort"] as? Int, 8080, "Disable-owned preserves a third-party HTTPS port")

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
    checkSettingsSearchDestinations(test)
}

private func checkSettingsSearchDestinations(_ test: CoreAssertions) {
    let destinations: [(query: String, control: SettingsSearchTarget, page: PreferencesPage, sheet: Bool)] = [
        ("menu bar", .menuBar, .general, false), ("菜单栏", .menuBar, .general, false),
        ("truncation", .truncation, .general, false), ("截断样式", .truncation, .general, false),
        ("Apple traffic", .appleTraffic, .advanced, false), ("Apple 流量", .appleTraffic, .advanced, false),
        ("MCP privacy", .mcpPrivacy, .mcp, false), ("AI 脱敏", .mcpPrivacy, .mcp, false),
        ("脱敏 敏感头", .privacy, .privacy, false),
        ("h2c", .h2c, .advanced, true), ("明文上游", .h2c, .advanced, true),
        ("捕获本机请求", .bypassProxy, .advanced, true), ("Capture local requests", .bypassProxy, .advanced, true),
        ("HTTP/2", .http2, .general, false),
        ("Content layout", .contentLayout, .general, false),
        ("Preserve original headers", .copyBehavior, .tools, false),
        ("Use monospaced font", .displayBehavior, .appearance, false),
        ("Scroll beyond last line", .displayBehavior, .appearance, false),
        ("Warn before quitting", .appBehavior, .general, false)
    ]
    for destination in destinations {
        let result = SettingsSearchTarget.results(for: destination.query).first
        // PreferencesSetting and both ScrollViewReader paths use this same stable control ID.
        test.expect(result?.id == destination.control.id && result?.page == destination.page
                    && result?.opensConnectionSettings == destination.sheet,
                    "Settings query \(destination.query) routes to its actual page, sheet and control ID")
    }
    for query in ["menu bar", "truncation", "Apple traffic"] {
        test.expect(!SettingsSearchTarget.results(for: query).contains(.displayBehavior),
                    "Moved setting \(query) no longer points to the appearance group")
    }
    test.expect(!SettingsSearchTarget.results(for: "redact sensitive").contains(.copyBehavior),
                "Redaction search no longer points to tools after privacy controls moved")
}


private func checkSystemBypassSettings(_ test: CoreAssertions) {
    let owned = ["*.example.test", "10.0.0.0/8"]
    let original: [String: Any] = ["ExceptionsList": ["localhost", "*.local"]]
    let current: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 9090,
                                  "ExceptionsList": owned]
    let restored = SystemProxySettings.restoredConfiguration(current, original: original, ownedPort: 9090,
                                                              ownedBypassLists: [owned])
    test.equal(restored["ExceptionsList"] as? [String], ["localhost", "*.local"], "Restores the bypass list owned by the takeover")
    let absent = SystemProxySettings.restoredConfiguration(current, original: [:], ownedPort: 9090, ownedBypassLists: [owned])
    test.expect(absent["ExceptionsList"] == nil, "Restoration removes a bypass key absent before takeover")
    var external = current
    external["ExceptionsList"] = ["other-application.test"]
    let preserved = SystemProxySettings.restoredConfiguration(external, original: original, ownedPort: 9090,
                                                              ownedBypassLists: [owned])
    test.equal(preserved["ExceptionsList"] as? [String], ["other-application.test"],
               "Restoration preserves a third-party bypass change")
    let previous = SystemProxySettings.restoredConfiguration(current, original: original, ownedPort: 9090,
                                                             ownedBypassLists: [owned, ["new.example.test"]])
    test.equal(previous["ExceptionsList"] as? [String], ["localhost", "*.local"],
               "Recovery recognizes the prior owned list after an interrupted update")
    test.equal(SystemProxyBypassList.normalized([" *.Example.Test ", "*.example.test", "", "localhost"]),
               ["*.example.test", "localhost"], "System bypass normalization trims and removes duplicates")
    test.expect(SystemProxyBypassList.validationError(["*.example.test", "10.0.0.0/8", "::1", "localhost"]) == nil,
                "System bypass accepts hostname, CIDR, IPv6 and local hostname patterns")
    test.expect(SystemProxyBypassList.validationError(["https://example.test/"]) != nil,
                "System bypass rejects URLs")
    test.expect(SystemProxyBypassList.validationError(["bad\nhost"]) != nil,
                "System bypass rejects control characters")
    let proxy = ExternalProxyConfig(enabled: true, host: "proxy.example.test", port: 8080)
    for host in ["localhost", "app.localhost", "127.0.0.1", "127.8.2.3", "::1", "::ffff:127.0.0.1"] {
        test.expect(!proxy.applies(to: host, respectGlobalSwitch: false), "External proxy always bypasses \(host)")
    }
    test.expect(proxy.applies(to: "public.example.test", respectGlobalSwitch: false),
                "External proxy still applies to public destinations")
}
