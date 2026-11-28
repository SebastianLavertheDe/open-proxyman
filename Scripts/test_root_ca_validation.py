#!/usr/bin/env python3
"""Compile production root-CA validation with the project's locked X509/Crypto versions.

This checks the portable validation itself. Atomic CA replacement and macOS trust
remain covered by the native Core checks and require macOS.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", default="swift")
    parser.add_argument("--scratch-path")
    parser.add_argument("--local-dependencies", type=Path,
                        help="Directory containing the locked swift-certificates, swift-crypto and swift-asn1 checkouts")
    args = parser.parse_args()
    compiler = shutil.which(args.swift) or args.swift
    pins = {pin["identity"]: pin["state"]["version"] for pin in json.loads((ROOT / "Package.resolved").read_text())["pins"]}
    with tempfile.TemporaryDirectory(prefix="pm-root-ca-native-") as temporary:
        folder = Path(temporary)
        sources = folder / "Sources/RootCAValidationChecks"
        sources.mkdir(parents=True)
        for source in [ROOT / "Sources/ProxyMirrorCore/System/RootCAValidation.swift",
                       ROOT / "Tests/Fixtures/RootCAValidation/Checks.swift"]:
            shutil.copy2(source, sources / source.name)
        names = ["swift-certificates", "swift-crypto", "swift-asn1"]
        if args.local_dependencies:
            dependencies = ",\n".join(f'.package(path: {json.dumps(str((args.local_dependencies / name).resolve()))})'
                                        for name in names)
        else:
            dependencies = ",\n".join(f'.package(url: "https://github.com/apple/{name}.git", exact: "{pins[name]}")'
                                        for name in names)
        (folder / "Package.swift").write_text('''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "RootCAValidationChecks", dependencies: [
''' + dependencies + '''
], targets: [.executableTarget(name: "RootCAValidationChecks", dependencies: [
    .product(name: "X509", package: "swift-certificates"),
    .product(name: "Crypto", package: "swift-crypto"),
])])
''')
        command = [compiler, "run", "--package-path", str(folder), "-j", "2"]
        if args.scratch_path:
            command += ["--scratch-path", args.scratch_path]
        environment = dict(os.environ)
        if args.local_dependencies:
            environment["SWIFTCI_USE_LOCAL_DEPS"] = "1"
        subprocess.run(command, env=environment, check=True, timeout=900)


if __name__ == "__main__":
    main()
