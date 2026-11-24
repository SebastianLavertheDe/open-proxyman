"""Compile actual RequestCode.swift on Linux/macOS and parse generated snippets.

Platform-only capture/export dependencies are stubbed. cURL/HTTPie/HAR are excluded
because their generators live in the macOS ExportService. Native Node and Go
snippets additionally send binary data to an isolated loopback HTTP fixture.
"""

import argparse
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading

from test_request_code import check_snippet
from foundation_test_support import build_foundation_module
from runtime_adapter_test_support import RUNTIME_STUBS


ROOT = Path(__file__).resolve().parents[1]
STUBS = RUNTIME_STUBS + r'''
import Foundation
@_exported import ProxyMirrorFoundation
final class Transaction {
    var method = "POST"
    var host = "127.0.0.1"
    var path = "/a%2Fb"
    var url = "http://127.0.0.1:1/a%2Fb?tag=a&tag=b"
    var headers = [("X-Test", "one"), ("X-Test", "two"), ("X-Quote", "quoted \\\" $dollar"), ("Expect", "100-continue")]
    var requestBody = Data([0, 255, 128, 39, 10, 36, 92])
    var canReplay = true
}
enum ComposeService {
    typealias ParsedRequest = HTTPRequest
    static func request(from tx: Transaction) -> ParsedRequest {
        ParsedRequest(method: tx.method, url: tx.url, headers: tx.headers, body: tx.requestBody.isEmpty ? nil : tx.requestBody)
    }
}
enum ExportService {
    static func curlCommand(_ tx: Transaction, runtime: ProxyRuntimeContext) -> String { fatalError("Excluded platform generator") }
    static func httpieCommand(_ tx: Transaction, runtime: ProxyRuntimeContext) -> String { fatalError("Excluded platform generator") }
    static func buildHAR(_ tx: [Transaction], redactSensitiveHeaders: Bool? = nil) -> [String: Any] { fatalError("Excluded platform generator") }
}
'''
MAIN = r'''
import Foundation
@main struct RequestCodeFixture {
    static func main() throws {
        let binary = Transaction()
        binary.url = ProcessInfo.processInfo.environment["PM_CODE_FIXTURE_URL"]!
        let empty = Transaction(); empty.method = "GET"; empty.requestBody = Data(); empty.headers = []
        let formats = RequestCode.Format.allCases.filter { ![.curl, .httpie, .har].contains($0) }
        var fixtures: [String: [String: String]] = [:]
        for (name, tx) in [("binary", binary), ("empty", empty)] {
            fixtures[name] = Dictionary(uniqueKeysWithValues: formats.map { ($0.rawValue, RequestCode.generate(tx, format: $0)) })
        }
        let json = try JSONSerialization.data(withJSONObject: fixtures, options: [.sortedKeys])
        FileHandle.standardOutput.write(json)
    }
}
'''


class Origin(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        payload = json.dumps({"body": base64.b64encode(body).decode(), "host": self.headers.get("Host"),
                              "repeated": self.headers.get_all("X-Test"), "path": self.path}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def smoke(code, language, directory, origin):
    if language == "nodeHTTP" and (tool := shutil.which("node")):
        file = directory / "native-http.cjs"
        file.write_text(code, encoding="utf-8")
        command = [tool, str(file)]
    elif language == "go" and (tool := shutil.which("go")):
        file = directory / "native-http.go"
        file.write_text(code, encoding="utf-8")
        executable = directory / "native-http-go"
        subprocess.run([tool, "build", "-o", str(executable), str(file)], check=True, timeout=120)
        command = [str(executable)]
    else:
        print(f"SKIP  {language} local HTTP smoke (toolchain unavailable)")
        return
    result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=15)
    lines = result.stdout.splitlines()
    assert lines[0] == "200", result.stdout
    response = json.loads("\n".join(lines[1:]))
    assert response["body"] == base64.b64encode(bytes([0, 255, 128, 39, 10, 36, 92])).decode(), response
    assert response["host"] == f"127.0.0.1:{origin.server_port}", response
    assert response["repeated"] == ["one", "two"], response
    assert response["path"] == "/a%2Fb?tag=a&tag=b", response
    print(f"PASS  {language} real local HTTP: Host, binary bytes, repeated headers, escaped URL")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default="swiftc")
    args = parser.parse_args()
    compiler = shutil.which(args.swiftc) or args.swiftc
    os.environ["PATH"] = str(Path(compiler).resolve().parent) + os.pathsep + os.environ.get("PATH", "")
    with tempfile.TemporaryDirectory(prefix="pm-request-code-models-") as temporary:
        directory = Path(temporary)
        module_flags = build_foundation_module(compiler, directory)
        stubs = directory / "PlatformStubs.swift"; stubs.write_text(STUBS, encoding="utf-8")
        main_file = directory / "Run.swift"; main_file.write_text(MAIN, encoding="utf-8")
        executable = directory / "request-code-fixtures"
        subprocess.run([compiler, "-swift-version", "5", "-module-cache-path", str(directory / "module-cache"),
                        *module_flags, str(ROOT / "Sources/ProxyMirrorCore/Export/ProxyRuntimeContext.swift"),
                        str(ROOT / "Sources/ProxyMirrorCore/Export/RequestCode.swift"),
                        str(ROOT / "Sources/ProxyMirrorCore/Export/ExportRedaction.swift"),
                        str(stubs), str(main_file), "-o", str(executable)], check=True, timeout=120)
        origin = ThreadingHTTPServer(("127.0.0.1", 0), Origin)
        worker = threading.Thread(target=origin.serve_forever, daemon=True); worker.start()
        try:
            env = {**os.environ, "PM_CODE_FIXTURE_URL": f"http://127.0.0.1:{origin.server_port}/a%2Fb?tag=a&tag=b"}
            fixtures = json.loads(subprocess.check_output([str(executable)], env=env, timeout=10))
            for name, formats in fixtures.items():
                for language, code in formats.items():
                    checked = check_snippet(language, code, directory)
                    print(f"{'PASS' if checked else 'SKIP'}  {name}: {language} syntax")
            for language in ("nodeHTTP", "go"):
                smoke(fixtures["binary"][language], language, directory, origin)
        finally:
            origin.shutdown(); origin.server_close(); worker.join(timeout=5)


if __name__ == "__main__":
    main()
