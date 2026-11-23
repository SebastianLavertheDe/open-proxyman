#!/usr/bin/env python3
"""Compile the production release parser and exercise update decisions without networking."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile
from localization_model_test_support import localization_sources

ROOT = Path(__file__).resolve().parents[1]
MAIN = r'''
import Foundation
@main struct Checks {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            count += 1
        }
        for invalid in ["", "v", "1..2", "1.2.", "1.2.-beta", "1.2.3-", "x1.2", "1.2.3.4.5", "9999999999999999999999"] {
            check(ReleaseVersion(invalid) == nil, "reject invalid version \(invalid)")
        }
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
                       "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "2.0.0"]
        for pair in zip(ordered, ordered.dropFirst()) {
            check(ReleaseVersion(pair.0)! < ReleaseVersion(pair.1)!, "semantic version ordering")
        }
        check(ReleaseVersion("v1.2.3+build.1") == ReleaseVersion("1.2.3+build.2"), "ignore build metadata")
        check(ReleaseVersion("1.2") == ReleaseVersion("1.2.0"), "normalize component counts")
        var payload: [String: Any] = ["tag_name": "v1.2.0", "name": "Release 1.2",
            "html_url": "https://github.com/SebastianLavertheDe/open-proxyman/releases/tag/v1.2.0",
            "draft": false, "prerelease": false]
        func decode() throws -> ReleaseUpdate { try ReleaseUpdate.decode(JSONSerialization.data(withJSONObject: payload)) }
        check(try decode().isNewer(than: "1.1.1"), "newer public release prompts")
        check(try !decode().isNewer(than: "1.2.0"), "same version does not prompt")
        check(try !decode().isNewer(than: "2.0.0"), "older release does not prompt")
        payload["draft"] = true
        check(try !decode().isNewer(than: "1.0.0"), "draft never prompts")
        payload["draft"] = false
        payload["prerelease"] = true
        check(try !decode().isNewer(than: "1.0.0"), "prerelease never prompts")
        payload["prerelease"] = false
        for address in ["http://github.com/SebastianLavertheDe/open-proxyman/releases/tag/v1",
                        "https://other.example/releases/tag/v1", "https://github.com/other/project/releases/tag/v1",
                        "https://user:secret@github.com/SebastianLavertheDe/open-proxyman/releases/tag/v1"] {
            payload["html_url"] = address
            do { _ = try decode(); preconditionFailure("unsafe release link") }
            catch { count += 1 }
        }
        let request = ReleaseUpdate.request()
        check(request.url?.host == "api.github.com" && request.httpMethod == "GET", "read-only canonical release endpoint")
        check(request.value(forHTTPHeaderField: "Authorization") == nil, "public check carries no credentials")
        print("PASS: \(count) production release/version checks")
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default="swiftc")
    args = parser.parse_args()
    compiler = shutil.which(args.swiftc) or args.swiftc
    with tempfile.TemporaryDirectory(prefix="pm-release-checks-") as folder:
        folder = Path(folder)
        entry = folder / "Checks.swift"
        entry.write_text(MAIN)
        binary = folder / "checks"
        typed_sources = localization_sources(folder)
        fallback = str(ROOT / "Sources/ProxyMirrorCore/Localization/Generated/EnglishFallbacks.swift")
        if fallback not in typed_sources: typed_sources.append(fallback)
        sources = list(dict.fromkeys([
            str(ROOT / "Sources/ProxyMirrorCore/System/ReleaseUpdate.swift"),
            str(ROOT / "Sources/ProxyMirrorCore/System/LocalizedErrorPresentation.swift"),
            str(ROOT / "Sources/ProxyMirrorCore/System/GeneratedOperationIssues.swift"),
            *typed_sources, str(entry)]))
        subprocess.run([compiler, "-swift-version", "5", "-module-cache-path", str(folder / "modules"),
                        *sources, "-o", str(binary)], check=True, timeout=120)
        subprocess.run([str(binary)], check=True, timeout=15)


if __name__ == "__main__":
    main()
