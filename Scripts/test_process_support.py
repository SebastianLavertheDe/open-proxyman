#!/usr/bin/env python3
"""Compile the real process C shim and run both production Swift process runners.

--spawn-header additionally tests against a supplied glibc 2.35 spawn.h, keeping
GNU-only declarations unavailable to Swift while the C implementation sees them.
The Foundation module and C module are built unchanged in a temporary directory.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from foundation_test_support import build_foundation_module

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default=shutil.which("swiftc"))
    parser.add_argument("--spawn-header", type=Path)
    args = parser.parse_args()
    if not args.swiftc:
        parser.error("swiftc is required")
    if args.spawn_header and sys.platform != "linux":
        parser.error("--spawn-header requires Linux")
    with tempfile.TemporaryDirectory(prefix="pm-process-support-") as temporary:
        directory = Path(temporary)
        includes = []
        if args.spawn_header:
            header_directory = directory / "JammyHeaders"
            header_directory.mkdir()
            shutil.copy2(args.spawn_header, header_directory / "spawn.h")
            includes.append(header_directory)
            module_directory = directory / "JammyImport"
            module_directory.mkdir()
            (module_directory / "module.modulemap").write_text('module JammySpawn [system] { header "../JammyHeaders/spawn.h" export * }\n')
            probe = directory / "GNUDeclaration.swift"
            probe.write_text("import JammySpawn\nlet function = posix_spawn_file_actions_addclosefrom_np\n")
            hidden = subprocess.run([args.swiftc, "-typecheck", "-I", str(module_directory), str(probe)],
                                    cwd=directory, capture_output=True, text=True, timeout=60)
            if hidden.returncode == 0 or "cannot find 'posix_spawn_file_actions_addclosefrom_np'" not in hidden.stderr:
                raise RuntimeError("The supplied header does not reproduce the Jammy Swift declaration boundary: " + hidden.stderr)
            print("Jammy header: GNU extension is unavailable to the default Swift importer", flush=True)
        module_flags = build_foundation_module(args.swiftc, directory, c_include_directories=includes)
        executable = directory / "process-support-checks"
        subprocess.run([args.swiftc, "-swift-version", "5", *module_flags,
                        str(ROOT / "Tests/Fixtures/ProcessSupport/main.swift"), "-o", str(executable)],
                       cwd=directory, check=True, timeout=120)
        subprocess.run([str(executable)], cwd=directory, check=True, timeout=30)


if __name__ == "__main__":
    main()
