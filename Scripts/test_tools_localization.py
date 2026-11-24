#!/usr/bin/env python3
"""Run real tool identities, typed accessors, and native resource lookups in isolation."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SWIFT_SOURCES = [
    "Sources/ProxyMirrorCore/Localization/AppLanguage.swift",
    "Sources/ProxyMirrorCore/Localization/LocalizationResources.swift",
    "Sources/ProxyMirrorCore/Localization/LocalizationContext.swift",
    "Sources/ProxyMirrorCore/UI/PresentationLocalization.swift",
    "Sources/ProxyMirrorCore/System/LocalizedErrorPresentation.swift",
    "Sources/ProxyMirrorCore/System/GeneratedOperationIssues.swift",
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default=shutil.which("swiftc"))
    args = parser.parse_args()
    if not args.swiftc:
        raise SystemExit("swiftc is required; set --swiftc to an installed toolchain")
    generated = sorted((ROOT / "Sources/ProxyMirrorCore/Localization/Generated").glob("*.swift"))
    if not generated:
        raise SystemExit("Generate the checked-in localization accessors first")
    with tempfile.TemporaryDirectory(prefix="proxymirror-tools-localization-") as temporary:
        directory = Path(temporary)
        resources = directory / "Tools.bundle"
        shutil.copytree(ROOT / "Sources/ProxyMirrorCore/Resources", resources)
        if sys.platform != "darwin":
            # swift-corelibs Foundation does not implement Darwin's stringsdict behavior.
            # The macOS run keeps and verifies the actual plural resources.
            for path in resources.rglob("*.stringsdict"):
                path.unlink()
        tools = (ROOT / "Sources/ProxyMirrorCore/UI/Tools/ToolWindows.swift").read_text()
        tool_enum = tools[tools.index("enum ToolKind:"):tools.index("struct ComposeRequestView:")]
        help_source = (ROOT / "Sources/ProxyMirrorCore/UI/Tools/TroubleshootingMenu.swift").read_text()
        help_enum = help_source[help_source.index("enum HelpGuideTopic:"):help_source.index("@MainActor")]
        (directory / "ToolModels.swift").write_text("import Foundation\n" + tool_enum + help_enum)
        compose = (ROOT / "Sources/ProxyMirrorCore/Export/ComposeService.swift").read_text()
        (directory / "ComposeModels.swift").write_text(compose[:compose.index("    private static let historyKey")] + "\n}\n")
        # Type-check the actual UI call expressions against production models and
        # generated accessors; a syntax-only pass cannot detect these mismatches.
        transparent = (ROOT / "Sources/ProxyMirrorCore/System/TransparentProxyController.swift").read_text()
        state = transparent[transparent.index("    enum State:"):transparent.index("    @Published")]
        failure_line = next(line for line in transparent.splitlines() if "self.stopCapture(endingIn:" in line)
        failure = failure_line.split("endingIn: ", 1)[1].strip()[:-1]
        sse = (ROOT / "Sources/ProxyMirrorCore/UI/Detail/SseEventsView.swift").read_text()
        span_line = next(line.strip() for line in sse.splitlines() if "Strings.Detail.span1fs(" in line)
        span = span_line[len("Text("):-1]
        (directory / "PlatformCallChecks.swift").write_text(
            "import Foundation\n" + state + "\nfunc checkPlatformCallTypes() {\n"
            "let first = Date(timeIntervalSince1970: 0), last = Date(timeIntervalSince1970: 1.25)\n"
            f"_ = {span}\nlet state: State = {failure}\n"
            "guard case .failed(let message) = state, !message.isEmpty else { fatalError(\"Missing failure presentation\") }\n}\n")
        checks = (ROOT / "Tests/ProxyMirrorCoreChecks/ToolLocalizationChecks.swift").read_text()
        checks = checks.replace("@testable import ProxyMirrorCore", "")
        (directory / "ToolChecks.swift").write_text(checks)
        (directory / "Assertions.swift").write_text('''import Foundation
final class CoreAssertions {
    var passed = 0
    func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }; passed += 1
    }
    func equal<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        expect(actual == expected, "\\(message): expected \\(expected), got \\(actual)")
    }
}
''')
        (directory / "main.swift").write_text('''import Foundation
let test = CoreAssertions()
checkToolLocalization(test)
checkPlatformCallTypes()
print("PASS: \\(test.passed) real tool localization assertions")
#if !os(macOS)
print("Native stringsdict plural assertions require the macOS test lane.")
#endif
''')
        executable = directory / "tools-localization-test"
        sources = [str(ROOT / path) for path in SWIFT_SOURCES]
        sources += [str(path) for path in generated]
        sources += [str(directory / name) for name in ("ToolModels.swift", "ComposeModels.swift", "PlatformCallChecks.swift",
                                                     "ToolChecks.swift", "Assertions.swift", "main.swift")]
        subprocess.run([args.swiftc, "-swift-version", "5", *sources, "-o", str(executable)], check=True)
        environment = os.environ.copy()
        environment["PM_LOCALIZATION_RESOURCE_DIR"] = str(resources)
        for language in ("en", "zh-Hans"):
            environment["PM_SETTINGS_LANGUAGE"] = language
            subprocess.run([str(executable)], cwd=directory, env=environment, check=True)


if __name__ == "__main__":
    main()
