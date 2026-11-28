import Foundation
import ProxyMirrorFoundation
import XCTest

final class SystemProxyBypassLeaseTests: XCTestCase {
    func testCaptureKeepsExplicitExceptionsAndOnlyExemptsTheListenerPort() throws {
        let plain = ["localhost", "*.corp.test", "127.0.0.1:5432"]
        let lease = SystemProxyBypassLease(restoreHosts: plain, plainHosts: plain, captureLocalRequests: true, port: 8123)
        let hosts = try XCTUnwrap(lease.installedHosts)

        XCTAssertEqual(hosts.first, "<-loopback>")
        XCTAssertEqual(hosts.filter(plain.contains), plain)
        XCTAssertTrue(hosts.contains("169.254.0.0/16"))
        XCTAssertTrue(hosts.contains("fe80::/10"))
        XCTAssertTrue(hosts.contains("0.0.0.0/32"))
        XCTAssertTrue(hosts.contains("::/128"))
        XCTAssertTrue(hosts.contains("127.0.0.1:8123"))
        XCTAssertFalse(hosts.contains("127.0.0.1:9090"))
        XCTAssertFalse(hosts.contains("127.0.0.1:52112"))
        XCTAssertFalse(hosts.contains("127.0.0.1"))
        XCTAssertFalse(hosts.contains("127.0.0.0/8"))
    }

    func testDisabledCaptureUsesPlainListWithoutImplicitAdditions() {
        let plain = ["localhost", "127.0.0.1", "*.work.test"]
        let lease = SystemProxyBypassLease(restoreHosts: plain, plainHosts: plain, captureLocalRequests: false, port: 9090)
        XCTAssertEqual(lease.installedHosts, plain)
        XCTAssertEqual(lease.restoredHosts(from: ["new.test"]), ["new.test"])

        let absent = SystemProxyBypassLease(restoreHosts: nil, plainHosts: nil, captureLocalRequests: false, port: 9090)
        XCTAssertNil(absent.installedHosts)
    }

    func testTwoServicesRestoreTheirOwnOriginalRules() throws {
        let wifiHosts = ["*.wifi.test", "169.254.0.0/16", "127.0.0.1:9090"]
        let vpnHosts = ["*.vpn.test", "<-loopback>"]
        for original in [wifiHosts, vpnHosts] {
            let lease = SystemProxyBypassLease(restoreHosts: original, plainHosts: original, captureLocalRequests: true, port: 9090)
            let installed = try XCTUnwrap(lease.installedHosts)
            XCTAssertEqual(lease.restoredHosts(from: installed), original)
            XCTAssertEqual(lease.removingCaptureRules(from: installed + ["new.test"]), original + ["new.test"])
        }
    }

    func testRestorationDistinguishesMissingExceptionsFromAnExplicitEmptyList() throws {
        let originals: [[String]?] = [nil, []]
        for original in originals {
            let lease = SystemProxyBypassLease(restoreHosts: original, plainHosts: original, captureLocalRequests: true, port: 9090)
            let installed = try XCTUnwrap(lease.installedHosts)
            XCTAssertEqual(lease.removingCaptureRules(from: installed), original)
            XCTAssertEqual(lease.restoredHosts(from: installed), original)
            XCTAssertNil(lease.restoredHosts(from: nil))
        }
    }

    func testExistingSubtractionCannotCancelLinkLocalAndListenerProtection() throws {
        let original = ["169.254.0.0/16", "127.0.0.1:9090", "<-loopback>", "*.corp.test"]
        let lease = SystemProxyBypassLease(restoreHosts: original, plainHosts: original, captureLocalRequests: true, port: 9090)
        let installed = try XCTUnwrap(lease.installedHosts)
        let lastSubtraction = try XCTUnwrap(installed.lastIndex(of: "<-loopback>"))
        for guardRule in ["169.254.0.0/16", "127.0.0.1:9090"] {
            let lastGuard = try XCTUnwrap(installed.lastIndex(of: guardRule))
            XCTAssertGreaterThan(lastGuard, lastSubtraction)
        }
        XCTAssertEqual(lease.restoredHosts(from: installed + ["new.test"]), original + ["new.test"])
    }

    func testRestorationPreservesExternalAdditionsRemovalsAndOrder() throws {
        let original = ["one.test", "removed.test", "three.test"]
        let lease = SystemProxyBypassLease(restoreHosts: original, plainHosts: original, captureLocalRequests: true, port: 9090)
        let installed = try XCTUnwrap(lease.installedHosts)
        let remaining = installed.filter { $0 != "removed.test" && $0 != "169.254.0.0/16" }
        let edited = ["external.test"] + remaining.reversed()
        XCTAssertEqual(lease.removingCaptureRules(from: edited), ["external.test", "three.test", "one.test"])
        XCTAssertEqual(lease.restoredHosts(from: edited), ["external.test", "three.test", "one.test"])
    }

    func testCustomListRestoresOriginalOnlyWhileStillOwned() throws {
        let system = ["*.system.test"]
        let custom = ["*.custom.test", "127.0.0.1"]
        for capture in [false, true] {
            let lease = SystemProxyBypassLease(restoreHosts: system, plainHosts: custom, captureLocalRequests: capture, port: 9090)
            let installed = try XCTUnwrap(lease.installedHosts)
            XCTAssertEqual(lease.removingCaptureRules(from: installed), custom)
            XCTAssertEqual(lease.restoredHosts(from: installed), system)
            XCTAssertEqual(lease.restoredHosts(from: ["external.test"]), ["external.test"])
        }
    }

    func testJournalRoundTripRecoversServiceSpecificChangesAfterRestart() throws {
        let services = [
            "wifi": SystemProxyBypassLease(restoreHosts: nil, plainHosts: nil, captureLocalRequests: true, port: 8111),
            "vpn": SystemProxyBypassLease(restoreHosts: ["old.test"], plainHosts: ["<-loopback>", "*.vpn.test"],
                                          captureLocalRequests: true, port: 8111),
        ]
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let journal = try encoder.encode(services)
        let wifiHosts = try XCTUnwrap(services["wifi"]?.installedHosts)
        let modifiedVPN = try XCTUnwrap(services["vpn"]?.installedHosts) + ["third.party"]
        let recovered = try PropertyListDecoder().decode([String: SystemProxyBypassLease].self, from: journal)
        let wifi = try XCTUnwrap(recovered["wifi"])
        let vpn = try XCTUnwrap(recovered["vpn"])
        XCTAssertNil(wifi.restoredHosts(from: wifiHosts))
        XCTAssertEqual(vpn.restoredHosts(from: modifiedVPN), ["<-loopback>", "*.vpn.test", "third.party"])
    }

    func testExternalAppendAndPrependMatchingGeneratedRulesSurviveInOrder() throws {
        let rule = "169.254.0.0/16"
        let original = ["corp.test"]
        let lease = SystemProxyBypassLease(restoreHosts: original, plainHosts: original, captureLocalRequests: true, port: 9090)
        let installed = try XCTUnwrap(lease.installedHosts)
        let added = ["external.test", rule, "after.test"]
        XCTAssertEqual(lease.restoredHosts(from: installed + added), original + added)
        let prepended = ["before.test", "<-loopback>", "new.test"]
        XCTAssertEqual(lease.restoredHosts(from: prepended + installed), prepended + original)
    }

    func testCustomListRestoresAnOriginalRuleAlsoInsertedForCapture() throws {
        let system = ["169.254.0.0/16", "corp.test", "127.0.0.1:9090"]
        let lease = SystemProxyBypassLease(restoreHosts: system, plainHosts: ["custom.test"], captureLocalRequests: true, port: 9090)
        let installed = try XCTUnwrap(lease.installedHosts)
        XCTAssertEqual(lease.removingCaptureRules(from: installed), ["custom.test"])
        XCTAssertEqual(lease.restoredHosts(from: installed), system)
    }
}
