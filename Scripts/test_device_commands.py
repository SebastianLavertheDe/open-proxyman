#!/usr/bin/env python3
"""Compile the production Swift device runner and exercise real local processes."""
import argparse
from pathlib import Path
from foundation_test_support import build_foundation_module
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default="swiftc")
    args = parser.parse_args()
    compiler = shutil.which(args.swiftc) or args.swiftc
    with tempfile.TemporaryDirectory(prefix="pm-device-native-") as temporary:
        module_flags = build_foundation_module(compiler, temporary)
        executable = Path(temporary) / "device-command-checks"
        subprocess.run([compiler, "-swift-version", "5", "-parse-as-library",
                        *module_flags,
                        str(ROOT / "Tests/Fixtures/DeviceCommandRunner/main.swift"),
                        "-o", str(executable)], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=20)


if __name__ == "__main__":
    main()
