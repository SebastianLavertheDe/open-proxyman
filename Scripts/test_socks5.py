#!/usr/bin/env python3
"""Exercise SOCKS5 on an already-running isolated ProxyMirror listener.

Start a clean test instance without system proxy takeover, then pass its port.
All origin traffic stays on localhost; the test does not modify app settings.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import socket
import threading


def receive(connection, count):
    chunks = bytearray()
    while len(chunks) < count:
        part = connection.recv(count - len(chunks))
        if not part:
            raise AssertionError("proxy closed before its SOCKS response")
        chunks.extend(part)
    return bytes(chunks)


def connect(proxy_port):
    client = socket.create_connection(("127.0.0.1", proxy_port), timeout=5)
    client.settimeout(5)
    # Deliberately split the method negotiation across TCP writes.
    for fragment in [b"\x05", b"\x02\x02", b"\x00"]:
        client.sendall(fragment)
    assert receive(client, 2) == b"\x05\x00"
    return client


def request_address(host, port):
    try:
        address = ipaddress.ip_address(host)
        encoded = bytes([1 if address.version == 4 else 4]) + address.packed
    except ValueError:
        encoded_host = host.encode("ascii")
        encoded = bytes([3, len(encoded_host)]) + encoded_host
    return b"\x05\x01\x00" + encoded + port.to_bytes(2, "big")


class Origin(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"SOCKS5 through ProxyMirror\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    assert 1 <= args.port <= 65535
    origin = ThreadingHTTPServer(("127.0.0.1", 0), Origin)
    worker = threading.Thread(target=origin.serve_forever, daemon=True)
    worker.start()
    try:
        for host in ["127.0.0.1", "localhost"]:
            with connect(args.port) as client:
                request = request_address(host, origin.server_port)
                client.sendall(request[:5])
                client.sendall(request[5:])
                reply = receive(client, 10)
                assert reply[:4] == b"\x05\x00\x00\x01", reply
                client.sendall(f"GET / HTTP/1.1\r\nHost: {host}:{origin.server_port}\r\nConnection: close\r\n\r\n".encode())
                response = bytearray()
                while part := client.recv(65536):
                    response.extend(part)
                assert response.startswith(b"HTTP/1.1 200") and response.endswith(b"SOCKS5 through ProxyMirror\n"), response
        with connect(args.port) as client:
            client.sendall(request_address("127.0.0.1", args.port))
            assert receive(client, 10)[1] == 2, "self-loop must be rejected"
        with connect(args.port) as client:
            client.sendall(b"\x05\x03\x00\x01\x7f\x00\x00\x01\x00\x50")
            assert receive(client, 10)[1] == 7, "UDP ASSOCIATE must be rejected"
        with socket.create_connection(("127.0.0.1", args.port), timeout=5) as client:
            client.sendall(b"\x05\x01\x02")
            assert receive(client, 2) == b"\x05\xff", "username/password auth must not be advertised"
        print("PASS: fragmented SOCKS5 negotiation, IPv4/domain CONNECT and HTTP relay, self-loop/auth/UDP rejection")
    finally:
        origin.shutdown()
        origin.server_close()
        worker.join(timeout=5)


if __name__ == "__main__":
    main()
