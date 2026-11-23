import Foundation
#if canImport(ProxyMirrorCore)
@testable import ProxyMirrorCore
#endif

/// Shared by the CoreChecks target and the standalone native IP test executable.
func networkAccessPolicyCases() -> [(Bool, String)] {
    var results: [(Bool, String)] = []
    func check(_ condition: Bool, _ message: String) { results.append((condition, message)) }
    do {
        let exact = try NetworkAccessPolicy(ranges: ["192.168.1.20", "10.0.0.7"])
        check(exact.allows("192.168.1.20"), "Exact IPv4 peer is allowed")
        check(exact.allows("10.0.0.7"), "Multiple exact peers share the allow list")
        check(!exact.allows("192.168.1.21"), "Adjacent IPv4 peer is rejected")
        check(!exact.allows("192.168.1.20.evil.example"), "Hostnames cannot bypass numeric address matching")
        check(exact.allows("::ffff:192.168.1.20"), "IPv4-mapped IPv6 peer matches IPv4 rule")
        check(!exact.allows("::ffff:192.168.1.21"), "IPv4-mapped IPv6 peer outside rule is rejected")

        let subnet = try NetworkAccessPolicy(ranges: ["192.168.10.123/24", "10.0.0.4/31"])
        check(subnet.allows("192.168.10.1") && subnet.allows("192.168.10.254"), "IPv4 CIDR includes both host boundaries")
        check(!subnet.allows("192.168.9.255") && !subnet.allows("192.168.11.0"), "IPv4 CIDR excludes neighboring networks")
        check(subnet.ranges.contains("192.168.10.0/24"), "CIDR normalizes host bits")
        check(subnet.allows("10.0.0.4") && subnet.allows("10.0.0.5") && !subnet.allows("10.0.0.6"), "IPv4 /31 mask crosses the final bit correctly")
        let bitBoundary = try NetworkAccessPolicy(ranges: ["10.128.0.1/9"])
        check(bitBoundary.allows("10.255.255.254") && !bitBoundary.allows("10.127.255.254"), "Non-byte CIDR masks preserve the ninth bit")

        let ipv6 = try NetworkAccessPolicy(ranges: ["2001:db8:abcd:12::f/64", "fe80::20%en0", "::1"])
        check(ipv6.allows("2001:0db8:abcd:0012::1"), "IPv6 equivalent notation matches the same network")
        check(ipv6.allows("2001:db8:abcd:12:ffff:ffff:ffff:ffff"), "IPv6 /64 includes its final host")
        check(!ipv6.allows("2001:db8:abcd:13::1"), "IPv6 adjacent /64 is rejected")
        check(ipv6.allows("fe80::20%en0") && ipv6.allows("fe80::20%7"), "Scoped IPv6 peers compare their numeric address")
        check(ipv6.allows("0:0:0:0:0:0:0:1"), "IPv6 loopback can be explicitly authorized")
        check(!ipv6.allows("192.0.2.1"), "IPv6 ranges do not authorize IPv4 peers")
        let v6Bit = try NetworkAccessPolicy(ranges: ["2001:db8::/127"])
        check(v6Bit.allows("2001:db8::") && v6Bit.allows("2001:db8::1") && !v6Bit.allows("2001:db8::2"), "IPv6 /127 mask handles the final bit")

        let mapped = try NetworkAccessPolicy(ranges: ["::ffff:192.168.2.42/120"])
        check(mapped.ranges == ["192.168.2.0/24"], "Mapped IPv6 CIDR normalizes to an IPv4 range")
        check(mapped.allows("192.168.2.8") && mapped.allows("::ffff:c0a8:208"), "Mapped CIDR accepts both transport representations")
        check(!mapped.allows("192.168.3.8"), "Mapped CIDR enforces its network boundary")

        let empty = try NetworkAccessPolicy(ranges: [])
        check(!empty.allows("127.0.0.1") && !empty.allows("::1"), "An empty allow list denies every peer")
        let all = try NetworkAccessPolicy(ranges: ["0.0.0.0/0", "::/0"])
        check(all.allows("203.0.113.1") && all.allows("2001:db8::1"), "Explicit /0 includes unicast peers of each family")
        check(!all.allows("0.0.0.0") && !all.allows("::"), "Unspecified addresses are never accepted as peers")
        check(!all.allows("224.0.0.1") && !all.allows("ff02::1"), "Multicast addresses are never accepted as peers")
        check(!all.allows("255.255.255.255"), "Broadcast is never accepted as a peer")
        let deduplicated = try NetworkAccessPolicy(ranges: ["192.0.2.1/24", "192.0.2.200/24"])
        check(deduplicated.ranges == ["192.0.2.0/24"], "Equivalent CIDR entries are deduplicated")
    } catch { check(false, "Unexpected policy construction failure: \(error.localizedDescription)") }

    let invalid = ["", "localhost", "example.com/24", "192.168.1.999", "192.168.1", "01.2.3.4", "1.2.3.4/33",
                   "1.2.3.4/-1", "1.2.3.4/+1", "1.2.3.4/", "1.2.3.4/24/8", "1.2.3.4 /24", "::/129",
                   "::/x", "::ffff:192.0.2.1/95", "fe80::1%", "fe80::1%bad zone", "https://192.0.2.1"]
    for range in invalid {
        check(NetworkAccessPolicy.validationError(for: [range]) != nil, "Invalid range is rejected: \(range)")
    }
    check(NetworkAccessPolicy.validationError(for: Array(repeating: "192.0.2.1", count: 257)) != nil,
          "Whitelist input count is bounded before deduplication")
    check(NetworkAccessPolicy.validationError(for: Array(repeating: "192.0.2.1", count: 256)) == nil,
          "Maximum supported whitelist count is accepted")
    return results
}

#if canImport(ProxyMirrorCore)
func checkNetworkAccessPolicy(_ test: CoreAssertions) {
    for (passed, message) in networkAccessPolicyCases() { test.expect(passed, message) }
}
#endif
