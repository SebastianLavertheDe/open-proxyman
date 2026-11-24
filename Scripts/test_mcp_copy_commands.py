"""Compile the actual copy generators and verify redacted request framing.

Only macOS platform models are replaced. The production redactor/header policy
and cURL/HTTPie generator bodies are compiled unchanged. cURL sends real local
HTTP; HTTPie's generated shell pipeline is checked with an argv/stdin recorder.
"""
import argparse
import base64
import gzip
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
from foundation_test_support import build_foundation_module


STUBS = r'''
import Foundation
@_exported import ProxyMirrorFoundation
final class AppSettings {
    static let shared = AppSettings()
    var port: UInt16 = 9090
    var appendProxyToCommands = false
    var preserveOriginalHeaders = false
    var redactSensitiveHeaders = false
}
final class ProxyEngine {
    static let shared = ProxyEngine()
    var isRunning = false
    var port: UInt16 = 9090
}
final class Transaction {
    var isTunnel = false
    var host = "127.0.0.1"
    var port = 80
    var method = "POST"
    var fullURL = ProcessInfo.processInfo.environment["PM_COPY_URL"]!
    var requestBody = Data()
    var requestHeaders = HTTPHeaders()
}
enum ComposeService {
    typealias ParsedRequest = HTTPRequest
    static func request(from tx: Transaction) -> ParsedRequest {
        ParsedRequest(method: tx.method, url: tx.fullURL,
                      headers: tx.requestHeaders.pairs.map { ($0.name, $0.value) }, body: tx.requestBody)
    }
}
'''

MAIN = r'''
import Foundation
@main struct CopyFixture {
    static func main() throws {
        let compressed = Data(base64Encoded: ProcessInfo.processInfo.environment["PM_COPY_GZIP"]!)!
        let json = Data(#"{"password":"body-secret","ok":"visible"}"#.utf8)
        var output: [String: Any] = [:]
        for (name, body, redact, preserve) in [("normal-default", compressed, false, false),
                                               ("normal-preserved", compressed, false, true),
                                               ("mcp-json", json, true, true), ("mcp-gzip", compressed, true, true)] {
            let captured: [(String, String)] = [
                ("Host", "wrong-host.invalid"), (":authority", "wrong-authority.invalid"),
                ("Content-Length", String(body.count)), ("Accept-Encoding", "gzip"),
                ("Content-Encoding", name == "mcp-json" ? "identity" : "gzip"), ("Content-Type", "application/json"),
                ("Transfer-Encoding", "chunked"), ("Trailer", "X-Trailer"), ("Connection", "keep-alive, X-Connection-Only"),
                ("X-Connection-Only", "hop-secret"), ("Proxy-Connection", "keep-alive"),
                ("Proxy-Authorization", "Basic proxy-secret"), ("TE", "trailers"),
                ("Content-MD5", "outdated-digest"), ("Authorization", "Bearer header-secret")]
            let tx = Transaction()
            tx.requestBody = body
            tx.requestHeaders = HTTPHeaders(captured)
            if redact {
                let record: [String: Any] = ["requestBody": body.base64EncodedString(),
                    "requestHeaders": captured.map { ["name": $0.0, "value": $0.1] }]
                let data = try MCPDataRedaction.jsonData(JSONSerialization.data(withJSONObject: record))
                let safe = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                tx.requestBody = Data(base64Encoded: safe["requestBody"] as! String)!
                let headers = (safe["requestHeaders"] as! [[String: String]]).map { ($0["name"]!, $0["value"]!) }
                tx.requestHeaders = HTTPHeaders(MCPDataRedaction.replayHeaders(headers, body: tx.requestBody))
            }
            AppSettings.shared.preserveOriginalHeaders = preserve
            output[name] = ["curl": ExportService.curlCommand(tx), "httpie": ExportService.httpieCommand(tx),
                            "bodyBase64": tx.requestBody.base64EncodedString(),
                            "headers": tx.requestHeaders.pairs.map { ["name": $0.name, "value": $0.value] },
                            "originalLength": body.count]
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output))
    }
}
'''


class Origin(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        payload = json.dumps({"headers": dict(self.headers), "bodyBase64": base64.b64encode(body).decode()}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def verify(name, received, expected):
    headers = {key.lower(): value for key, value in received["headers"].items()}
    body = base64.b64decode(received["bodyBase64"])
    assert body == base64.b64decode(expected["bodyBase64"]), (name, body)
    assert int(headers["content-length"]) == len(body), (name, headers, len(body))
    for key in ["proxy-authorization", "proxy-connection", "transfer-encoding", "trailer", "te", "x-connection-only", ":authority"]:
        assert key not in headers, (name, key, headers)
    assert headers["host"] != "wrong-host.invalid", (name, headers)
    if name.startswith("mcp-"):
        assert "content-encoding" not in headers and "content-md5" not in headers, (name, headers)
        assert b"body-secret" not in body and "header-secret" not in json.dumps(headers), (name, body, headers)
    else:
        assert headers["content-encoding"] == "gzip", (name, headers)
        assert b"body-secret" in gzip.decompress(body), name


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default=shutil.which("swiftc"))
    args = parser.parse_args()
    if not args.swiftc or not shutil.which("curl"):
        parser.error("swiftc and curl are required")
    root = Path(__file__).resolve().parents[1]
    source = (root / "Sources/ProxyMirrorCore/Export/ExportService.swift").read_text()
    commands = "import Foundation\nenum ExportService {\n" + source[source.index("    /// 生成可复用的 cURL 命令"):source.index("\n}\n\n@MainActor")] + "\n}\n"
    with tempfile.TemporaryDirectory(prefix="pm-copy-framing-") as directory, ThreadingHTTPServer(("127.0.0.1", 0), Origin) as origin:
        target = Path(directory)
        module_flags = build_foundation_module(args.swiftc, target)
        worker = threading.Thread(target=origin.serve_forever, daemon=True)
        worker.start()
        try:
            for name, content in [("Models.swift", STUBS), ("Commands.swift", commands), ("Main.swift", MAIN)]:
                (target / name).write_text(content)
            executable = target / "copy-fixture"
            subprocess.run([args.swiftc, "-parse-as-library", *module_flags, str(root / "Sources/ProxyMirrorCore/Export/ExportRedaction.swift"),
                            *(str(target / name) for name in ["Models.swift", "Commands.swift", "Main.swift"]), "-o", str(executable)], check=True, timeout=120)
            env = dict(os.environ, PM_COPY_URL=f"http://127.0.0.1:{origin.server_port}/copy",
                       PM_COPY_GZIP=base64.b64encode(gzip.compress(b'{"password":"body-secret"}', mtime=0)).decode())
            fixtures = json.loads(subprocess.check_output([str(executable)], env=env, timeout=15))
            recorder = target / "http"
            recorder.write_text("#!/usr/bin/env python3\nimport base64,json,sys\nprint(json.dumps({'args':sys.argv[1:],'bodyBase64':base64.b64encode(sys.stdin.buffer.read()).decode()}))\n")
            recorder.chmod(0o755)
            for name, fixture in fixtures.items():
                curl = json.loads(subprocess.check_output(["/bin/sh", "-c", fixture["curl"]], env=env, stderr=subprocess.DEVNULL, timeout=10))
                verify(name, curl, fixture)
                command_env = dict(env, PATH=str(target) + os.pathsep + os.environ.get("PATH", ""))
                httpie = json.loads(subprocess.check_output(["/bin/sh", "-c", fixture["httpie"]], env=command_env, timeout=10))
                headers = dict(arg.split(": ", 1) for arg in httpie["args"][2:])
                headers.setdefault("Host", "127.0.0.1")
                headers.setdefault("Content-Length", str(len(base64.b64decode(httpie["bodyBase64"]))))
                verify(name, {"headers": headers, "bodyBase64": httpie["bodyBase64"]}, fixture)
                if name == "normal-default":
                    assert "Content-Length:" not in fixture["curl"] and "Accept-Encoding:" not in fixture["curl"]
                if name == "normal-preserved":
                    assert "Content-Length:" in fixture["curl"] and "Accept-Encoding: gzip" in fixture["curl"]
                print("PASS", name, "real cURL HTTP and generated HTTPie argv/stdin framing")
        finally:
            origin.shutdown()
            worker.join()


if __name__ == "__main__":
    main()
