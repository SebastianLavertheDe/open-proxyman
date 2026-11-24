"""Run the production Compose curl transport and cURL generator on loopback.

Build the real ProxyMirrorFoundation module and ProxyMirrorTransportFixture
SwiftPM target, then exercise their production HTTP transport and cURL generator.
No source extraction, replacement engine, fake Transaction, or application stubs
are used. macOS UI/CA adapters and WebSocket composition remain native checks.
"""

import argparse
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[1]


class Origin(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    seen = []
    second_port = 0

    def log_message(self, *_args):
        pass

    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            # Cancellation and header-only redirects deliberately close peers.
            pass

    def handle_request(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        path = urlsplit(self.path).path
        self.seen.append({"method": self.command, "path": path, "body": body,
                          "authorization": self.headers.get("Authorization"), "cookie": self.headers.get("Cookie"),
                          "content_type": self.headers.get("Content-Type"), "x-test": self.headers.get("X-Test")})
        if path == "/continue":
            self.wfile.write(b"HTTP/1.1 103 Early Hints\r\nLink: </fixture.css>\r\n\r\nHTTP/1.1 100 Continue\r\n\r\n")
            self.wfile.flush()
        if path == "/malformed":
            self.wfile.write(b"HTTP/1.1 200 OK\r\nBroken-Header\r\n\r\n")
            self.wfile.flush()
            self.close_connection = True
            return
        if path in {"/trailers", "/redirect-trailers", "/large-trailers", "/slow-trailers"}:
            self.send_response(303 if path == "/redirect-trailers" else 200)
            if path == "/redirect-trailers":
                self.send_header("Location", "/trailers")
            self.send_header("Content-Type", "application/json")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Trailer", "X-Final, X-Multi")
            self.end_headers()
            if self.command == "HEAD":
                return
            entity = b"intermediate" if path == "/redirect-trailers" else b'{"ok":true}'
            try:
                self.wfile.write(f"{len(entity):x}\r\n".encode() + entity + b"\r\n0\r\n")
                self.wfile.flush()
                if path == "/slow-trailers":
                    time.sleep(2)
                self.wfile.write((b"X-Large: " + b"x" * 1000 + b"\r\n") * 70 if path == "/large-trailers" else b"X-Final: check")
                self.wfile.flush()
                time.sleep(0.01)
                self.wfile.write((b"" if path == "/large-trailers" else b"sum") + b"\r\nX-Multi: one\r\nX-Multi: two\r\n\r\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if path.startswith("/redirect/"):
            status = int(path.rsplit("/", 1)[1])
            location = "/final"
        elif path in {"/loop", "/cross", "/invalid", "/hanging-redirect"}:
            status = 303 if path == "/hanging-redirect" else 302
            location = {"/loop": "/loop", "/cross": f"http://127.0.0.1:{self.second_port}/final",
                        "/invalid": "file:///unused-fixture", "/hanging-redirect": "/final"}[path]
        elif path in {"/slow-redirect", "/slow-final"}:
            time.sleep(0.65)
            status, location = (307, "/slow-final") if path.endswith("redirect") else (200, None)
        elif path == "/cancel":
            time.sleep(2)
            status, location = 200, None
        else:
            status, location = 200, None
        payload = json.dumps({"method": self.command, "body": base64.b64encode(body).decode(),
                              "content_type": self.headers.get("Content-Type"),
                              "authorization": self.headers.get("Authorization"), "cookie": self.headers.get("Cookie"),
                              "x-test": self.headers.get("X-Test")}).encode()
        self.send_response(status)
        if location:
            self.send_header("Location", location)
        self.send_header("Content-Type", "application/json")
        self.send_header("X-Seen-Method", self.command)
        self.send_header("X-Fixture-Path", path)
        self.send_header("Content-Length", str(len(payload) if path != "/hanging-redirect" else 2**30))
        self.end_headers()
        if path == "/hanging-redirect":
            time.sleep(2)
            self.close_connection = True
            return
        if self.command != "HEAD":
            try:
                self.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError):
                pass

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_QUERY = handle_request


def compile_fixture(compiler, directory):
    if sys.platform == "darwin":
        # The macOS graph also declares Core, native services and local BridgeKit.
        # Build the real fixture product from that complete graph; only artifacts
        # go into the temporary scratch directory.
        package = ROOT
    else:
        # A portable graph snapshot prevents Linux SwiftPM from rewriting the
        # checkout's macOS dependency lockfile.
        package = directory / "package"
        package.mkdir()
        shutil.copy2(ROOT / "Package.swift", package / "Package.swift")
        for relative in ["Sources/ProxyMirrorFoundation", "Sources/ProxyMirrorProcessSupport", "Tests/ProxyMirrorFoundationTests", "Tests/Fixtures/ComposeTransport"]:
            shutil.copytree(ROOT / relative, package / relative)
    swift = str(Path(shutil.which(compiler) or compiler).resolve().with_name("swift"))
    common = [swift, "build", "--package-path", str(package), "--scratch-path", str(directory / "build")]
    subprocess.run([*common, "--product", "ProxyMirrorTransportFixture", "-j", "2"], cwd=package, check=True, timeout=180)
    binary_directory = subprocess.check_output([*common, "--show-bin-path"], cwd=package, text=True, timeout=30).strip()
    return Path(binary_directory) / "ProxyMirrorTransportFixture"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default=os.environ.get("PM_SWIFTC") or shutil.which("swiftc"))
    args = parser.parse_args()
    if not args.swiftc:
        parser.error("swiftc is required")
    origin = ThreadingHTTPServer(("127.0.0.1", 0), Origin)
    second = ThreadingHTTPServer(("127.0.0.1", 0), Origin)
    Origin.second_port = second.server_port
    for server in [origin, second]:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{origin.server_port}"
    checks = 0
    try:
        with tempfile.TemporaryDirectory(prefix="pm-compose-transport-") as temporary:
            work = Path(temporary)
            binary = compile_fixture(args.swiftc, work)

            def send(method, path, data=b"\x00\xffredirect-body", timeout=5, follow=True, cancel=False, limit=None, reserve=None):
                Origin.seen.clear()
                command = [str(binary), "send", method, url + path, base64.b64encode(data).decode(), str(timeout), str(follow).lower()]
                if cancel:
                    command.append("cancel")
                if limit is not None:
                    command.append(f"limit={limit}")
                if reserve is not None:
                    command.append(f"reserve={reserve}")
                result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=15)
                return json.loads(result.stdout)

            for status in [301, 302, 303, 307, 308]:
                for method in ["POST", "PUT", "PATCH", "DELETE", "GET", "HEAD", "QUERY"]:
                    data = b"\x00\xffredirect-body" if method != "HEAD" else b""
                    result = send(method, f"/redirect/{status}", data=data)
                    expected = "GET" if status == 303 and method != "HEAD" or status in [301, 302] and method == "POST" else method
                    expected_body = b"" if expected == "GET" and expected != method or status == 303 or method == "HEAD" else data
                    assert result["state"] == "completed" and result["status"] == 200, (status, method, result)
                    assert len(Origin.seen) == 2 and Origin.seen[1]["method"] == expected, Origin.seen
                    assert Origin.seen[1]["body"] == expected_body, Origin.seen
                    assert result["headers"]["x-seen-method"] == expected, result
                    assert result["headers"]["x-fixture-path"] == "/final", result
                    if expected == "HEAD":
                        assert base64.b64decode(result["body"]) == b"" and result["bytes"] == 0, result
                    else:
                        body = json.loads(base64.b64decode(result["body"]))
                        assert body["method"] == expected and base64.b64decode(body["body"]) == expected_body, result
                        assert result["bytes"] == int(result["headers"]["content-length"]), result
                    if expected != method or status == 303 and method != "HEAD":
                        assert Origin.seen[1]["content_type"] is None, Origin.seen
                    checks += 1
            print("PASS 35 production Compose redirect method/body combinations (301/302/303/307/308)")
            result = send("POST", "/continue")
            assert result["status"] == 200 and result["state"] == "completed", result
            assert json.loads(base64.b64decode(result["body"]))["method"] == "POST", result
            checks += 1
            result = send("POST", "/redirect/303", follow=False)
            assert result["status"] == 303 and len(Origin.seen) == 1, result
            checks += 1
            result = send("POST", "/cross")
            assert result["status"] == 200 and Origin.seen[-1]["authorization"] is None and Origin.seen[-1]["cookie"] is None, (result, Origin.seen)
            assert Origin.seen[-1]["x-test"] == "retained", Origin.seen
            checks += 1
            result = send("GET", "/loop", data=b"")
            assert result["state"] == "failed" and "Too many redirects" in result["error"] and len(Origin.seen) == 11, (result, len(Origin.seen))
            checks += 1
            result = send("GET", "/invalid", data=b"")
            assert result["state"] == "failed" and "Invalid HTTP redirect" in result["error"] and len(Origin.seen) == 1, result
            checks += 1
            start = time.monotonic()
            result = send("POST", "/hanging-redirect", timeout=0)
            assert result["status"] == 200 and time.monotonic() - start < 1.5, result
            checks += 1
            start = time.monotonic()
            result = send("PUT", "/slow-redirect", timeout=1)
            assert result["state"] == "failed" and time.monotonic() - start < 1.8, result
            checks += 1
            result = send("GET", "/cancel", data=b"", cancel=True)
            assert result["state"] == "failed" and "cancel" in result["error"].lower(), result
            checks += 1
            start = time.monotonic()
            result = send("GET", "/malformed", data=b"")
            assert result["state"] == "failed" and time.monotonic() - start < 1.5, result
            checks += 1
            expected_trailers = [{"name": "x-final", "value": "checksum"},
                                 {"name": "x-multi", "value": "one"}, {"name": "x-multi", "value": "two"}]
            for path, follow, entity in [("/trailers", True, b'{"ok":true}'),
                                         ("/redirect-trailers", True, b'{"ok":true}'),
                                         ("/redirect-trailers", False, b"intermediate")]:
                result = send("GET", path, data=b"", follow=follow)
                assert result["state"] == "completed" and base64.b64decode(result["body"]) == entity, result
                assert result["bytes"] == len(entity) and result["trailers"] == expected_trailers, result
                checks += 1
            for limit, reserve, retained in [(0, None, b""), (4, None, b'{"ok'), (20, 2, b'{"')]:
                result = send("GET", "/trailers", data=b"", limit=limit, reserve=reserve)
                assert result["state"] == "completed" and base64.b64decode(result["body"]) == retained, result
                assert result["bytes"] == 11 and result["trailers"] == expected_trailers, result
                checks += 1
            result = send("HEAD", "/trailers", data=b"")
            assert result["state"] == "completed" and result["bytes"] == 0 and result["body"] == "" and result["trailers"] == [], result
            checks += 1
            result = send("GET", "/large-trailers", data=b"")
            assert result["state"] == "failed" and "Response headers exceed" in result["error"], result
            assert base64.b64decode(result["body"]) == b'{"ok":true}' and result["bytes"] == 11, result
            checks += 1
            for cancel, timeout in [(True, 5), (False, 1)]:
                start = time.monotonic()
                result = send("GET", "/slow-trailers", data=b"", cancel=cancel, timeout=timeout)
                assert result["state"] == "failed" and time.monotonic() - start < 1.8, result
                assert base64.b64decode(result["body"]) == b'{"ok":true}' and result["bytes"] == 11, result
                checks += 1
            for method, payload in [("HEAD", b""), ("HEAD", b"must-not-send"), ("POST", b""), ("GET", b"")]:
                data = base64.b64encode(payload).decode()
                code = subprocess.check_output([str(binary), "curl", method, url + "/final", data], text=True, timeout=10)
                result = subprocess.run(["/bin/sh", "-c", code], check=True, capture_output=True, text=True, timeout=5)
                if method == "HEAD":
                    assert "--head" in code and "-X HEAD" not in code and "--data" not in code and "HTTP/1.1 200" in result.stdout, (code, result.stdout)
                    assert "Content-Length:" not in code, code
                    if payload:
                        assert "captured request body is omitted" in code, code
                checks += 1
            print(f"PASS {checks} actual HTTP transport/cURL checks: redirects, credentials, 100 Continue, deadlines, cancellation, HEAD, separate duplicate trailers and capture budgets")
    finally:
        for server in [origin, second]:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
