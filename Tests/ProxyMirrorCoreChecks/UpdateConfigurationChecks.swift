import Foundation
@testable import ProxyMirrorCore

func checkUpdateConfiguration(_ test: CoreAssertions) throws {
    test.expect(try AppUpdateConfiguration.read([:]) == nil,
                "Updates: builds without a signed feed use the public release checker")
    let key = Data(repeating: 1, count: 32).base64EncodedString()
    let configuration = try AppUpdateConfiguration.read(["SUFeedURL": "https://updates.example.test/appcast.xml", "SUPublicEDKey": key])
    test.equal(configuration?.feedURL.scheme, "https", "Updates: configured feeds require HTTPS")
    test.equal(configuration?.publicKey, key, "Updates: public keys retain their exact configured value")
    for url in ["http://updates.example.test/feed", "file:///tmp/feed", "https://user:secret@example.test/feed", "https://example.test/feed#fragment"] {
        test.rejects(try AppUpdateConfiguration.read(["SUFeedURL": url, "SUPublicEDKey": key]),
                     with: AppUpdateConfiguration.ConfigurationError.self, "Updates: unsafe feed URLs are rejected")
    }
    test.rejects(try AppUpdateConfiguration.read(["SUFeedURL": "https://example.test/feed", "SUPublicEDKey": "YQ=="]),
                 with: AppUpdateConfiguration.ConfigurationError.self, "Updates: signing public keys must be 32 bytes")
    test.rejects(try AppUpdateConfiguration.read(["SUFeedURL": "https://example.test/feed"]),
                 with: AppUpdateConfiguration.ConfigurationError.self, "Updates: partial configuration is rejected")
}
