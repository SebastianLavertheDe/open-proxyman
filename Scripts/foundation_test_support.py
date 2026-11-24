"""Build the real Foundation module for platform-adapter fixtures.

Primary policy tests use the repository's SwiftPM test target. These helpers let
older bilingual/macOS-adapter fixtures import that same production module rather
than copying individual Foundation declarations into their replacement models.
"""
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def build_foundation_module(compiler, directory):
    directory = Path(directory)
    production = ROOT / "Sources/ProxyMirrorFoundation"
    snapshot = directory / "FoundationSources"
    # Compile the whole real module from a stable fixture snapshot. This avoids
    # Swift rejecting an input that another concurrent development task rewrites.
    shutil.copytree(production, snapshot)
    sources = sorted(snapshot.rglob("*.swift"))
    library = directory / ("libProxyMirrorFoundation.dylib" if sys.platform == "darwin" else "libProxyMirrorFoundation.so")
    subprocess.run([str(compiler), "-swift-version", "5", "-package-name", "ProxyMirror", "-parse-as-library",
                    "-emit-module", "-emit-library", "-module-name", "ProxyMirrorFoundation",
                    "-emit-module-path", str(directory / "ProxyMirrorFoundation.swiftmodule"),
                    *map(str, sources), "-o", str(library)], check=True, timeout=180)
    return ["-package-name", "ProxyMirror", "-I", str(directory), "-L", str(directory),
            "-lProxyMirrorFoundation", "-Xlinker", "-rpath", "-Xlinker", str(directory)]
