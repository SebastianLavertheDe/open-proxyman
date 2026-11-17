"""Act as a Network Extension peer using loopback traffic only."""

import hashlib
import hmac
import json
import os
import socket
import ssl
import sys
import time
import uuid


def mac(token, message):
    return hmac.new(token.encode(), message, hashlib.sha256).hexdigest().encode()


def handshake(token, host, port, address, application):
    nonce = str(uuid.uuid4()).encode()
    flow = json.dumps(dict(host=host, port=port, address=address, application=application)).encode()
    message = b"PMTP/1 " + nonce + b"\r\n" + flow + b"\r\n"
    return (message + mac(token, message) + b"\r\n",
            b"OK " + mac(token, b"PMTP/1 OK " + nonce + b"\r\n") + b"\r\n")


def read_bytes(sock, count):
    received = bytearray()
    while len(received) < count:
        data = sock.recv(count - len(received))
        if not data:
            raise EOFError("Proxy closed the connection")
        received.extend(data)
    return bytes(received)


def rejected(port, message):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as peer:
        peer.sendall(message)
        assert peer.recv(1) == b"", "Ingress accepted an invalid handshake"


def request(host, path):
    return f"GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode()


def read_http(peer, path):
    response = bytearray()
    while data := peer.recv(8192):
        response.extend(data)
    assert response.startswith(b"HTTP/1.1 200 "), response
    assert path.encode() in response, response


def h2_frame(kind, flags, stream, data):
    return len(data).to_bytes(3, "big") + bytes([kind, flags]) + stream.to_bytes(4, "big") + data


def read_http2(peer, host, path):
    authority, path = host.encode(), path.encode()
    headers = b"\x82\x87\x01" + bytes([len(authority)]) + authority + b"\x04" + bytes([len(path)]) + path
    peer.sendall(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" + h2_frame(4, 0, 0, b"") + h2_frame(1, 5, 1, headers))
    body = bytearray()
    for _ in range(100):
        header = read_bytes(peer, 9)
        length, kind, flags = int.from_bytes(header[:3], "big"), header[3], header[4]
        stream = int.from_bytes(header[5:], "big")
        payload = read_bytes(peer, length)
        if kind == 4 and flags == 0:
            peer.sendall(h2_frame(4, 1, 0, b""))
        if kind == 0 and stream == 1:
            body.extend(payload)
        if stream == 1 and flags & 1 and kind in (0, 1):
            assert path in body, body
            return
        assert kind not in (3, 7), (kind, payload)
    raise AssertionError("HTTP/2 stream did not end")


def main():
    port, mode = int(sys.argv[1]), sys.argv[2]
    token = os.environ["PM_TRANSPARENT_TEST_TOKEN"]
    app = "com.sebastianLavertheDe.proxymirror.fixture"
    if mode == "http":
        host, path = "transparent.pm.test", "/transparent-http"
        frame, ack = handshake(token, host, 80, "127.0.0.1", app)
        rejected(port, handshake(token + "incorrect", host, 80, None, app)[0])
        rejected(port, handshake(token, host, 22, None, app)[0])
        rejected(port, handshake(token, host, 80, "bad-address.test", app)[0])
        rejected(port, b"x" * 4096)
        with socket.create_connection(("127.0.0.1", port), timeout=5) as peer:
            peer.sendall(frame[:19])
            time.sleep(0.03)
            peer.sendall(frame[19:] + request(host, path))
            peer.shutdown(socket.SHUT_WR)
            assert read_bytes(peer, len(ack)) == ack
            read_http(peer, path)
        rejected(port, frame)
        with socket.create_connection(("127.0.0.1", port), timeout=5) as peer:
            peer.sendall(frame[:19])
            assert peer.recv(1) == b"", "Incomplete handshake did not time out"
        return

    host = "allowed.pm.test"
    path = "/transparent-" + mode
    frame, ack = handshake(token, "127.0.0.1", 443, "127.0.0.1", app)
    tls = ssl.create_default_context(cafile=sys.argv[3])
    tls.set_alpn_protocols(["h2" if mode == "h2" else "http/1.1"])
    with socket.create_connection(("127.0.0.1", port), timeout=5) as peer:
        peer.sendall(frame)
        assert read_bytes(peer, len(ack)) == ack
        with tls.wrap_socket(peer, server_hostname=host) as channel:
            if mode == "h2":
                assert channel.selected_alpn_protocol() == "h2"
                read_http2(channel, host, path)
            else:
                channel.sendall(request(host, path))
                read_http(channel, path)


if __name__ == "__main__":
    main()
