#!/usr/bin/env python3
"""Compile real Foundation localization code and run isolated bundle fixtures."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    "Sources/ProxyMirrorCore/Localization/AppLanguage.swift",
    "Sources/ProxyMirrorCore/Localization/LocalizationResources.swift",
    "Sources/ProxyMirrorCore/Localization/LocalizationContext.swift",
    "Sources/ProxyMirrorCore/UI/PresentationLocalization.swift",
    "Sources/ProxyMirrorCore/Localization/Generated/Strings.swift",
    "Sources/ProxyMirrorCore/Localization/Generated/EnglishFallbacks.swift",
    "Tests/ProxyMirrorCoreChecks/LocalizationChecks.swift",
]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default=shutil.which("swiftc"))
    args = parser.parse_args()
    if not args.swiftc:
        raise SystemExit("swiftc is required; set --swiftc to an installed toolchain")
    with tempfile.TemporaryDirectory(prefix="proxymirror-localization-runtime-") as temporary:
        directory = Path(temporary)
        (directory / "Assertions.swift").write_text("""
import Foundation
final class CoreAssertions {
    var passed = 0
    func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
        passed += 1
    }
}
""")
        (directory / "main.swift").write_text("""
import Foundation
let test = CoreAssertions()
try checkLocalization(test)
let expectedLanguage = CommandLine.arguments[1]
guard L10n.effectiveLanguage == expectedLanguage else { fatalError("explicit process language") }
let expectedCancel = expectedLanguage == "en" ? "Cancel" : "取消"
guard Strings.Common.cancel == expectedCancel else { fatalError("typed real-resource lookup") }
setenv("PM_SETTINGS_LANGUAGE", expectedLanguage == "en" ? "zh-Hans" : "en", 1)
guard L10n.effectiveLanguage == expectedLanguage else { fatalError("running language must stay frozen") }
guard Strings.Common.cancel == expectedCancel else { fatalError("existing windows keep the running language") }
print("PASS: \\(test.passed + 4) real Foundation localization assertions in \\(expectedLanguage)")
#if !os(macOS)
print("Native stringsdict plural behavior requires the macOS test lane.")
#endif
""")
        executable = directory / "localization-test"
        subprocess.run([args.swiftc, "-swift-version", "5", *[str(ROOT / path) for path in SOURCES],
                        str(directory / "Assertions.swift"), str(directory / "main.swift"), "-o", str(executable)], check=True)
        for language in ("en", "zh-Hans"):
            environment = dict(os.environ, PM_SETTINGS_LANGUAGE=language,
                               PM_LOCALIZATION_RESOURCE_DIR=str(ROOT / "Sources/ProxyMirrorCore/Resources"))
            subprocess.run([str(executable), language], cwd=directory, env=environment, check=True)

if __name__ == "__main__":
    main()
