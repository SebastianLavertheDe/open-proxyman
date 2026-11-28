"""Test the packaged App's local CLI, proxy traffic, and persistence on macOS."""

import argparse
from contextlib import contextmanager
import hashlib
import http.client
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from http.server import ThreadingHTTPServer

from test_loopback import Handler, executable


LOOPBACK = "127.0.0.1"
LARGE_CHUNK = bytes(range(256)) * 256
LARGE_CHUNK_COUNT = 32


class CLIOrigin(Handler):
    def do_GET(self):
        gate = self.server.response_gates.get(self.path)
        if gate is None:
            self.serve_sample()
            return
        try:
            self.connection.settimeout(8)
            self.send_response(200)
            self.send_header("Content-Length", str(len(LARGE_CHUNK) * LARGE_CHUNK_COUNT))
            self.end_headers()
            self.wfile.write(LARGE_CHUNK)
            if gate.wait(8):
                for _ in range(LARGE_CHUNK_COUNT - 1):
                    self.wfile.write(LARGE_CHUNK)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass
        finally:
            self.close_connection = True


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def passed(message):
    print(f"PASS  {message}", flush=True)


def prepare_bundle(source, destination, identifier):
    shutil.copytree(source, destination)
    info = destination / "Contents/Info.plist"
    with info.open("rb") as file:
        metadata = plistlib.load(file)
    metadata.update(CFBundleIdentifier=identifier, LSUIElement=True)
    with info.open("wb") as file:
        plistlib.dump(metadata, file)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", destination],
                   check=True, capture_output=True, text=True, timeout=15)
    return executable(destination / "Contents/MacOS" / metadata["CFBundleExecutable"], "test App")


def write_preferences(identifier, port):
    for key, kind, value in (
        ("storage.localizationVersion", "-int", "2"),
        ("proxy.port", "-int", str(port)),
        ("proxy.autoStart", "-bool", "true"),
        ("proxy.autoTakeOverSystemProxy", "-bool", "false"),
        ("proxy.lanEnabled", "-bool", "false"),
        ("ui.followLatest", "-bool", "true"),
    ):
        subprocess.run(["/usr/bin/defaults", "write", identifier, key, kind, value], check=True, timeout=5)


def command(binary, env, *args, exit_code=0):
    result = subprocess.run([binary, *args], env=env, capture_output=True, text=True, timeout=8)
    require(result.returncode == exit_code,
            f"{args!r}: expected exit {exit_code}, got {result.returncode}. {result.stderr.strip()}")
    if exit_code:
        require(not result.stdout and result.stderr.startswith("ProxyMirror: "),
                f"{args!r}: expected a diagnostic only on stderr")
    else:
        require(not result.stderr, f"{args!r}: unexpected stderr {result.stderr!r}")
    return result.stdout


@contextmanager
def running_app(binary, env, log_path):
    with log_path.open("ab") as log, subprocess.Popen([binary], env=env, stdout=log, stderr=log) as app:
        try:
            yield app
        finally:
            if app.poll() is None:
                app.terminate()
                try:
                    app.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    app.kill()


def wait_for_app(binary, env, app, proxy_port):
    deadline = time.monotonic() + 15
    while app.poll() is None and time.monotonic() < deadline:
        result = subprocess.run([binary, "status"], env=env, capture_output=True, text=True, timeout=5)
        if result.returncode == 0:
            status = json.loads(result.stdout)
            require(not result.stderr, "status wrote an unexpected diagnostic")
            require(status["appRunning"] and status["listening"] and status["recording"],
                    f"test App did not start recording: {status!r}")
            require(status["listenAddress"] == f"{LOOPBACK}:{proxy_port}" and not status["systemProxyActive"],
                    f"test App did not start the isolated loopback listener: {status!r}")
            return status
        require(result.returncode == 3, f"unexpected startup status: {result.stderr.strip()}")
        time.sleep(0.05)
    raise AssertionError(f"test App did not become ready (process status {app.poll()})")


def proxy_request(proxy_port, url, method="GET", body=None):
    connection = http.client.HTTPConnection(LOOPBACK, proxy_port, timeout=5)
    try:
        connection.request(method, url, body, {"Connection": "close", "Content-Type": "text/plain"})
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()


def captured_row(binary, env, path, *filters, state="completed"):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        rows = json.loads(command(binary, env, "traffic", "--url", path, *filters))
        if len(rows) == 1 and rows[0]["state"] == state:
            return rows[0]
        time.sleep(0.05)
    raise AssertionError(f"did not capture a {state} transaction for {path}")


def check_traffic_and_har(binary, env, directory, proxy_port, origin_url):
    missing = "/missing/cli?tag=one&tag=two"
    post_body = "测试 body"
    status, response = proxy_request(proxy_port, origin_url + missing, "POST", post_body.encode())
    require(status == 404 and json.loads(response)["body"] == post_body, "POST body did not reach the origin")
    row = captured_row(binary, env, missing, "--method", "post", "--status", "404")
    require(row["url"] == origin_url + missing and row["requestBytes"] == len(post_body.encode()),
            f"filtered traffic row did not match POST: {row!r}")
    require(proxy_request(proxy_port, origin_url + "/cli/latest")[0] == 200, "latest capture did not reach the origin")
    latest = captured_row(binary, env, "/cli/latest")
    recent = json.loads(command(binary, env, "traffic", "--limit", "1"))
    require(len(recent) == 1 and recent[0]["id"] == latest["id"], "--limit 1 did not return the latest capture")
    require(json.loads(command(binary, env, "traffic", "--status", "503")) == [], "traffic status filter leaked a row")
    passed("traffic filters, byte counts, and latest limit")

    stdout = json.loads(command(binary, env, "export-har", "--id", row["id"], "--output", "-"))
    entries = stdout["log"]["entries"]
    require(len(entries) == 1, "HAR must export only the matching transaction")
    request, reply = entries[0]["request"], entries[0]["response"]
    require(request["url"] == row["url"] and request["postData"]["text"] == post_body,
            "HAR did not preserve the captured POST body")
    require(request["queryString"] == [{"name": "tag", "value": "one"}, {"name": "tag", "value": "two"}],
            "HAR did not preserve repeated query parameters")
    cookies = [header["value"] for header in reply["headers"] if header["name"].lower() == "set-cookie"]
    require(reply["status"] == 404 and cookies == ["sample=a", "sample=b"]
            and reply["content"]["text"].encode() == response, "HAR did not preserve status, duplicate headers, and body")
    output = directory / "captured.har"
    require(not command(binary, env, "export-har", "--id", row["id"], "--output", str(output)),
            "file export unexpectedly wrote to stdout")
    require(json.loads(output.read_text(encoding="utf-8")) == stdout and stat.S_IMODE(output.stat().st_mode) == 0o600,
            "HAR file data or private permissions did not match")
    command(binary, env, "export-har", "--url", "not-a-fixture-path", "--output", "-", exit_code=5)
    command(binary, env, "export-har", "--id", row["id"], "--output", str(directory / "missing" / "file.har"),
            exit_code=4)
    passed("HAR stdout, private file, and failure codes")


def check_rules(binary, env, directory, proxy_port, origin_url):
    url = origin_url + "/cli/blocked"
    rule = {"id": "824B2A98-D046-4DFB-B7EB-10E32C1C1721", "enabled": True, "pattern": url,
            "target": "", "comment": "CLI integration fixture"}
    original = directory / "rule.json"
    changed = directory / "changed.json"
    original.write_text(json.dumps({"version": 2, "blockList": [rule]}), encoding="utf-8")
    changed.write_text(json.dumps({"version": 2, "blockList": [{**rule, "pattern": url + "/changed"}]}),
                       encoding="utf-8")
    preview = json.loads(command(binary, env, "rules", "preview", "--input", str(original), "--mode", "merge"))
    changes = {change["section"]: change for change in preview["changes"]}
    require(not preview["applied"] and changes["blockList"]["added"] == 1 and len(preview["previewToken"]) == 64,
            f"rules preview did not describe the pending change: {preview!r}")
    token = preview["previewToken"]
    command(binary, env, "rules", "apply", "--input", str(changed), "--mode", "merge", "--preview-token", token,
            exit_code=6)
    exported = json.loads(command(binary, env, "rules", "export", "--output", "-", "--tool", "blockList"))
    require(exported["blockList"] == [] and proxy_request(proxy_port, url)[0] == 200,
            "a preview or stale token changed live rules")
    applied = json.loads(command(binary, env, "rules", "apply", "--input", str(original), "--mode", "merge",
                                 "--preview-token", token))
    require(applied["applied"] and not applied.get("previewToken") and proxy_request(proxy_port, url)[0] == 403,
            "rules apply did not change live routing")
    passed("rules preview, stale token rejection, and valid apply")
    return url


@contextmanager
def gated_response(origin, proxy_port, origin_url, path):
    with socket.socket() as slow:
        slow.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 * 1024)
        slow.settimeout(8)
        slow.connect((LOOPBACK, proxy_port))
        slow.sendall(f"GET {origin_url}{path} HTTP/1.1\r\nHost: {LOOPBACK}:{origin.server_port}\r\n"
                     "Connection: close\r\n\r\n".encode("ascii"))
        with http.client.HTTPResponse(slow) as response:
            response.begin()
            require(response.status == 200, f"gated transfer did not start: {path}")
            yield response


def check_cancelled_client(binary, env, origin, proxy_port, origin_url):
    path = "/cli/cancel"
    try:
        with gated_response(origin, proxy_port, origin_url, path) as response:
            require(response.read(1) == LARGE_CHUNK[:1], "response did not reach the client before cancellation")
        row = captured_row(binary, env, path, state="failed")
        har = json.loads(command(binary, env, "export-har", "--id", row["id"], "--output", "-"))
        error = har["log"]["entries"][0]["response"]["_error"]
        failure = har["log"]["entries"][0]["response"].get("_proxyMirrorFailure", {})
        require(0 < row["responseBytes"] < len(LARGE_CHUNK) * LARGE_CHUNK_COUNT,
                f"cancellation did not leave a partially captured response: {row!r}")
        require(failure.get("code") in {"network_client_closed", "network_client_write_failed", "network_connection_error"},
                f"cancelled client was not recorded with a client failure identity: {failure!r}, diagnostic: {error!r}")
    finally:
        origin.response_gates[path].set()
    passed("client cancellation closes an incomplete response and records a client error")


def check_slow_client(origin, proxy_port, origin_url):
    path = "/cli/slow"
    with gated_response(origin, proxy_port, origin_url, path) as response:
        try:
            status, data = proxy_request(proxy_port, origin_url + "/cli/sibling")
            require(status == 200 and json.loads(data)["path"] == "/cli/sibling",
                    "sibling request could not complete while slow client was in flight")
        finally:
            origin.response_gates[path].set()
        digest = hashlib.sha256()
        total = 0
        for chunk in iter(lambda: response.read(16 * 1024), b""):
            digest.update(chunk)
            total += len(chunk)
        expected = LARGE_CHUNK * LARGE_CHUNK_COUNT
        require(total == len(expected) and digest.digest() == hashlib.sha256(expected).digest(),
                f"slow-client response bytes did not match the source ({total} of {len(expected)} bytes)")
    passed("slow client resumes with exact bytes while sibling completes")


def run_suite(app_bundle, directory, identifier, log_path):
    binary = prepare_bundle(app_bundle, directory / "ProxyMirror CLI Test.app", identifier)
    support = directory / "support"
    env = {key: value for key, value in os.environ.items() if not key.startswith("PM_SNAPSHOT")}
    env["PM_SUPPORT_DIR"] = str(support)
    command(binary, env, "status", "--bogus", exit_code=2)
    command(binary, env, "status", exit_code=3)
    passed("usage and App offline exit codes")

    with ThreadingHTTPServer((LOOPBACK, 0), CLIOrigin) as origin, socket.socket() as reservation:
        origin.response_gates = {path: threading.Event() for path in ("/cli/slow", "/cli/cancel")}
        thread = threading.Thread(target=origin.serve_forever, daemon=True)
        thread.start()
        try:
            origin_url = f"http://{LOOPBACK}:{origin.server_port}"
            reservation.bind((LOOPBACK, 0))
            proxy_port = reservation.getsockname()[1]
            write_preferences(identifier, proxy_port)
            reservation.close()
            with running_app(binary, env, log_path) as app:
                status = wait_for_app(binary, env, app, proxy_port)
                require(not status["systemProxyActive"], "opted-out launch took over the system proxy")
                require(status["liveCount"] == 0 and status["selectedCount"] == 0, "test App did not start empty")
                require(stat.S_IMODE((support / ".control").stat().st_mode) == 0o700,
                        "local control directory is not private")
                command(binary, env, "traffic", "--selected", exit_code=5)
                passed("live status, isolated socket, and empty selection")
                check_traffic_and_har(binary, env, directory, proxy_port, origin_url)
                blocked = check_rules(binary, env, directory, proxy_port, origin_url)
            command(binary, env, "status", exit_code=3)
            with running_app(binary, env, log_path) as app:
                wait_for_app(binary, env, app, proxy_port)
                require(proxy_request(proxy_port, blocked)[0] == 403, "applied rule was lost after restart")
                passed("local control reconnect and rule persistence on restart")
                check_cancelled_client(binary, env, origin, proxy_port, origin_url)
                check_slow_client(origin, proxy_port, origin_url)
        finally:
            for gate in origin.response_gates.values():
                gate.set()
            origin.shutdown()
            thread.join()


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=root / "build_app/ProxyMirror.app")
    args = parser.parse_args()
    app = args.app.resolve()
    if not (app / "Contents/Info.plist").is_file():
        parser.error(f"App bundle not found: {app}")
    # A short absolute path keeps the UNIX socket within sockaddr_un.sun_path.
    with tempfile.TemporaryDirectory(dir="/tmp", prefix="pm-cli-") as tmp:
        directory = Path(tmp)
        identifier = "test.proxymirror.cli." + uuid.uuid4().hex
        log_path = directory / "app.log"
        try:
            run_suite(app, directory, identifier, log_path)
        except (AssertionError, KeyError, ValueError, OSError, http.client.HTTPException, subprocess.SubprocessError) as error:
            print(f"FAIL  CLI integration: {error}", file=sys.stderr)
            if isinstance(error, subprocess.CalledProcessError) and error.stderr:
                print(error.stderr.rstrip(), file=sys.stderr)
            if log_path.is_file():
                print("\n".join(log_path.read_text(encoding="utf-8", errors="replace").splitlines()[-40:]),
                      file=sys.stderr)
            return 1
        finally:
            subprocess.run(["/usr/bin/defaults", "delete", identifier], capture_output=True, timeout=5)
            (Path.home() / "Library/Preferences" / f"{identifier}.plist").unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
