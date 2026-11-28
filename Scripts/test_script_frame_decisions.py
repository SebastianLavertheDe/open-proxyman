#!/usr/bin/env python3
"""Compile the exact production Swift frame decoder/action method without AppKit/NIO.

Only the enclosing ScriptingService namespace is supplied by this harness. The
decoder, action enum and decision method are copied verbatim from production.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default="swiftc")
    args = parser.parse_args()
    source = (ROOT / "Sources/ProxyMirrorCore/Interception/ScriptingService.swift").read_text()
    start = source.index("    static func interpretFrameValue(")
    method = source[start:source.index("\n    }\n", start) + len("\n    }")]
    start = source.index("enum FrameValue:")
    decoder = source[start:source.index("\nextension ScriptWorker {", start)]
    frames = (ROOT / "Sources/ProxyMirrorCore/Proxy/WSInterception.swift").read_text()
    start = frames.index("enum WSFrameAction:")
    action = frames[start:frames.index("\n}\n", start) + len("\n}")]
    with tempfile.TemporaryDirectory(prefix="pm-frame-native-") as temporary:
        folder = Path(temporary)
        production = folder / "Production.swift"
        production.write_text("import Foundation\n" + decoder + "\n" + action
                              + "\nenum ScriptingService {\n" + method + "\n}\n")
        executable = folder / "checks"
        subprocess.run([shutil.which(args.swiftc) or args.swiftc, "-swift-version", "5", "-parse-as-library",
                        str(production), str(ROOT / "Tests/Fixtures/ScriptFrameDecisions/main.swift"),
                        "-o", str(executable)], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=20)


if __name__ == "__main__":
    main()
