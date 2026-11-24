"""Compile production debounced persistence and shared shutdown/failure checks."""
import argparse
from pathlib import Path
from foundation_test_support import build_foundation_module
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
    assertions = (root / "Tests/ProxyMirrorCoreChecks/CoreChecks.swift").read_text()
    assertions = "import Foundation\nstruct CoreAssertions {" + assertions.split("struct CoreAssertions {", 1)[1]
    checks = (root / "Tests/ProxyMirrorCoreChecks/PendingSaveChecks.swift").read_text()
    checks = checks.replace("@testable import ProxyMirrorCore\n", "")
    entry = r'''
@main struct RunPendingSaveChecks {
    static func main() throws {
        var count = 0
        var failures = 0
        let test = CoreAssertions { passed, message, file, line in
            count += 1
            if !passed { failures += 1; print("FAIL \(file):\(line): \(message)") }
        }
        try checkPendingSaves(test)
        print("Pending saves: \(count) checks, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="pm-pending-saves-") as temporary:
        directory = Path(temporary)
        module_flags = build_foundation_module(args.swiftc, directory)
        fixture = directory / "Checks.swift"
        fixture.write_text("@_exported import ProxyMirrorFoundation\n" + assertions + "\n" + checks + entry)
        executable = directory / "checks"
        subprocess.run([args.swiftc, "-swift-version", "5", "-parse-as-library",
                        *module_flags,
                        str(fixture), "-o", str(executable)], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=20)


if __name__ == "__main__":
    main()
