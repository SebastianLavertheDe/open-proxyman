import Foundation
import XCTest
@testable import ProxyMirrorFoundation

final class AndroidEmulatorSetupTests: XCTestCase {
    private final class Fixture {
        var commands: [[String]] = []
        var proxies = ["emulator-5554": ":0", "emulator-5556": "old.proxy:8080"]
        var certificates: [String: String] = [:]
        var failPush = false
        var failRemoveCertificate = false
        var raceCertificate: String?
        var onProxyRead: (() throws -> Void)?
        var staging: [String: String] = [:]
        var linked = Set<String>()
        let certificate = "-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----\n"
        func run(_ args: [String]) throws -> String {
            commands.append(args)
            if args == ["devices"] { return "List of devices attached\nemulator-5554\tdevice\nemulator-5556\tdevice\n" }
            let serial = args[1], rest = Array(args.dropFirst(2))
            if rest == ["shell", "getprop", "ro.build.version.sdk"] { return serial == "emulator-5554" ? "33" : "34" }
            if rest == ["shell", "getprop", "ro.build.fingerprint"] || rest == ["shell", "getprop", "ro.build.flavor"] { return "sdk_google_phone_x86_64" }
            if rest == ["shell", "settings", "get", "global", "http_proxy"] {
                if let onProxyRead { self.onProxyRead = nil; try onProxyRead() }
                return proxies[serial] ?? "null"
            }
            if rest.starts(with: ["shell", "settings", "put", "global", "http_proxy"]) { proxies[serial] = rest.last! }
            if rest.starts(with: ["shell", "settings", "delete"]) { proxies[serial] = "null" }
            if rest.count == 2, rest[1].hasPrefix("if [ -f") {
                let path = String(rest[1].split(separator: " ")[3])
                return (path.contains(".proxymirror-") ? staging[serial] : certificates[serial]) == nil ? "" : "present"
            }
            if rest.count == 2, rest[1].contains(" -ef ") { return linked.contains(serial) ? "owned" : "foreign" }
            if rest == ["shell", "id", "-u"] { return "0" }
            if rest.first == "push" {
                staging[serial] = failPush ? "partial certificate" : try String(contentsOfFile: rest[1], encoding: .utf8)
                if failPush { throw CocoaError(.fileWriteUnknown) }
            }
            if rest.starts(with: ["shell", "ln"]) {
                if let raceCertificate { certificates[serial] = raceCertificate }
                guard certificates[serial] == nil else { throw CocoaError(.fileWriteFileExists) }
                certificates[serial] = staging[serial]
                linked.insert(serial)
            }
            if rest.starts(with: ["shell", "rm"]) {
                if rest.last!.contains(".proxymirror-") { staging[serial] = nil }
                else {
                    if failRemoveCertificate { throw CocoaError(.fileWriteNoPermission) }
                    certificates[serial] = nil; linked.remove(serial)
                }
            }
            if rest.starts(with: ["shell", "cat"]) {
                return (rest.last!.contains(".proxymirror-") ? staging[serial] : certificates[serial]) ?? ""
            }
            return ""
        }
    }

    func testOnlySupportedDevicesAreChangedAndJournalSurvivesRestart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = Fixture(), cert = dir.appendingPathComponent("ca.pem"), journal = dir.appendingPathComponent("journal.json")
        try fixture.certificate.write(to: cert, atomically: true, encoding: .utf8)
        let setup = AndroidEmulatorSetup(journal: journal, command: fixture.run)
        let devices = try setup.devices(certificateHash: "1234abcd")
        XCTAssertEqual(devices.map(\.supported), [true, false])
        XCTAssertEqual(try setup.override(devices, certificate: cert, certificateHash: "1234abcd", proxy: "10.0.2.2:9090"), ["emulator-5554"])
        XCTAssertEqual(fixture.proxies["emulator-5554"], "10.0.2.2:9090")
        XCTAssertFalse(fixture.commands.contains { $0.starts(with: ["-s", "emulator-5556", "root"]) })
        let recovered = AndroidEmulatorSetup(journal: journal, command: fixture.run)
        XCTAssertEqual(try recovered.revert(), ["emulator-5554"])
        XCTAssertEqual(fixture.proxies["emulator-5554"], ":0")
        XCTAssertNil(fixture.certificates["emulator-5554"])
        XCTAssertEqual(try recovered.entries(), [])
    }

    func testFailedCertificateInstallCanBeRecoveredWithoutDeletingExistingCertificates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = Fixture(), cert = dir.appendingPathComponent("ca.pem")
        try fixture.certificate.write(to: cert, atomically: true, encoding: .utf8)
        let setup = AndroidEmulatorSetup(journal: dir.appendingPathComponent("journal.json"), command: fixture.run)
        fixture.failPush = true
        XCTAssertThrowsError(try setup.override(setup.devices(certificateHash: "1234abcd"), certificate: cert, certificateHash: "1234abcd", proxy: "10.0.2.2:9090"))
        XCTAssertEqual(try setup.entries().count, 1)
        XCTAssertEqual(try setup.revert(), ["emulator-5554"])
        XCTAssertEqual(fixture.proxies["emulator-5554"], ":0")
        XCTAssertNil(fixture.staging["emulator-5554"])
        fixture.certificates["emulator-5554"] = "another certificate"
        fixture.failPush = false
        XCTAssertThrowsError(try setup.override(setup.devices(certificateHash: "1234abcd"), certificate: cert, certificateHash: "1234abcd", proxy: "10.0.2.2:9090"))
        XCTAssertEqual(fixture.certificates["emulator-5554"], "another certificate")
        XCTAssertEqual(try setup.entries(), [])
    }

    func testRecoveryPreservesProxyChangedByUser() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = Fixture(), cert = dir.appendingPathComponent("ca.pem")
        try fixture.certificate.write(to: cert, atomically: true, encoding: .utf8)
        let setup = AndroidEmulatorSetup(journal: dir.appendingPathComponent("journal.json"), command: fixture.run)
        _ = try setup.override(setup.devices(certificateHash: "1234abcd"), certificate: cert, certificateHash: "1234abcd", proxy: "10.0.2.2:9090")
        fixture.proxies["emulator-5554"] = "user.proxy:8888"
        XCTAssertThrowsError(try setup.revert())
        XCTAssertEqual(fixture.proxies["emulator-5554"], "user.proxy:8888")
        XCTAssertEqual(try setup.entries().count, 1)
    }
    func testStaleDeviceSnapshotNeverOverwritesForeignCA() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = Fixture(), cert = dir.appendingPathComponent("ca.pem")
        try fixture.certificate.write(to: cert, atomically: true, encoding: .utf8)
        let setup = AndroidEmulatorSetup(journal: dir.appendingPathComponent("journal.json"), command: fixture.run)
        let devices = try setup.devices(certificateHash: "1234abcd")
        fixture.certificates["emulator-5554"] = "foreign CA"
        XCTAssertThrowsError(try setup.override(devices, certificate: cert, certificateHash: "1234abcd", proxy: "10.0.2.2:9090"))
        XCTAssertEqual(fixture.certificates["emulator-5554"], "foreign CA")
        XCTAssertEqual(fixture.proxies["emulator-5554"], ":0")
        XCTAssertEqual(try setup.entries(), [])
    }

    func testCertificateRacingWithAtomicInstallIsPreserved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = Fixture(), cert = dir.appendingPathComponent("ca.pem")
        try fixture.certificate.write(to: cert, atomically: true, encoding: .utf8)
        let setup = AndroidEmulatorSetup(journal: dir.appendingPathComponent("journal.json"), command: fixture.run)
        fixture.raceCertificate = "foreign racing CA"
        XCTAssertThrowsError(try setup.override(setup.devices(certificateHash: "1234abcd"), certificate: cert, certificateHash: "1234abcd", proxy: "10.0.2.2:9090"))
        XCTAssertEqual(try setup.revert(), ["emulator-5554"])
        XCTAssertEqual(fixture.certificates["emulator-5554"], "foreign racing CA")
        XCTAssertNil(fixture.staging["emulator-5554"])
        XCTAssertEqual(fixture.proxies["emulator-5554"], ":0")
    }

    func testPartialRecoveryDoesNotReplayRestoredProxy() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = Fixture(), cert = dir.appendingPathComponent("ca.pem")
        try fixture.certificate.write(to: cert, atomically: true, encoding: .utf8)
        let setup = AndroidEmulatorSetup(journal: dir.appendingPathComponent("journal.json"), command: fixture.run)
        _ = try setup.override(setup.devices(certificateHash: "1234abcd"), certificate: cert, certificateHash: "1234abcd", proxy: "10.0.2.2:9090")
        fixture.failRemoveCertificate = true
        XCTAssertThrowsError(try setup.revert())
        XCTAssertEqual(try setup.entries().first?.proxyPending, false)
        fixture.proxies["emulator-5554"] = "user.proxy:8888"
        fixture.failRemoveCertificate = false
        XCTAssertEqual(try setup.revert(), ["emulator-5554"])
        XCTAssertEqual(fixture.proxies["emulator-5554"], "user.proxy:8888")
        XCTAssertEqual(try setup.entries(), [])
    }

    func testCertificateSnapshotSurvivesSourceReplacementDuringSetup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = Fixture(), cert = dir.appendingPathComponent("ca.pem")
        try fixture.certificate.write(to: cert, atomically: true, encoding: .utf8)
        let setup = AndroidEmulatorSetup(journal: dir.appendingPathComponent("journal.json"), command: fixture.run)
        let devices = try setup.devices(certificateHash: "1234abcd")
        fixture.onProxyRead = { try "replacement CA".write(to: cert, atomically: true, encoding: .utf8) }
        _ = try setup.override(devices, certificate: cert, certificateHash: "1234abcd", proxy: "10.0.2.2:9090")
        XCTAssertEqual(fixture.certificates["emulator-5554"], fixture.certificate)
        XCTAssertEqual(try setup.entries().first?.expectedCertificate, fixture.certificate)
        XCTAssertEqual(try setup.revert(), ["emulator-5554"])
        XCTAssertNil(fixture.certificates["emulator-5554"])
        let push = try XCTUnwrap(fixture.commands.first { $0.count > 2 && $0[2] == "push" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: push[3]), "The local CA snapshot is cleaned up after adb completes")
    }

    func testUnsetProxyRecoveryAcceptsAndroidNullAfterInterruptedDelete() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = Fixture(), cert = dir.appendingPathComponent("ca.pem")
        fixture.proxies["emulator-5554"] = ""
        try fixture.certificate.write(to: cert, atomically: true, encoding: .utf8)
        let setup = AndroidEmulatorSetup(journal: dir.appendingPathComponent("journal.json"), command: fixture.run)
        _ = try setup.override(setup.devices(certificateHash: "1234abcd"), certificate: cert,
            certificateHash: "1234abcd", proxy: "10.0.2.2:9090", installCertificate: false)
        // Android returns null after settings delete, including a crash before the journal commit.
        fixture.proxies["emulator-5554"] = "null"
        XCTAssertEqual(try setup.revert(), ["emulator-5554"])
        XCTAssertEqual(fixture.proxies["emulator-5554"], "null")
        XCTAssertEqual(try setup.entries(), [])
    }

}
