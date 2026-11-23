#!/usr/bin/env python3
"""Compatibility entry point for the native resource and SwiftGen workflow."""
from pathlib import Path
import subprocess
import sys

if __name__ == "__main__":
    root = Path(__file__).resolve().parents[1]
    arguments = sys.argv[1:]
    if arguments == ["--check"]:
        raise SystemExit(subprocess.call([sys.executable, str(root / "Scripts/check_localization.py")], cwd=root))
    raise SystemExit(subprocess.call(["bash", str(root / "Scripts/generate_localization.sh"), *arguments], cwd=root))
