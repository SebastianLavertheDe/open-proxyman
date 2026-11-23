#!/usr/bin/env python3
"""Compile and exercise the actual ScriptNetworkBridge.swift against local HTTP fixtures.

This validates Foundation/URLSession native I/O on macOS or Linux. It does not
claim to validate JavaScriptCore or the full macOS app; use --worker separately
for the actual packaged worker protocol and CPU/network deadline checks.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]


class Fixture(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def serve(self):
        target = urlsplit(self.path)
        query = parse_qs(target.query)
        if target.path == "/slow":
            time.sleep(int(query.get("ms", ["700"])[0]) / 1000)
        if target.path in ["/redirect", "/redirect-loop"]:
            body = b"redirect"
            self.send_response(302)
            self.send_header("Location", query["url"][0] if target.path == "/redirect" else "/redirect-loop")
        else:
            self.send_response(200)
            if target.path == "/size":
                body = b"x" * int(query.get("n", ["65536"])[0])
            elif target.path == "/binary":
                body = bytes([0, 1, 128, 255])
            else:
                length = int(self.headers.get("Content-Length", "0"))
                request_body = self.rfile.read(length)
                body = json.dumps({"method": self.command, "headers": dict(self.headers),
                                   "body": request_body.decode("utf8", "replace"), "path": self.path}).encode()
        self.send_header("Content-Type", "application/json")
        self.send_header("X-Bridge-Fixture", "native-urlsession")
        self.send_header("Set-Cookie", "session=must-not-be-reused")
        if target.path != "/size-chunked":
            self.send_header("Content-Length", str(len(body)))
        else:
            body = b"x" * 65536
            self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            if target.path == "/size-chunked":
                self.wfile.write(f"{len(body):x}\r\n".encode() + body + b"\r\n0\r\n\r\n")
            else:
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    do_GET = do_POST = do_QUERY = serve


def request(identifier, url, **options):
    return {"request": {"id": identifier, "url": url, **options}}


def run_bridge(binary, commands, blocked_port):
    environment = dict(os.environ, PM_TEST_BLOCKED_PORT=str(blocked_port),
                       http_proxy="http://127.0.0.1:1", https_proxy="http://127.0.0.1:1", no_proxy="")
    result = subprocess.run([str(binary)], input="".join(json.dumps(value) + "\n" for value in commands),
                            text=True, capture_output=True, timeout=8, env=environment)
    assert result.returncode == 0, result.stderr
    return {value["id"]: value for value in map(json.loads, result.stdout.splitlines())}


def response_text(value):
    return base64.b64decode(value["bodyBase64"]).decode("utf8", "replace")


def bridge_checks(binary, address, blocked_port):
    result = run_bridge(binary, [request("get", address + "/echo", headers=[["X-Custom", "native"]]),
                                request("post", address + "/echo", method="POST", body="hello π", headers=[["Content-Type", "text/plain"]])], blocked_port)
    body = json.loads(response_text(result["get"]))
    assert result["get"]["status"] == 200 and body["method"] == "GET"
    assert body["headers"]["X-Custom"] == "native"
    assert json.loads(response_text(result["post"]))["body"] == "hello π"
    assert any(name.lower() == "x-bridge-fixture" for name, _ in result["get"]["headers"])
    assert "Cookie" not in json.loads(response_text(result["post"]))["headers"]
    result = run_bridge(binary, [request("binary", address + "/binary"), request("query", address + "/echo", method="QUERY", body="query-body")], blocked_port)
    assert base64.b64decode(result["binary"]["bodyBase64"]) == bytes([0, 1, 128, 255])
    assert json.loads(response_text(result["query"]))["method"] == "QUERY"
    result = run_bridge(binary, [request("timeout", address + "/slow", timeoutMs=100), request("abort", address + "/slow"), {"cancel": "abort", "delayMs": 100}], blocked_port)
    assert result["timeout"]["name"] == "TimeoutError", result
    assert result["abort"]["name"] == "AbortError", result
    result = run_bridge(binary, [request("large", address + "/size"), request("chunked", address + "/size-chunked")], blocked_port)
    assert "超过" in result["large"]["error"] and "超过" in result["chunked"]["error"]
    redirect = address + "/redirect?url=" + address + "/echo"
    result = run_bridge(binary, [request("follow", redirect), request("manual", redirect, redirect="manual"), request("error", redirect, redirect="error")], blocked_port)
    assert result["follow"]["status"] == 200 and result["manual"]["status"] == 302
    assert "重定向" in result["error"]["error"]
    result = run_bridge(binary, [request("blocked", f"http://127.0.0.1:{blocked_port}/"), request("framing", address, headers=[["Content-Length", "99"]]), request("getbody", address, body="invalid"), request("scheme", "file:///tmp/secret"), request("port", "http://127.0.0.1:70000/")], blocked_port)
    assert "自身监听端口" in result["blocked"]["error"]
    aliases = run_bridge(binary, [request("numeric-host", f"http://2130706433:{blocked_port}/"),
                                 request("short-host", f"http://127.1:{blocked_port}/")], blocked_port)
    assert all("自身监听端口" in item["error"] for item in aliases.values())
    assert "手动设置" in result["framing"]["error"]
    assert "GET/HEAD" in result["getbody"]["error"]
    assert "HTTP/HTTPS" in result["scheme"]["error"]
    assert "端口" in result["port"]["error"]
    result = run_bridge(binary, [request("loop", address + "/redirect-loop")], blocked_port)
    assert "超过 5 次" in result["loop"]["error"]
    commands = []
    for index in range(9):
        commands.extend([request("quota-" + str(index), address + "/echo"), {"sleepMs": 100}])
    result = run_bridge(binary, commands, blocked_port)
    assert all(result["quota-" + str(index)].get("status") == 200 for index in range(8))
    assert "最多 8 次" in result["quota-8"]["error"]
    cross_host = address.replace("127.0.0.1", "localhost") + "/echo"
    result = run_bridge(binary, [request("credentials", address + "/redirect?url=" + cross_host,
                                        headers=[["Authorization", "Bearer local-test"], ["Cookie", "secret=local"]])], blocked_port)
    headers = {key.lower(): value for key, value in json.loads(response_text(result["credentials"]))["headers"].items()}
    assert "authorization" not in headers and "cookie" not in headers
    concurrent = [request(str(index), address + "/slow") for index in range(5)]
    result = run_bridge(binary, concurrent, blocked_port)
    assert sum("4 个并发" in value.get("error", "") for value in result.values()) == 1
    print("PASS: native Swift URLSession bridge: 23 assertions (GET/POST/QUERY, headers, binary, timeout, abort, declared/chunked bounds, redirect modes/loop/credential stripping, recursion/framing/scheme/port guards, request quota/concurrency, no cookie jar or inherited proxy)")


def worker_checks(worker, address):
    def run(source, **options):
        payload = {"source": source, "message": {"phase": "request", "method": "GET", "url": address, "headers": [], "body": "original"},
                   "environment": {}, "sharedState": {}, "networkEnabled": True,
                   "network": {"wallTimeMs": 2000, "requestTimeoutMs": 1000, "responseLimit": 32768, "blockedProxyPort": 9090}, **options}
        result = subprocess.run([str(worker)], input=json.dumps(payload), text=True, capture_output=True, timeout=4)
        assert result.stdout, (result.returncode, result.stderr)
        return json.loads(result.stdout)
    source = "async function onRequest(message){const r=await fetch(" + json.dumps(address + "/echo") + ",{headers:{'X-Worker':'jsc'}});message.body=JSON.stringify(await r.json());return message;}"
    value = run(source)
    assert json.loads(value["message"]["body"])["headers"]["X-Worker"] == "jsc", value
    started = time.monotonic()
    delayed = run("async function onRequest(message){const r=await fetch(" + json.dumps(address + "/slow?ms=700") + ");message.body=(await r.json()).method;return message;}")
    assert delayed["message"]["body"] == "GET" and time.monotonic() - started >= 0.6, delayed
    value = run("async function onRequest(message){const r=await require('axios').post(" + json.dumps(address + "/echo") + ",{native:true});message.body=r.data.body;return message;}")
    assert json.loads(value["message"]["body"])["native"] is True
    value = run("async function onRequest(message){const c=new AbortController();const pending=fetch(" + json.dumps(address + "/slow") + ",{signal:c.signal});c.abort();await pending;return message;}")
    assert "已取消" in value["error"] and "sharedState" not in value
    value = run("sharedState.failed=1; while(true){}")
    assert "400 ms" in value["error"] and "sharedState" not in value
    value = run("async function onRequest(message){await fetch(" + json.dumps(address + "/slow") + ",{timeoutMs:100});return message;}")
    assert "超时" in value["error"] and "sharedState" not in value
    print("PASS: actual macOS JavaScriptCore worker network, axios, abort, timeout, CPU deadline and failure-state protocol")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", help="Absolute path to swiftc; compiles native network bridge harness")
    parser.add_argument("--worker", type=Path, help="Actual ProxyMirrorScriptWorker binary for macOS JSC integration")
    args = parser.parse_args()
    if not args.swift and not args.worker:
        parser.error("pass --swift and/or --worker")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    blocked = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    for fixture in (server, blocked):
        threading.Thread(target=fixture.serve_forever, daemon=True).start()
    address = f"http://127.0.0.1:{server.server_port}"
    try:
        with tempfile.TemporaryDirectory(prefix="pm-script-network-") as directory:
            if args.swift:
                binary = Path(directory) / "NetworkBridgeHarness"
                subprocess.run([args.swift, "-swift-version", "5", str(ROOT / "Sources/ProxyMirrorScriptWorker/ScriptNetworkBridge.swift"),
                                str(ROOT / "Tests/Fixtures/ScriptNetworkBridgeHarness.swift"), "-o", str(binary)], check=True, timeout=120)
                bridge_checks(binary, address, blocked.server_port)
            if args.worker:
                worker_checks(args.worker.resolve(), address)
    finally:
        server.shutdown(); blocked.shutdown()


if __name__ == "__main__":
    main()
