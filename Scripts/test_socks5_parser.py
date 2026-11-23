#!/usr/bin/env python3
"""Native behavior tests for the actual C parser called by SOCKS5ProxyHandshake."""
import ctypes
from pathlib import Path
import random
import subprocess
import tempfile


class Request(ctypes.Structure):
    _fields_ = [("address_offset", ctypes.c_size_t), ("address_length", ctypes.c_size_t),
                ("consumed", ctypes.c_size_t), ("port", ctypes.c_uint16), ("address_type", ctypes.c_uint8)]


def main():
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="proxymirror-socks-parser-") as temporary:
        path = Path(temporary) / "parser.so"
        subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", "-O2", "-fPIC", "-shared",
                        "-I" + str(root / "Sources/ProxyMirrorProtocolSupport/include"),
                        str(root / "Sources/ProxyMirrorProtocolSupport/SOCKS5Parser.c"), "-o", str(path)], check=True)
        library = ctypes.CDLL(str(path))
        library.pm_socks5_greeting.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
        library.pm_socks5_parse_request.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(Request)]

        def greeting(data):
            consumed = ctypes.c_size_t()
            status = library.pm_socks5_greeting(data, len(data), ctypes.byref(consumed))
            return status, consumed.value

        def parse(data):
            request = Request()
            status = library.pm_socks5_parse_request(data, len(data), ctypes.byref(request))
            return status, request

        accepted = b"\x05\x03\x02\x80\x00"
        for split in range(len(accepted)):
            assert greeting(accepted[:split])[0] == 0
        assert greeting(accepted + b"extra") == (1, len(accepted))
        assert greeting(b"\x05\x00")[0] == -255
        assert greeting(b"\x05\x01\x02")[0] == -255
        assert greeting(b"\x04\x01\x00")[0] == -255
        for address_type, address in [(1, bytes([127, 0, 0, 1])), (4, bytes(15) + b"\x01"),
                                      (3, b"localhost"), (3, b"a" * 255)]:
            prefix = b"\x05\x01\x00" + bytes([address_type])
            wire = prefix + (bytes([len(address)]) if address_type == 3 else b"") + address + b"\x01\xbb"
            for split in range(len(wire)):
                assert parse(wire[:split])[0] == 0, (wire, split)
            status, request = parse(wire + b"HTTP/1.1\r\n")
            assert status == 1 and request.port == 443 and request.consumed == len(wire)
            assert (wire[request.address_offset:request.address_offset + request.address_length]) == address
        for wire, expected in [(b"\x05\x03\x00\x01", -7), (b"\x05\x02\x00\x01", -7),
                               (b"\x04\x01\x00\x01", -1), (b"\x05\x01\x01\x01", -1),
                               (b"\x05\x01\x00\x02", -8), (b"\x05\x01\x00\x03\x00", -8),
                               (b"\x05\x01\x00\x01\x7f\x00\x00\x01\x00\x00", -8)]:
            assert parse(wire)[0] == expected
        rng = random.Random(0x50524F58)
        for _ in range(5000):
            wire = rng.randbytes(rng.randrange(0, 512))
            status, request = parse(wire)
            if status == 1:
                assert request.consumed <= len(wire) and request.port > 0
                assert request.address_offset + request.address_length + 2 == request.consumed
        print("PASS: native SOCKS greeting/request parser, every fragmentation boundary, IPv4/6/domain, coalesced bytes, auth/command/address/port errors, 5000 fuzz inputs")


if __name__ == "__main__":
    main()
