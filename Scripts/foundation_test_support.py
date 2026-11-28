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


def build_foundation_module(compiler, directory, *, c_include_directories=()):
    directory = Path(directory)
    production = ROOT / "Sources/ProxyMirrorFoundation"
    snapshot = directory / "FoundationSources"
    # Compile the whole real module from a stable fixture snapshot. This avoids
    # Swift rejecting an input that another concurrent development task rewrites.
    shutil.copytree(production, snapshot)
    sources = sorted(snapshot.rglob("*.swift"))
    support = directory / "ProcessSupport"
    shutil.copytree(ROOT / "Sources/ProxyMirrorProcessSupport", support)
    includes = [support / "include", *map(Path, c_include_directories)]
    clang = Path(compiler).resolve().parent / "clang"
    if not clang.is_file():
        clang = shutil.which("clang")
    if not clang:
        raise RuntimeError("clang is required to compile the production process support module")
    sdk_flags = []
    if sys.platform == "darwin":
        sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True, timeout=30).strip()
        sdk_flags = ["-isysroot", sdk]
    support_object = directory / "ProcessSupport.o"
    subprocess.run([str(clang), "-fPIC", *sdk_flags, *[flag for path in includes for flag in ("-I", str(path))],
                    "-c", str(support / "ProcessSupport.c"), "-o", str(support_object)], check=True, timeout=60)
    # Only the C implementation needs an optional historical libc header. Its
    # public module intentionally exposes no libc records to Swift's importer.
    module_flags = ["-I", str(support / "include")]
    library = directory / ("libProxyMirrorFoundation.dylib" if sys.platform == "darwin" else "libProxyMirrorFoundation.so")
    subprocess.run([str(compiler), "-swift-version", "5", "-package-name", "ProxyMirror", "-parse-as-library",
                    "-emit-module", "-emit-library", "-module-name", "ProxyMirrorFoundation",
                    "-emit-module-path", str(directory / "ProxyMirrorFoundation.swiftmodule"),
                    *module_flags, *map(str, sources), str(support_object), "-o", str(library)], check=True, timeout=180)
    return ["-package-name", "ProxyMirror", "-I", str(directory), "-L", str(directory),
            *module_flags, "-lProxyMirrorFoundation", "-Xlinker", "-rpath", "-Xlinker", str(directory)]
