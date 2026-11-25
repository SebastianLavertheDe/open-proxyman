#!/usr/bin/env python3
"""Compile production TLS capture with locked dependencies and verify a TLS handshake.

Runs on Linux or macOS without changing the app's Package.resolved. This validates
NIOSSL/X509 accessors and a real in-memory, certificate-verified handshake; the
desktop Summary view and live proxy integration still require macOS acceptance.
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
                        help="Directory containing the locked NIO/NIOSSL/X509/Crypto checkouts and their sibling dependencies")
    args = parser.parse_args()
    pins = {pin["identity"]: pin["state"]["version"]
            for pin in json.loads((ROOT / "Package.resolved").read_text())["pins"]}
    names = ["swift-certificates", "swift-crypto", "swift-nio", "swift-nio-ssl"]
    with tempfile.TemporaryDirectory(prefix="pm-tls-metadata-") as temporary:
        folder = Path(temporary)
        sources = folder / "Sources/MetadataChecks"
        sources.mkdir(parents=True)
        for source in [ROOT / "Sources/ProxyMirrorFoundation/HTTP/ProxyConnectionDetails.swift",
                       ROOT / "Sources/ProxyMirrorCore/Proxy/TLSConnectionMetadata.swift",
                       ROOT / "Sources/ProxyMirrorCore/System/PublicCertificateData.swift",
                       ROOT / "Tests/Fixtures/TLSMetadata/Checks.swift"]:
            shutil.copy2(source, sources / source.name)
        if args.local_dependencies:
            dependencies = ",\n".join(
                f'.package(path: {json.dumps(str((args.local_dependencies / name).absolute()))})'
                for name in names)
        else:
            dependencies = ",\n".join(
                f'.package(url: "https://github.com/apple/{name}.git", exact: "{pins[name]}")'
                for name in names)
        (folder / "Package.swift").write_text('''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "MetadataChecks", dependencies: [
''' + dependencies + '''
], targets: [.executableTarget(name: "MetadataChecks", dependencies: [
    .product(name: "X509", package: "swift-certificates"),
    .product(name: "Crypto", package: "swift-crypto"),
    .product(name: "NIOCore", package: "swift-nio"),
    .product(name: "NIOEmbedded", package: "swift-nio"),
    .product(name: "NIOSSL", package: "swift-nio-ssl"),
])])
''', encoding="utf-8")
        command = [shutil.which(args.swift) or args.swift, "run", "--package-path", str(folder), "-j", "2"]
        if args.scratch_path:
            command += ["--scratch-path", args.scratch_path]
        environment = dict(os.environ)
        if args.local_dependencies:
            environment["SWIFTCI_USE_LOCAL_DEPS"] = "1"
        subprocess.run(command, env=environment, check=True, timeout=900)


if __name__ == "__main__":
    main()
