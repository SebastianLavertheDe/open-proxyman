"""Run production workbench/MCP/privacy code with isolated storage and a deterministic transport.

Only platform services are replaced. Request parsing, workbench validation,
job retention, JSON-RPC validation and the MCP redaction envelope are production
code. No network requests or user-default writes outside the test suite occur.
"""
from pathlib import Path
import argparse
import shutil
import subprocess
import tempfile

from foundation_test_support import build_foundation_module

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default="swiftc")
    args = parser.parse_args()
    compiler = shutil.which(args.swiftc) or args.swiftc
    with tempfile.TemporaryDirectory(prefix="pm-workbench-") as temporary:
        directory = Path(temporary)
        flags = build_foundation_module(compiler, directory)
        compose = (ROOT / "Sources/ProxyMirrorCore/Export/ComposeService.swift").read_text()
        parsing = compose[compose.index("    static func parse(_ text:"):compose.index("    static func parseCurl(")]
        start = compose.index("    static func rawText(from request:")
        raw = compose[start:compose.index("\n    }", start) + len("\n    }")]
        (directory / "ComposeParsing.swift").write_text("import Foundation\nimport ProxyMirrorFoundation\nextension ComposeService {\n" + parsing + raw + "\n}\n")
        control = (ROOT / "Sources/ProxyMirrorCore/DesktopApplication/AutomationControl.swift").read_text()
        envelope = control[control.index("    @MainActor\n    static func execute("):control.index("    @MainActor\n    private static func executeRequest(")]
        encoding = control[control.index("    static func json("):control.index("    private static func object<")]
        dispatch = """
    @MainActor
    private static func executeRequest(_ arguments: [String: Any], app: AppState, redactForMCP: Bool) throws -> Data {
        try AutomationWorkbench.execute(arguments, app: app, defaults: app.defaults)
    }
"""
        (directory / "AutomationEnvelope.swift").write_text("import Foundation\nenum AutomationControl {\n" + envelope + encoding + dispatch + "}\n")
        executable = directory / "workbench"
        sources = [
            ROOT / "Sources/ProxyMirrorCore/DesktopApplication/AutomationWorkbench.swift",
            ROOT / "Sources/ProxyMirrorCore/DesktopApplication/MCPProtocol.swift",
            ROOT / "Sources/ProxyMirrorCore/Export/ExportRedaction.swift",
            ROOT / "Tests/Fixtures/AutomationWorkbench/PlatformStubs.swift",
            ROOT / "Tests/Fixtures/AutomationWorkbench/Checks.swift",
            directory / "ComposeParsing.swift", directory / "AutomationEnvelope.swift",
        ]
        subprocess.run([compiler, "-swift-version", "5", "-parse-as-library", *flags,
                        *map(str, sources), "-o", str(executable)], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
