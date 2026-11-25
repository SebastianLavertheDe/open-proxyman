#!/usr/bin/env python3
"""Exercise the production Sparkle verifier with real CryptoKit signatures on macOS."""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]

if __name__ == "__main__":
    if sys.platform != "darwin":
        raise SystemExit("Appcast signature verification requires the macOS CryptoKit test lane")
    with tempfile.TemporaryDirectory(prefix="pm-appcast-verification-") as temporary:
        executable = Path(temporary) / "checks"
        subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", "-D", "APPCAST_TESTING",
                        str(ROOT / "Scripts/verify_release_appcast.swift"),
                        str(ROOT / "Tests/Fixtures/AppcastVerification/main.swift"), "-o", str(executable)],
                       check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=20)
