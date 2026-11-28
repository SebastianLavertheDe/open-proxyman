import Foundation

/// The selected certificate crosses the authorization boundary as an immutable
/// argument, never as a user-writable file path. The privileged shell creates
/// its own private copy before invoking Apple's trust tool.
package struct CertificateTrustInstallPlan: Sendable {
    package let certificatePEM: String

    package init(certificatePEM: String) { self.certificatePEM = certificatePEM }

    package init?(helperArguments: [String]) {
        guard helperArguments.count == 2, helperArguments[0] == "--install-ca",
              helperArguments[1].hasPrefix("-----BEGIN CERTIFICATE-----"),
              helperArguments[1].trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("-----END CERTIFICATE-----") else { return nil }
        self.init(certificatePEM: helperArguments[1])
    }

    package var arguments: [String] { [certificatePEM] }
    package var helperArguments: [String] { ["--install-ca", certificatePEM] }
    package static let successMarker = "ProxyMirror certificate installation finished successfully"
    package static let script = #"""
    set -eu
    exec </dev/null 2>&1
    umask 077
    directory=$(/usr/bin/mktemp -d /private/tmp/ProxyMirrorCA.XXXXXX)
    trap '/bin/rm -rf -- "$directory"' EXIT
    certificate="$directory/selected-ca.pem"
    /usr/bin/printf '%s' "$1" > "$certificate"
    /usr/bin/security add-trusted-cert -d -r trustRoot -p ssl -k /Library/Keychains/System.keychain "$certificate"
    printf '\n%s\n' 'ProxyMirror certificate installation finished successfully'
    """#
}
