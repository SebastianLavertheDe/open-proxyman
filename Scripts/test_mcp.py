"""Exercise packaged ProxyMirror MCP HTTP/stdio, CLI CRUD and incremental export on macOS.

Uses a copied bundle, fresh preferences and PM_SUPPORT_DIR. Never talks to an
already-running personal instance or enables the system proxy.
"""
import argparse
import base64
from datetime import datetime, timedelta, timezone
import http.client
import json
import os
from pathlib import Path
import socket
import socketserver
import select
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
    conn = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=15)
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


class RecordingUpstream(socketserver.BaseRequestHandler):
    """HTTP CONNECT upstream which records tunnels and relays to the test origin."""
    def handle(self):
        self.request.settimeout(5)
        header = bytearray()
        while b"\r\n\r\n" not in header:
            chunk = self.request.recv(4096)
            if not chunk:
                return
            header.extend(chunk)
            require(len(header) <= 32768, "upstream CONNECT header too large")
        head, tail = bytes(header).split(b"\r\n\r\n", 1)
        require(head.startswith(b"CONNECT "), f"upstream expected CONNECT, got {head!r}")
        self.server.tunnels.append(head.split(b"\r\n", 1)[0].decode())
        with socket.create_connection((LOOPBACK, self.server.origin_port), timeout=5) as origin:
            self.request.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            if tail:
                origin.sendall(tail)
            peers = [self.request, origin]
            while True:
                ready, _, _ = select.select(peers, [], [], 5)
                if not ready:
                    return
                for peer in ready:
                    chunk = peer.recv(65536)
                    if not chunk:
                        return
                    (origin if peer is self.request else self.request).sendall(chunk)


def check_inclusive_proxy(binary, env, endpoint, token, proxy_port, origin_port, directory):
    dns = call(endpoint, token, "rules", {"tool": "dns", "action": "add", "rule": {
        "enabled": True, "hostPattern": "*.routing.pm.test", "ip": LOOPBACK}})["rule"]["id"]
    with socketserver.ThreadingTCPServer((LOOPBACK, 0), RecordingUpstream) as upstream:
        upstream.daemon_threads = True
        upstream.origin_port = origin_port
        upstream.tunnels = []
        worker = threading.Thread(target=upstream.serve_forever, daemon=True)
        worker.start()
        base = f"http://api.routing.pm.test:{origin_port}"
        try:
            configuration = {"enabled": True, "mode": "HTTP", "host": LOOPBACK, "port": upstream.server_address[1],
                "routingMode": "inclusive", "includedTargets": [base + "/selected/*"], "bypassHosts": []}
            path = directory / "inclusive-proxy.json"
            path.write_text(json.dumps(configuration), encoding="utf-8")
            echoed = json.loads(command(binary, env, "external-proxy", "set", "--input", str(path)))
            require(echoed["routingMode"] == "inclusive" and echoed["includedTargets"] == configuration["includedTargets"],
                    "inclusive configuration did not round-trip through CLI")
            require(proxy_request(proxy_port, base + "/selected/item")[0] == 200, "inclusive selected path failed")
            require(len(upstream.tunnels) == 1, "selected inclusive path did not reach the upstream")
            require(proxy_request(proxy_port, base + "/not-selected/item")[0] == 200, "inclusive direct path failed")
            require(len(upstream.tunnels) == 1, "same-host unmatched path incorrectly used upstream")
            require(proxy_request(proxy_port, f"http://outside.routing.pm.test:{origin_port}/selected/item")[0] == 200,
                    "unlisted host direct request failed")
            require(len(upstream.tunnels) == 1, "unlisted URL host incorrectly used upstream")
            echoed = call(endpoint, token, "external_proxy", {"action": "set", "config": {
                "includedTargets": ["*.routing.pm.test"]}})
            require(echoed["includedTargets"] == ["*.routing.pm.test"], "MCP inclusive target round-trip failed")
            require(proxy_request(proxy_port, base + "/host-glob")[0] == 200 and len(upstream.tunnels) == 2,
                    "inclusive host wildcard was not used")
            call(endpoint, token, "external_proxy", {"action": "set", "config": {
                "routingMode": "bypass", "bypassHosts": ["api.routing.pm.test"]}})
            require(proxy_request(proxy_port, base + "/bypass")[0] == 200 and len(upstream.tunnels) == 2,
                    "bypass route did not remain direct")
            call(endpoint, token, "external_proxy", {"action": "set", "config": {"routingMode": "all"}})
            require(proxy_request(proxy_port, base + "/all")[0] == 200 and len(upstream.tunnels) == 3,
                    "all mode incorrectly applied the old bypass list")
            require(proxy_request(proxy_port, f"http://{LOOPBACK}:{origin_port}/localhost-direct")[0] == 200
                    and len(upstream.tunnels) == 3, "localhost exception was lost in all mode")
            call(endpoint, token, "external_proxy", {"action": "set", "config": {
                "routingMode": "inclusive", "includedTargets": []}}, is_error=True)
            passed("inclusive CLI/MCP round-trip, matched/unmatched URL routing, host glob, all/bypass and localhost exception")
        finally:
            call(endpoint, token, "external_proxy", {"action": "disable"})
            call(endpoint, token, "rules", {"tool": "dns", "action": "delete", "id": dns})
            upstream.shutdown()
            worker.join()


def rule_identity(tool, row):
    return row["bundleID"].lower() if tool == "sslApplications" else row["id"]


def owned_ids(value):
    result = set()
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "id":
                try:
                    result.add(str(uuid.UUID(child)).upper())
                except (ValueError, TypeError, AttributeError):
                    pass
            else:
                result.update(owned_ids(child))
    elif isinstance(value, list):
        for child in value:
            result.update(owned_ids(child))
    return result


def check_rule_verbs(binary, env, endpoint, token, origin_port):
    with socket.socket() as reservation:
        reservation.bind((LOOPBACK, 0))
        reverse_port = reservation.getsockname()[1]
    fixtures = {
        "mapLocal": {"pattern": "https://label.pm.test/*", "target": ""},
        "mapRemote": {"pattern": "https://label.pm.test/*", "target": "https://target.pm.test/"},
        "blockList": {"pattern": "https://label.pm.test/*"},
        "allowList": {"pattern": "https://label.pm.test/*"},
        "sslProxyingList": {"pattern": "label.pm.test"},
        "sslApplications": {"bundleID": "com.example.cli.source", "name": "Source app", "action": "decrypt"},
        "dns": {"hostPattern": "label.pm.test", "ip": LOOPBACK},
        "customCertificates": {"hostPattern": "label.pm.test", "certificatePath": "/tmp/fixture-cert.pem", "privateKeyPath": "/tmp/fixture-key.pem"},
        "breakpoints": {},
        "rewrite": {"name": "Group", "rules": []},
        "latency": {"name": "Network", "milliseconds": 10},
        "protobuf": {"name": "Mapping"},
        "reverse": {"name": "Route", "listenPort": reverse_port, "remoteHost": LOOPBACK, "remotePort": origin_port},
    }
    for tool, fields in fixtures.items():
        folder = call(endpoint, token, "folders", {"tool": tool, "action": "create", "name": "Rule verb fixture"})["id"]
        fields = dict(fields, enabled=False)
        source = call(endpoint, token, "rules", {"tool": tool, "action": "add", "rule": fields, "folderId": folder})["rule"]
        source_id = rule_identity(tool, source)
        renamed = json.loads(command(binary, env, "rules", tool, "rename", "--id", source_id, "--name", "Renamed fixture"))["rule"]
        if tool in {"mapLocal", "mapRemote", "blockList", "allowList", "sslProxyingList"}:
            require(renamed["comment"] == "Renamed fixture" and renamed["pattern"] == source["pattern"], f"{tool}: rename altered matching fields")
        elif tool == "breakpoints":
            require(renamed["rule"]["name"] == "Renamed fixture", "breakpoint rename did not target predicate name")
        else:
            require(renamed["name"] == "Renamed fixture", f"{tool}: rename did not target model label")
        arguments = ["rules", tool, "duplicate", "--id", source_id, "--name", "Copied fixture"]
        if tool == "sslApplications":
            command(binary, env, *arguments, exit_code=2)
            arguments += ["--bundle-id", "com.example.cli.target"]
        copy = json.loads(command(binary, env, *arguments))["rule"]
        copy_id = rule_identity(tool, copy)
        require(copy_id != source_id and owned_ids(source).isdisjoint(owned_ids(copy)), f"{tool}: duplicate reused source IDs")
        members = call(endpoint, token, "rules", {"tool": tool, "action": "list", "folderId": folder})
        require({rule_identity(tool, row) for row in members} == {source_id, copy_id}, f"{tool}: duplicate lost folder membership")
        call(endpoint, token, "rules", {"tool": tool, "action": "enable", "id": source_id})
        call(endpoint, token, "rules", {"tool": tool, "action": "disable", "id": source_id})
        if tool == "reverse":
            require(copy["enabled"] is False, "reverse copy attempted to bind duplicate port")
        call(endpoint, token, "rules", {"tool": tool, "action": "delete", "id": copy_id})
        command(binary, env, "rules", tool, "delete", "--id", source_id)
        call(endpoint, token, "folders", {"tool": tool, "action": "delete", "id": folder})

    folder = call(endpoint, token, "folders", {"tool": "rewrite", "action": "create", "name": "Nested script fixture"})["id"]
    group = call(endpoint, token, "rules", {"tool": "rewrite", "action": "add", "folderId": folder,
        "rule": {"name": "Original group", "enabled": False}})["rule"]
    child = call(endpoint, token, "rules", {"tool": "rewrite", "action": "add", "groupId": group["id"], "folderId": folder,
        "rule": {"enabled": False}})["rule"]
    renamed = call(endpoint, token, "rules", {"tool": "rewrite", "action": "rename", "id": child["id"], "name": "Nested label"})["rule"]
    require(renamed["rule"]["name"] == "Nested label", "nested rule auto-resolution failed")
    group_before = call(endpoint, token, "rules", {"tool": "rewrite", "action": "get", "id": group["id"]})
    group_copy = call(endpoint, token, "rules", {"tool": "rewrite", "action": "duplicate", "id": group["id"]})["rule"]
    require(owned_ids(group_before).isdisjoint(owned_ids(group_copy)), "group copy retained a nested UUID")
    child_copy = json.loads(command(binary, env, "rules", "rewrite", "duplicate", "--id", child["id"], "--group-id", group["id"]))["rule"]
    require(owned_ids(child).isdisjoint(owned_ids(child_copy)), "child copy retained predicate UUID")
    listed = call(endpoint, token, "rules", {"tool": "rewrite", "action": "list", "groupId": group["id"]})
    require(len(listed) == 2, "nested duplicate was not inserted into its source group")
    call(endpoint, token, "rules", {"tool": "rewrite", "action": "delete", "id": group_copy["id"]})
    call(endpoint, token, "rules", {"tool": "rewrite", "action": "delete", "id": group["id"]})
    call(endpoint, token, "folders", {"tool": "rewrite", "action": "delete", "id": folder})
    passed("standalone rule rename/duplicate for every rule tool, folder inheritance and nested script ID regeneration")


def check_native_logs(binary, env, endpoint, token, proxy_port, origin_url):
    for index in range(105):
        require(proxy_request(proxy_port, origin_url + f"/native-logs/{index}")[0] == 200, "native log fixture failed")
    all_logs = json.loads(command(binary, env, "export", "logs", "all"))
    require(all_logs["version"] == 1 and len(all_logs["records"]) > 100, "logs export retained the flow query's 100-row limit")
    require("pinnedDomains" in all_logs and "selected" in all_logs, "native logs lost session metadata")
    latest = json.loads(command(binary, env, "export", "flows", "--format", "json", "--limit", "1"))
    require(len(latest) == 1, "flows pagination was changed by logs export")
    dns = call(endpoint, token, "rules", {"tool": "dns", "action": "add", "rule": {
        "hostPattern": "*.logs.pm.test", "ip": LOOPBACK}})["rule"]["id"]
    port = urlsplit(origin_url).port
    try:
        for domain in ["alpha.logs.pm.test", "beta.logs.pm.test", "alpha.logs.pm.test"]:
            require(proxy_request(proxy_port, f"http://{domain}:{port}/grouped-log")[0] == 200, "domain log fixture failed")
        bundle = json.loads(command(binary, env, "export", "logs", "domains", "--domains", "*.logs.pm.test"))
        require(bundle["format"] == "proxymirror-domain-logs", "domain logs did not return a grouped native bundle")
        require({group["domain"] for group in bundle["sessions"]} == {"alpha.logs.pm.test", "beta.logs.pm.test"}, "domain grouping/filtering failed")
        require(sum(len(group["session"]["records"]) for group in bundle["sessions"]) == 3, "domain grouping lost or duplicated a flow")
        for group in bundle["sessions"]:
            require(group["session"]["version"] == 1 and all(row["host"] == group["domain"] for row in group["session"]["records"]),
                    "group is not a complete native session for its domain")
        mcp_bundle = call(endpoint, token, "export_logs", {"scope": "domains", "domains": ["beta.logs.pm.test"]})
        require(len(mcp_bundle["sessions"]) == 1 and len(mcp_bundle["sessions"][0]["session"]["records"]) == 1,
                "MCP independent domain log export mismatch")
        tomorrow = (datetime.now(timezone.utc) + timedelta(days=1)).isoformat().replace("+00:00", "Z")
        yesterday = (datetime.now(timezone.utc) - timedelta(days=1)).isoformat().replace("+00:00", "Z")
        command(binary, env, "export", "logs", "all", "--from", tomorrow, exit_code=5)
        command(binary, env, "export", "logs", "all", "--to", yesterday, exit_code=5)
        command(binary, env, "export", "logs", "all", "--from", tomorrow, "--to", yesterday, exit_code=2)
        command(binary, env, "export", "logs", "all", "--limit", "1", exit_code=2)
        command(binary, env, "export", "flows", "--from", tomorrow, exit_code=2)
        passed("independent complete native logs (>100 records), domain bundles, MCP export and time boundaries")
    finally:
        call(endpoint, token, "rules", {"tool": "dns", "action": "delete", "id": dns})


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

                check_inclusive_proxy(binary, env, endpoint, token, proxy_port, origin.server_port, directory)
                check_rule_verbs(binary, env, endpoint, token, origin.server_port)
                check_native_logs(binary, env, endpoint, token, proxy_port, origin_url)

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
