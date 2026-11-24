#!/usr/bin/env python3
"""Run the real proxy's self-target, wire framing and 40-second upload regressions.

Requires the macOS ProxyMirrorSelfTest executable. Uses an empty temporary support
directory and local TCP origins; no system proxy or keychain changes are made.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path(os.environ.get("PM_SELFTEST_BIN", root / ".build/debug/ProxyMirrorSelfTest")))
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not os.access(binary, os.X_OK):
        parser.error(f"SelfTest is not executable: {binary}; build it on macOS first")
    with tempfile.TemporaryDirectory(prefix="pm-http-transport-") as temporary:
        environment = {**os.environ, "PM_SUPPORT_DIR": str(Path(temporary) / "support")}
        return subprocess.run([str(binary), "--http-transport-safety"], env=environment, timeout=90).returncode


if __name__ == "__main__":
    raise SystemExit(main())
