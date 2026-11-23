import Foundation
@testable import ProxyMirrorCore

func checkReleaseUpdates(_ test: CoreAssertions) throws {
    test.expect(ReleaseVersion("v1.2.0")! > ReleaseVersion("1.1.1")!, "Release checks compare numeric version components")
    test.expect(ReleaseVersion("1.0.0-rc.2")! < ReleaseVersion("1.0.0")!, "A stable release supersedes its prerelease")
    test.equal(ReleaseVersion("1.2+build.1"), ReleaseVersion("1.2.0+build.2"), "Build metadata does not trigger an update")
    for invalid in ["", "v", "1..2", "1.2.3-", "1.2.3.4.5"] {
        test.expect(ReleaseVersion(invalid) == nil, "Malformed release versions are rejected")
    }
    let payload: [String: Any] = ["tag_name": "v2.0.0", "name": "Release 2",
        "html_url": "https://github.com/SebastianLavertheDe/open-proxyman/releases/tag/v2.0.0",
        "draft": false, "prerelease": false]
    let release = try ReleaseUpdate.decode(JSONSerialization.data(withJSONObject: payload))
    test.expect(release.isNewer(than: "1.1.1") && !release.isNewer(than: "2.0.0"), "Only a newer public release triggers the notification")
    var unsafe = payload
    unsafe["html_url"] = "https://other.example/download"
    test.rejects(try ReleaseUpdate.decode(JSONSerialization.data(withJSONObject: unsafe)),
                 with: ReleaseUpdate.Failure.self, "Update metadata cannot send the user to an unrelated download host")
}
