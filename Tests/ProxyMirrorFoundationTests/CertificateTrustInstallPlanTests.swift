import Foundation
import XCTest
import ProxyMirrorFoundation

final class CertificateTrustInstallPlanTests: XCTestCase {
    func testSelectionIsAnImmutableArgumentAndThePrivilegedScriptHasOnlyFixedToolPaths() {
        var selected = "-----BEGIN CERTIFICATE-----\nselected\n-----END CERTIFICATE-----\n"
        let plan = CertificateTrustInstallPlan(certificatePEM: selected)
        selected = "different certificate"
        XCTAssertEqual(plan.arguments, [plan.certificatePEM])
        XCTAssertEqual(CertificateTrustInstallPlan(helperArguments: plan.helperArguments)?.certificatePEM, plan.certificatePEM)
        XCTAssertNil(CertificateTrustInstallPlan(helperArguments: ["--install-ca"]))
        XCTAssertNil(CertificateTrustInstallPlan(helperArguments: ["--install-ca", selected, "extra"]))
        XCTAssertNil(CertificateTrustInstallPlan(helperArguments: ["--serve", plan.certificatePEM]))
        XCTAssertNil(CertificateTrustInstallPlan(helperArguments: ["--install-ca", "/tmp/caller-owned-certificate.pem"]))
        XCTAssertFalse(plan.certificatePEM.contains(selected))
        XCTAssertTrue(CertificateTrustInstallPlan.script.contains("/usr/bin/security add-trusted-cert"))
        XCTAssertTrue(CertificateTrustInstallPlan.script.contains("/private/tmp/ProxyMirrorCA.XXXXXX"))
        XCTAssertFalse(CertificateTrustInstallPlan.script.contains("TMPDIR"))
        XCTAssertFalse(CertificateTrustInstallPlan.script.contains("eval"))
    }

    func testUnprivilegedBoundaryFixtureInstallsExactSelectedBytesAndCleansItsPrivateSnapshot() throws {
        try exerciseBoundary(exitStatus: 0)
    }

    func testFailedTrustCommandPropagatesFailureAndStillCleansItsPrivateSnapshot() throws {
        try exerciseBoundary(exitStatus: 23)
    }

    private func exerciseBoundary(exitStatus: Int32) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pm-ca-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let unusualDirectory = root.appendingPathComponent("space's $(touch PWNED)")
        try FileManager.default.createDirectory(at: unusualDirectory, withIntermediateDirectories: false)
        let captured = root.appendingPathComponent("captured.pem")
        let snapshotPath = root.appendingPathComponent("snapshot-path")
        let fakeSecurity = unusualDirectory.appendingPathComponent("security")
        // Only the external trust-tool boundary is replaced. This fixture never
        // runs Apple's security, Authorization Services or an elevated process.
        let source = #"""
        #!/bin/sh
        for certificate do :; done
        /bin/cp "$certificate" "$PM_CAPTURE"
        printf '%s' "$certificate" > "$PM_SNAPSHOT_PATH"
        /bin/ls -ld "$certificate" "${certificate%/*}"
        exit "$PM_SECURITY_EXIT"
        """#
        try source.write(to: fakeSecurity, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSecurity.path)
        let selected = "-----BEGIN CERTIFICATE-----\nselected $(touch PWNED) ' \" `echo PWNED`\n-----END CERTIFICATE-----\n"
        let plan = CertificateTrustInstallPlan(certificatePEM: selected)
        // The formerly shared, caller-owned file can be changed independently.
        try "replacement".write(to: unusualDirectory.appendingPathComponent("ProxyMirrorCA.pem"), atomically: true, encoding: .utf8)
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = CertificateTrustInstallPlan.script
            .replacingOccurrences(of: "/private/tmp/ProxyMirrorCA.XXXXXX", with: quote(unusualDirectory.appendingPathComponent("ProxyMirrorCA.XXXXXX").path))
            .replacingOccurrences(of: "/usr/bin/security", with: quote(fakeSecurity.path))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "ProxyMirror"] + plan.arguments
        process.currentDirectoryURL = root
        process.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": unusualDirectory.path,
                               "PM_CAPTURE": captured.path, "PM_SNAPSHOT_PATH": snapshotPath.path,
                               "PM_SECURITY_EXIT": String(exitStatus)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, exitStatus, output)
        XCTAssertEqual(try Data(contentsOf: captured), Data(selected.utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("PWNED").path))
        XCTAssertTrue(output.contains("-rw-------"), output)
        XCTAssertTrue(output.contains("drwx------"), output)
        let privateSnapshot = try String(contentsOf: snapshotPath, encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: privateSnapshot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: privateSnapshot).deletingLastPathComponent().path))
        XCTAssertEqual(output.contains(CertificateTrustInstallPlan.successMarker), exitStatus == 0, output)
    }
}
