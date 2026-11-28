#!/usr/bin/env python3
"""Compile and execute the production HTTP parser/framing/deadline policies.

Pass --nio-package /path/to/swift-nio to also run the real NIO connect guard,
including DNS/Happy Eyeballs, using a small independent Swift package.
"""
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
    parser.add_argument("--nio-package", type=Path)
    args = parser.parse_args()
    compiler = shutil.which(args.swiftc) or args.swiftc
    with tempfile.TemporaryDirectory(prefix="pm-http-safety-") as temporary:
        directory = Path(temporary)
        binary = directory / "http-safety"
        module_flags = build_foundation_module(compiler, directory)
        subprocess.run([compiler, "-swift-version", "5", "-parse-as-library", *module_flags,
                        str(ROOT / "Tests/Fixtures/HTTPProtocolSafety/main.swift"), "-o", str(binary)], check=True, timeout=120)
        subprocess.run([str(binary)], check=True, timeout=15)
        if args.nio_package:
            import json
            (directory / "Sources/ConnectChecks").mkdir(parents=True)
            for source in [ROOT / "Sources/ProxyMirrorCore/Proxy/ProxySelfConnectionGuard.swift",
                           ROOT / "Tests/Fixtures/SelfConnectionGuard/main.swift"]:
                name = "Entry.swift" if source.name == "main.swift" else source.name
                (directory / "Sources/ConnectChecks" / name).symlink_to(source)
            manifest = '// swift-tools-version: 5.10\nimport PackageDescription\n'
            manifest += ('let package = Package(name: "ConnectChecks", dependencies: [.package(name: "swift-nio", path: %s)], '
                         'targets: [.executableTarget(name: "ConnectChecks", dependencies: '
                         '[.product(name: "NIOCore", package: "swift-nio"), '
                         '.product(name: "NIOEmbedded", package: "swift-nio"), '
                         '.product(name: "NIOPosix", package: "swift-nio")])], '
                         'swiftLanguageVersions: [.v5])\n') % json.dumps(str(args.nio_package.resolve()))
            (directory / "Package.swift").write_text(manifest)
            swift = str(Path(compiler).resolve().with_name("swift"))
            subprocess.run([swift, "run", "-j", "2", "--package-path", str(directory), "ConnectChecks"], check=True, timeout=600)


if __name__ == "__main__":
    main()
