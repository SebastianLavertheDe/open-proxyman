"""Compile the real Foundation-only MCP redactor and run its shared checks."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default=shutil.which("swiftc"))
    args = parser.parse_args()
    if not args.swiftc:
        parser.error("swiftc is required")
    root = Path(__file__).resolve().parents[1]
    checks = (root / "Tests/ProxyMirrorCoreChecks/MCPPrivacyChecks.swift").read_text()
    checks = checks.replace("@testable import ProxyMirrorCore\n", "").split("@MainActor\n")[0]
    harness = '''
import Foundation
struct CoreAssertions {
    func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        print("PASS " + message)
    }
    func equal<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        expect(actual == expected, message)
    }
}
@main struct MCPPrivacyFixture {
    static func main() throws { try checkMCPPrivacy(CoreAssertions()) }
}
'''
    with tempfile.TemporaryDirectory(prefix="pm-mcp-privacy-") as directory:
        target = Path(directory)
        (target / "Checks.swift").write_text(checks)
        (target / "Main.swift").write_text(harness)
        executable = target / "privacy-checks"
        subprocess.run([args.swiftc, "-parse-as-library", str(root / "Sources/ProxyMirrorCore/Export/ExportRedaction.swift"),
                        str(target / "Checks.swift"), str(target / "Main.swift"), "-o", str(executable)], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=20)


if __name__ == "__main__":
    main()
