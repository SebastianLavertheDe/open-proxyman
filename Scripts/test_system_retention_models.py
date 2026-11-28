"""Run retention policies through their actual SwiftPM production module.

Native CoreChecks separately exercise TrafficStore, Combine notifications,
saved/archive preservation and the macOS system proxy adapter.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", default="swift")
    parser.add_argument("--swiftc", help="Select the sibling swift executable")
    args = parser.parse_args()
    compiler = args.swift
    if args.swiftc:
        compiler = str(Path(shutil.which(args.swiftc) or args.swiftc).resolve().with_name("swift"))
    root = Path(__file__).resolve().parents[1]
    # Linux's platform-specific target graph can remove desktop pins during
    # resolution. Test a source snapshot so this read-only check preserves the
    # repository lock and never downloads macOS-only dependencies from its pins.
    with tempfile.TemporaryDirectory(prefix="pm-retention-module-") as temporary:
        package = root
        if sys.platform != "darwin":
            package = Path(temporary)
            shutil.copy2(root / "Package.swift", package / "Package.swift")
            for folder in ("Sources", "Tests"):
                shutil.copytree(root / folder, package / folder)
        subprocess.run([compiler, "test", "--package-path", str(package), "-j", "2",
                        "--filter", "RetentionPolicyTests"], cwd=package, check=True)


if __name__ == "__main__":
    main()
