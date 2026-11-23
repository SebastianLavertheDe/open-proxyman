"""Exercise packaged ProxyMirror MCP HTTP/stdio, CLI CRUD and incremental export on macOS.

Uses a copied bundle, fresh preferences and PM_SUPPORT_DIR. Never talks to an
already-running personal instance or enables the system proxy.
"""
import argparse
import http.client
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import uuid
from http.server import ThreadingHTTPServer
from urllib.parse import urlsplit

from test_cli import (
    CLIOrigin, LOOPBACK, captured_row, command, passed, prepare_bundle,
    proxy_request, require, running_app, wait_for_app, write_preferences,
)


def rpc(endpoint, token, message, *, authorization=True, origin=None, method="POST", host=None):
    parsed = urlsplit(endpoint)
    conn = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=8)
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
               "MCP-Protocol-Version": "2025-06-18"}
    if authorization:
        headers["Authorization"] = token
    if origin is not None:
        headers["Origin"] = origin
    if host is not None:
        headers["Host"] = host
    try:
        conn.request(method, parsed.path, body=json.dumps(message).encode(), headers=headers)
        response = conn.getresponse()
        raw = response.read()
        return response.status, json.loads(raw) if raw else None
    finally:
        conn.close()


def call(endpoint, token, name, arguments=None, *, is_error=False):
    status, response = rpc(endpoint, token, {"jsonrpc": "2.0", "id": 7,
        "method": "tools/call", "params": {"name": name, "arguments": arguments or {}}})
    require(status == 200 and response.get("id") == 7, f"tool HTTP/RPC response invalid: {status}, {response!r}")
    result = response["result"]
    require(result["isError"] is is_error, f"{name}: unexpected result {result!r}")
    text = result["content"][0]["text"]
    try:
        return json.loads(text)
    except ValueError:
        return text


def run_suite(source, directory, identifier, log_path):
    binary = prepare_bundle(source, directory / "ProxyMirror MCP Test.app", identifier)
    support = directory / "support"
    env = {key: value for key, value in os.environ.items() if not key.startswith("PM_SNAPSHOT")}
    env["PM_SUPPORT_DIR"] = str(support)
    with ThreadingHTTPServer((LOOPBACK, 0), CLIOrigin) as origin, socket.socket() as reservation:
        origin.response_gates = {}
        thread = threading.Thread(target=origin.serve_forever, daemon=True)
        thread.start()
        reservation.bind((LOOPBACK, 0))
        proxy_port = reservation.getsockname()[1]
        write_preferences(identifier, proxy_port)
        reservation.close()
        try:
            with running_app(binary, env, log_path) as app:
                wait_for_app(binary, env, app, proxy_port)
                config = json.loads(command(binary, env, "mcp", "config"))
                endpoint, token = config["url"], config["headers"]["Authorization"]
                descriptor = support / ".control/mcp.json"
                require(stat.S_IMODE(descriptor.stat().st_mode) == 0o600, "MCP token file permissions are not private")
                request = {"jsonrpc": "2.0", "id": "init", "method": "initialize", "params": {
                    "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}}
                status, response = rpc(endpoint, token, request)
                require(status == 200 and response["id"] == "init" and response["result"]["protocolVersion"] == "2025-06-18",
                        f"initialize failed: {status}, {response!r}")
                require(rpc(endpoint, token, {"jsonrpc": "2.0", "method": "notifications/initialized"}) == (202, None),
                        "initialized notification must return 202 without a JSON body")
                require(rpc(endpoint, token, request, authorization=False)[0] == 401, "unauthenticated MCP call was accepted")
                require(rpc(endpoint, token, request, origin="https://evil.example")[0] == 403, "remote Origin was accepted")
                require(rpc(endpoint, token, request, host="evil.example")[0] == 403, "remote Host was accepted")
                require(rpc(endpoint, token, {}, method="GET")[0] == 405, "GET should advertise no server SSE stream")
                status, response = rpc(endpoint, token, {"jsonrpc": "2.0", "id": 2, "method": "does/not/exist"})
                require(status == 200 and response["id"] == 2 and response["error"]["code"] == -32601, "unknown method lost error/id")
                status, response = rpc(endpoint, token, {"jsonrpc": "2.0", "id": 3, "method": "tools/list"})
                names = {item["name"] for item in response["result"]["tools"]}
                require({"query_flows", "get_flow", "rules", "folders", "copy_as_code", "tools"} <= names, "MCP tools missing")
                call(endpoint, token, "query_flows", {"limit": 0}, is_error=True)
                call(endpoint, token, "query_flows", {"unexpected": "key"}, is_error=True)
                passed("MCP initialize, tool discovery, notification/error semantics, authentication and Origin/Host checks")

                origin_url = f"http://{LOOPBACK}:{origin.server_port}"
                require(proxy_request(proxy_port, origin_url + "/mcp/one")[0] == 200, "initial capture failed")
                first = captured_row(binary, env, "/mcp/one")
                require(proxy_request(proxy_port, origin_url + "/mcp/two")[0] == 200, "incremental capture failed")
                second = captured_row(binary, env, "/mcp/two")
                flows = call(endpoint, token, "query_flows", {"afterId": first["id"]})
                require([row["id"] for row in flows] == [second["id"]], "MCP afterId did not follow capture sequence")
                require(proxy_request(proxy_port, origin_url + "/mcp/three")[0] == 200, "third capture failed")
                third = captured_row(binary, env, "/mcp/three")
                page = call(endpoint, token, "query_flows", {"afterId": first["id"], "limit": 1})
                require([row["id"] for row in page] == [second["id"]], "incremental burst skipped the earliest unseen flow")
                next_page = json.loads(command(binary, env, "traffic", "--after-id", second["id"], "--limit", "1"))
                require([row["id"] for row in next_page] == [third["id"]], "CLI incremental cursor skipped a flow")
                detail = call(endpoint, token, "get_flow", {"id": second["id"]})
                require(detail["id"] == second["id"] and detail["statusCode"] == 200, "flow detail mismatch")
                code = call(endpoint, token, "copy_as_code", {"id": second["id"], "language": "swift"})
                require("URLSession" in code["code"], "Swift code generation not connected")
                exported = json.loads(command(binary, env, "export", "flows", "--format", "har", "--after-id", first["id"], "--limit", "1"))
                require(len(exported["log"]["entries"]) == 1, "CLI incremental HAR contains wrong flows")
                session = json.loads(command(binary, env, "export", "logs", "--format", "session"))
                require(session["version"] == 1 and isinstance(session["records"][0]["startedAt"], (int, float)), "native session date encoding is incompatible")
                passed("MCP full details/code generation and CLI incremental HAR/native session export")

                created = call(endpoint, token, "rules", {"tool": "blockList", "action": "add", "rule": {"pattern": origin_url + "/mcp/blocked"}})
                rule_id = created["rule"]["id"]
                require(proxy_request(proxy_port, origin_url + "/mcp/blocked")[0] == 403, "MCP-created block rule did not affect engine")
                call(endpoint, token, "tools", {"action": "disable", "tool": "blockList"})
                require(proxy_request(proxy_port, origin_url + "/mcp/blocked")[0] == 200, "global disable was not applied")
                call(endpoint, token, "tools", {"action": "enable", "tool": "blockList"})
                folder = call(endpoint, token, "folders", {"tool": "blockList", "action": "create", "name": "MCP rules"})
                call(endpoint, token, "folders", {"tool": "blockList", "action": "assign", "folderId": folder["id"], "ruleId": rule_id})
                rows = json.loads(command(binary, env, "rules", "blockList", "list", "--folder-id", folder["id"]))
                require(len(rows) == 1 and rows[0]["id"] == rule_id, "folder assignment not shared with CLI")
                call(endpoint, token, "folders", {"tool": "blockList", "action": "disable", "id": folder["id"]})
                require(proxy_request(proxy_port, origin_url + "/mcp/blocked")[0] == 200, "folder disable not applied")
                command(binary, env, "rules", "blockList", "delete", "--id", rule_id)
                require(call(endpoint, token, "rules", {"tool": "blockList", "action": "list"}) == [], "deleted rule still present")
                passed("MCP rule CRUD, global/folder switches, and CLI shared rule state")

                messages = [request, {"jsonrpc": "2.0", "method": "notifications/initialized"},
                            {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "proxy_address", "arguments": {}}}]
                process = subprocess.run([binary, "mcp", "stdio"], env=env,
                    input="".join(json.dumps(message) + "\n" for message in messages), text=True,
                    capture_output=True, timeout=10, check=True)
                replies = [json.loads(line) for line in process.stdout.splitlines()]
                require(len(replies) == 2 and replies[0]["id"] == "init" and replies[1]["id"] == 4 and not process.stderr,
                        f"stdio bridge emitted invalid framing/diagnostics: {process!r}")
                passed("stdio MCP bridge emits one JSON line per request and no notification response")
        finally:
            origin.shutdown()
            thread.join()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path(__file__).resolve().parents[1] / "build_app/ProxyMirror.app")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("macOS is required to launch and validate the packaged App")
    if not (args.app / "Contents/Info.plist").is_file():
        parser.error(f"App bundle not found: {args.app}")
    with tempfile.TemporaryDirectory(dir="/tmp", prefix="pm-mcp-") as temp:
        directory = Path(temp)
        identifier = "test.proxymirror.mcp." + uuid.uuid4().hex
        log_path = directory / "app.log"
        try:
            run_suite(args.app.resolve(), directory, identifier, log_path)
        except (AssertionError, KeyError, ValueError, OSError, http.client.HTTPException, subprocess.SubprocessError) as error:
            print(f"FAIL MCP integration: {error}", file=sys.stderr)
            if log_path.is_file():
                print("\n".join(log_path.read_text(encoding="utf-8", errors="replace").splitlines()[-40:]), file=sys.stderr)
            return 1
        finally:
            subprocess.run(["/usr/bin/defaults", "delete", identifier], capture_output=True, timeout=5)
            (Path.home() / "Library/Preferences" / f"{identifier}.plist").unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
