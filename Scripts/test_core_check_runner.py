#!/usr/bin/env python3
"""Exercise the actual XCTest worker wrapper, without importing desktop services.

Only CoreCheckGroup's case identifiers are supplied by the small fixture module;
the process launch, output collection, deadline and XCTest assertions are the
unchanged repository implementation.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    swift = shutil.which("swift")
    if not swift:
        raise SystemExit("swift is required")
    with tempfile.TemporaryDirectory(prefix="pm-core-runner-") as temporary:
        directory = Path(temporary)
        target = directory / "Sources/ProxyMirrorCoreChecks"
        tests = directory / "Tests/ProxyMirrorCoreTests"
        target.mkdir(parents=True)
        tests.mkdir(parents=True)
        group_source = (ROOT / "Tests/ProxyMirrorCoreChecks/CoreChecks.swift").read_text()
        identifiers = group_source.split("    case ", 1)[1].split("\n", 1)[0]
        (target / "Groups.swift").write_text(
            "package enum CoreCheckGroup: String { case " + identifiers + " }\n"
        )
        (tests / "ProxyMirrorCoreTests.swift").symlink_to(
            ROOT / "Tests/ProxyMirrorCoreTests/ProxyMirrorCoreTests.swift"
        )
        (directory / "Package.swift").write_text('''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "CoreRunnerChecks", targets: [
    .target(name: "ProxyMirrorCoreChecks"),
    .testTarget(name: "ProxyMirrorCoreTests", dependencies: ["ProxyMirrorCoreChecks"])
], swiftLanguageVersions: [.v5])
''')
        worker = directory / "worker.py"
        worker.write_text('''#!/usr/bin/env python3
import os, sys, time
assert sys.argv[1:] == ["--core-unit", "capture"]
assert os.path.isabs(os.environ["PM_SUPPORT_DIR"])
print("fixture stdout", flush=True)
print("fixture stderr", file=sys.stderr, flush=True)
mode = os.environ["PM_WORKER_MODE"]
if mode == "timeout": time.sleep(30)
sys.exit(7 if mode == "failure" else 0)
''')
        worker.chmod(0o755)
        command = [swift, "test", "--package-path", str(directory), "-j", "2",
                   "--filter", "ProxyMirrorCoreTests.testCapture"]
        environment = os.environ.copy()
        environment.update(PM_SELFTEST_BIN=str(worker), PM_CORE_GROUP_TIMEOUT="1")
        for mode in ["success", "failure", "timeout"]:
            environment["PM_WORKER_MODE"] = mode
            started = time.monotonic()
            result = subprocess.run(command, cwd=directory, env=environment, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=120)
            output = result.stdout
            assert "fixture stdout" in output and "fixture stderr" in output, output
            assert "CORE GROUP START capture" in output, output
            if mode == "success":
                assert result.returncode == 0 and "status=0" in output, output
            elif mode == "failure":
                assert result.returncode != 0 and "status=7" in output, output
            else:
                assert result.returncode != 0 and "exceeded 1.0s" in output, output
                assert time.monotonic() - started < 15, output
            print(f"PASS Core XCTest worker {mode}")


if __name__ == "__main__":
    main()
