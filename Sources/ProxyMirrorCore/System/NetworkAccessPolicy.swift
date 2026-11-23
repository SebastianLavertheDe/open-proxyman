import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A numeric IP allow list. Hostnames never enter the access decision, so DNS
/// changes cannot turn an approved device into a different peer.
struct NetworkAccessPolicy: Equatable, Sendable {
    static let maximumRanges = 256
    let ranges: [String]
    private let networks: [IPNetworkRange]

    init(ranges: [String]) throws {
        guard ranges.count <= Self.maximumRanges else { throw ValidationError(OperationIssue.networkAccessPolicyTheAccessListSupportsUpToEntries(Int(Self.maximumRanges))) }
        var parsed: [IPNetworkRange] = []
        for range in ranges {
            guard let network = IPNetworkRange(range) else { throw ValidationError(OperationIssue.networkAccessPolicyInvalidIpAddressOrCidr(String(String(range.prefix(128))))) }
            if !parsed.contains(network) { parsed.append(network) }
        }
        networks = parsed
        self.ranges = parsed.map(\.description)
    }

    static func validationError(for ranges: [String]) -> String? {
        do { _ = try Self(ranges: ranges); return nil }
        catch { return error.localizedDescription }
    }

    static func localizedValidationError(for ranges: [String]) -> String? {
        do { _ = try Self(ranges: ranges); return nil }
        catch { return LocalizedErrorPresentation.message(for: error) }
    }

    func allows(_ peer: String) -> Bool {
        guard let address = NumericIPAddress(peer), address.isUnicast else { return false }
        return networks.contains { $0.contains(address) }
    }

    struct ValidationError: LocalizedError, OperationIssueProviding {
        let operationIssue: OperationIssue
        init(_ issue: OperationIssue) { operationIssue = issue }
        init(_ message: String) { operationIssue = .technical(message) }
        var message: String { operationIssue.diagnostic }
        var text: String { operationIssue.diagnostic }
        var errorDescription: String? { operationIssue.diagnostic }
    }
}

/// IPv4-mapped IPv6 peers normalize to IPv4 before comparison. A mapped IPv6
/// CIDR is accepted only for /96.../128, where it has an unambiguous IPv4 range.
struct IPNetworkRange: Equatable, Sendable, CustomStringConvertible {
    private let network: [UInt8]
    private let prefix: Int

    init?(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 256,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let address = NumericIPAddress(String(parts[0]), normalizeMapped: false) else { return nil }
        let rawPrefix: Int
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(parts[1]) else { return nil }
            rawPrefix = count
        } else { rawPrefix = address.bytes.count * 8 }
        guard (0...address.bytes.count * 8).contains(rawPrefix) else { return nil }
        let bytes: [UInt8]
        let normalizedPrefix: Int
        if address.isIPv4Mapped {
            guard rawPrefix >= 96 else { return nil }
            bytes = Array(address.bytes.suffix(4))
            normalizedPrefix = rawPrefix - 96
        } else {
            bytes = address.bytes
            normalizedPrefix = rawPrefix
        }
        prefix = normalizedPrefix
        network = bytes.enumerated().map { offset, byte in byte & Self.mask(normalizedPrefix - offset * 8) }
    }

    fileprivate func contains(_ address: NumericIPAddress) -> Bool {
        guard address.bytes.count == network.count else { return false }
        return zip(address.bytes, network).enumerated().allSatisfy { offset, pair in
            pair.0 & Self.mask(prefix - offset * 8) == pair.1
        }
    }

    var description: String {
        let address = NumericIPAddress.presentation(network)
        return prefix == network.count * 8 ? address : "\(address)/\(prefix)"
    }

    private static func mask(_ remaining: Int) -> UInt8 {
        if remaining <= 0 { return 0 }
        if remaining >= 8 { return 255 }
        return UInt8(255 << (8 - remaining) & 255)
    }
}

struct NumericIPAddress: Equatable, Sendable {
    let bytes: [UInt8]

    init?(_ value: String, normalizeMapped: Bool = true) {
        var literal = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if literal.hasPrefix("[") && literal.hasSuffix("]") { literal = String(literal.dropFirst().dropLast()) }
        // Scoped link-local addresses identify the interface at bind time. Peer
        // authorization compares the numeric address on that chosen listener.
        if let scope = literal.firstIndex(of: "%") {
            let zone = literal[literal.index(after: scope)...]
            guard literal[..<scope].contains(":"), !zone.isEmpty, zone.utf8.count <= 64,
                  zone.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }) else { return nil }
            literal = String(literal[..<scope])
        }
        var v4 = in_addr()
        if inet_pton(AF_INET, literal, &v4) == 1 {
            bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, literal, &v6) == 1 else { return nil }
        let raw = withUnsafeBytes(of: &v6) { Array($0) }
        let mapped = raw.prefix(10).allSatisfy { $0 == 0 } && raw[10] == 255 && raw[11] == 255
        bytes = normalizeMapped && mapped ? Array(raw.suffix(4)) : raw
    }

    var isIPv4Mapped: Bool {
        bytes.count == 16 && bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255
    }

    var isUnicast: Bool {
        if bytes.count == 4 { return bytes[0] > 0 && bytes[0] < 224 && bytes != [255, 255, 255, 255] }
        return !bytes.allSatisfy { $0 == 0 } && bytes[0] != 255
    }

    var isLoopback: Bool {
        bytes.count == 4 ? bytes[0] == 127 : bytes == Array(repeating: UInt8(0), count: 15) + [1]
    }

    var description: String { Self.presentation(bytes) }

    static func presentation(_ bytes: [UInt8]) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let capacity = socklen_t(buffer.count)
        let result = bytes.withUnsafeBytes { source in
            inet_ntop(bytes.count == 4 ? AF_INET : AF_INET6, source.baseAddress, &buffer, capacity)
        }
        return result == nil ? "" : String(cString: buffer)
    }
}
