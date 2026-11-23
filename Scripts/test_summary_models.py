"""Compile and run the real summary/folder models with platform-only dependencies stubbed.

Works on Linux once a Swift 5.9+ toolchain is available. No app, network, settings,
Keychain or real rules storage is touched. This does not validate the macOS UI.
"""

import argparse
from pathlib import Path
from localization_model_test_support import localization_sources
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
STUBS = r'''
import Foundation

enum StubTransactionState { case pending, awaiting, completed, failed }
final class Transaction {
    var host = ""
    var statusCode = 0
    var duration = 0.0
    var requestBytes = 0
    var responseBytes = 0
    var state = StubTransactionState.pending
}
struct RuleBackup: Codable { var organization: RuleOrganization? }
enum RulesFileIO { static func load<T: Codable>(_ file: String) -> T? { nil } }
final class RulesStore {
    static let shared = RulesStore()
    func backup() -> RuleBackup { RuleBackup(organization: RuleOrganizationStore.shared.snapshot()) }
    func install(_ backup: RuleBackup) throws {
        if let organization = backup.organization { RuleOrganizationStore.shared.updateSnapshot(organization) }
    }
}
'''
MAIN = r'''
import Foundation
@main struct RunSummaryFolderChecks {
    static func main() throws {
        var failures = 0
        var checks = 0
        let assertions = CoreAssertions { passed, message, file, line in
            checks += 1
            if !passed { failures += 1; print("FAIL \(file):\(line): \(message)") }
        }
        try checkSummaryAndFolderDrafts(assertions)
        print("Summary/folder models: \(checks) checks, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default="swiftc", help="Swift compiler executable")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="pm-summary-model-check-") as temporary:
        directory = Path(temporary)
        stubs = directory / "PlatformStubs.swift"
        stubs.write_text(STUBS, encoding="utf-8")
        assertions_source = (ROOT / "Tests/ProxyMirrorCoreChecks/CoreChecks.swift").read_text(encoding="utf-8")
        assertions = directory / "Assertions.swift"
        assertions.write_text(
            "import Foundation\nstruct CoreAssertions {" + assertions_source.split("struct CoreAssertions {", 1)[1].split("func makeCheckDirectory", 1)[0],
            encoding="utf-8",
        )
        checks = directory / "SummaryFolderChecks.swift"
        checks.write_text(
            (ROOT / "Tests/ProxyMirrorCoreChecks/SummaryFolderChecks.swift").read_text(encoding="utf-8")
            .replace("@testable import ProxyMirrorCore\n", ""), encoding="utf-8",
        )
        main_file = directory / "Run.swift"
        main_file.write_text(MAIN, encoding="utf-8")
        executable = directory / "summary-folder-checks"
        subprocess.run([
            args.swiftc, "-swift-version", "5", "-module-cache-path", str(directory / "module-cache"),
            str(ROOT / "Sources/ProxyMirrorCore/Model/FlowSummaryStatistics.swift"),
            str(ROOT / "Sources/ProxyMirrorCore/Model/RuleFolderEditingDraft.swift"),
            str(ROOT / "Sources/ProxyMirrorCore/Interception/RuleOrganization.swift"),
            str(stubs), str(assertions), str(checks), str(main_file), *localization_sources(directory), "-o", str(executable),
        ], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
