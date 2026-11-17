"""Run ProxyMirror's regression suites against isolated loopback services."""

import argparse
import base64
import gzip
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def serve_sample(self):
        if self.path.startswith("/ws"):
            key = self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
            accept = base64.b64encode(hashlib.sha1(key.encode()).digest()).decode()
            head = ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                    f"Sec-WebSocket-Accept: {accept}\r\n")
            if self.path == "/ws-compressed" and self.headers.get("Sec-WebSocket-Extensions") == "permessage-deflate":
                head += "Sec-WebSocket-Extensions: permessage-deflate\r\n"
                frame = bytes.fromhex("c1 07 f2 48 cd c9 c9 07 00")
            else:
                frame = b"\x81\x02hi"
            self.connection.sendall((head + "\r\n").encode() + frame)
            time.sleep(1.0)   # 留给 WS 帧脚本的决策窗口（脚本 worker 启动约 100ms），避免 curl 先退场
            self.close_connection = True
            return
        if self.path.startswith("/coding/"):
            name = self.path.rsplit("/", 1)[1]
            body = b'{"capture":"content-coding"}'
            encoded = {
                "gzip": gzip.compress(body, mtime=0),
                "deflate": zlib.compress(body),
                "br": base64.b64decode("jw2AeyJjYXB0dXJlIjoiY29udGVudC1jb2RpbmcifQM="),
            }[name]
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Encoding", name)
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
            return
        if self.path == "/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for chunk in (b": comment\r\nevent: added\r\ndata: {\"n\": 1}\r\nid: 42\r\n\r\n",
                          b"retry: 2500\ndata: one\ndata: two\n\n"):
                self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
                self.wfile.flush()
                time.sleep(0.08)
            self.wfile.write(b"0\r\n\r\n")
            return
        if self.path.startswith("/timeout"):
            time.sleep(32)
        if self.path.startswith("/informational"):
            self.wfile.write(b"HTTP/1.1 103 Early Hints\r\nLink: </asset>\r\n\r\n")
        if self.path.startswith("/closing"):
            self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nclose-delimited")
            self.close_connection = True
            return
        data = b""
        if self.headers.get("Transfer-Encoding") == "chunked":
            while True:
                length = int(self.rfile.readline().strip().split(b";")[0], 16)
                if length == 0:
                    while self.rfile.readline().strip():
                        pass
                    break
                data += self.rfile.read(length)
                assert self.rfile.read(2) == b"\r\n"
        elif self.headers.get("Content-Length"):
            data = self.rfile.read(int(self.headers["Content-Length"]))
        body = json.dumps({
            "path": self.path, "method": self.command, "host": self.headers["Host"],
            "body": data.decode("utf-8", "replace"), "server": self.server.server_port,
        }).encode()
        self.send_response(404 if self.path.startswith("/missing") else 200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Set-Cookie", "sample=a")
        self.send_header("Set-Cookie", "sample=b")
        if self.path.startswith("/chunk"):
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Trailer", "X-End")
            self.end_headers()
            self.wfile.write(f"{len(body):x}\r\n".encode() + body + b"\r\n0\r\nX-End: fixture\r\n\r\n")
        else:
            self.send_header("Content-Length", str(len(body)))
            try:
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    do_GET = do_POST = do_HEAD = serve_sample


def certificates(directory):
    config = directory / "openssl.cnf"
    config.write_text(
        "[req]\nprompt=no\ndistinguished_name=dn\n"
        "[dn]\nCN=ProxyMirror loopback test\n"
        "[root]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n"
        "[leaf]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
        "extendedKeyUsage=serverAuth\nsubjectAltName=DNS:allowed.pm.test,DNS:adjacent.pm.test\n"
    )
    ca, ca_key = directory / "root.pem", directory / "root.key"
    leaf, leaf_key, csr = directory / "leaf.pem", directory / "leaf.key", directory / "leaf.csr"
    commands = [
        ["req", "-new", "-x509", "-nodes", "-newkey", "rsa:2048", "-days", "2",
         "-config", config, "-extensions", "root", "-out", ca, "-keyout", ca_key],
        ["req", "-new", "-nodes", "-newkey", "rsa:2048", "-config", config, "-out", csr, "-keyout", leaf_key],
        ["x509", "-req", "-in", csr, "-CA", ca, "-CAkey", ca_key, "-CAcreateserial",
         "-days", "2", "-extfile", config, "-extensions", "leaf", "-out", leaf],
    ]
    for args in commands:
        subprocess.run(["/usr/bin/openssl", *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    return ca, leaf, leaf_key


def ssl_application_fixtures(root, directory):
    client = directory / "TLSClient"
    subprocess.run(["/usr/bin/clang", str(root / "Scripts/ssl_app_fixture.c"), "-lcurl", "-o", str(client)], check=True)
    clients = []
    for name, identifier in [("SSL Fixture A", "test.proxymirror.ssla"), ("SSL Fixture B", "test.proxymirror.sslb")]:
        app = directory / f"{name}.app"
        executable = app / "Contents/MacOS/TLSClient"
        executable.parent.mkdir(parents=True)
        shutil.copy2(client, executable)
        with (app / "Contents/Info.plist").open("wb") as file:
            plistlib.dump({
                "CFBundleExecutable": executable.name,
                "CFBundleIdentifier": identifier,
                "CFBundleName": name,
                "CFBundlePackageType": "APPL",
            }, file)
        clients.append(executable)
    return clients


def executable(path, label):
    path = Path(path).expanduser().resolve()
    if not path.is_file() or not os.access(path, os.X_OK):
        raise ValueError(f"{label} is not an executable file: {path}")
    return path


def selftest_binary(root):
    return executable(os.environ.get("PM_SELFTEST_BIN", root / ".build/debug/ProxyMirrorSelfTest"), "SelfTest")


def positive_integer(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--full", action="store_true", help="include the real upstream timeout check")
    mode.add_argument("--concurrency", action="store_true", help="run the standalone shared-state stress suite")
    parser.add_argument("--timeout", type=positive_integer, default=120, help="SelfTest timeout in seconds")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        binary = selftest_binary(root)
    except ValueError as error:
        parser.error(str(error))
    if args.concurrency:
        with tempfile.TemporaryDirectory(prefix="proxymirror-concurrency-") as tmp:
            env = {**os.environ, "PM_SUPPORT_DIR": str(Path(tmp) / "app-support")}
            return subprocess.run([binary, "--concurrency"], env=env, timeout=args.timeout).returncode
    with tempfile.TemporaryDirectory(prefix="proxymirror-loopback-") as tmp, socket.socket() as refused:
        directory = Path(tmp)
        ca, leaf, leaf_key = certificates(directory)
        ssl_app_a, ssl_app_b = ssl_application_fixtures(root, directory)
        servers = [ThreadingHTTPServer(("127.0.0.1", 0), Handler) for _ in range(3)]
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(leaf, leaf_key)
        servers[2].socket = context.wrap_socket(servers[2].socket, server_side=True)
        refused.bind(("127.0.0.1", 0))
        refused_port = refused.getsockname()[1]
        refused.close()
        for server in servers:
            threading.Thread(target=server.serve_forever, daemon=True).start()
        env = {
            **os.environ,
            "PM_SUPPORT_DIR": str(directory / "app-support"),
            "PM_FIXTURE_A": str(servers[0].server_port),
            "PM_FIXTURE_B": str(servers[1].server_port),
            "PM_FIXTURE_TLS": str(servers[2].server_port),
            "PM_FIXTURE_CA": str(ca),
            "PM_FIXTURE_SSL_APP_A": str(ssl_app_a),
            "PM_FIXTURE_SSL_APP_B": str(ssl_app_b),
            "PM_FIXTURE_REFUSED": str(refused_port),
            "PM_FIXTURE_TIMEOUT": "1" if args.full else "0",
            "PM_FIXTURE_TRANSPARENT_PEER": str(root / "Scripts/transparent_ingress_fixture.py"),
            "PM_FIXTURE_PYTHON": sys.executable,
        }
        try:
            return subprocess.run([binary, "--loopback"], env=env, timeout=args.timeout).returncode
        finally:
            for server in servers:
                server.shutdown()
                server.server_close()


if __name__ == "__main__":
    sys.exit(main())
