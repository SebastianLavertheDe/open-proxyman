#!/usr/bin/env python3
"""Compile and exercise the actual vendored Zstandard C decoder, including limits.

This portable check does not require Swift/macOS. The Swift content-coding tests
cover its output/prefix/cancellation integration on macOS.
"""
import ctypes
import ctypes.util
from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="proxymirror-zstd-test-") as temporary:
        library = Path(temporary) / "decoder.so"
        subprocess.run(["cc", "-O2", "-fPIC", "-shared", "-I" + str(root / "Sources/ProxyMirrorZstd/include"),
                        str(root / "Sources/ProxyMirrorZstd/ProxyMirrorZstd.c"),
                        str(root / "Sources/ProxyMirrorZstd/zstddeclib.c"), "-o", str(library)], check=True)
        decoder = ctypes.CDLL(str(library))
        decoder.pm_zstd_create.restype = ctypes.c_void_p
        decoder.pm_zstd_destroy.argtypes = [ctypes.c_void_p]
        decoder.pm_zstd_decode.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t),
                                           ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t)]
        # Independently generated frame with UTF-8 content and no dictionary.
        wire = bytes.fromhex("28b52ffd2018c1000050726f78794d6972726f72207a73746420e4b8ade696870a")
        plain = "ProxyMirror zstd 中文\n".encode()

        def decode(data, chunk=32768):
            context = decoder.pm_zstd_create()
            assert context
            try:
                result = bytearray()
                offset = 0
                while True:
                    used = ctypes.c_size_t(len(data) - offset)
                    written = ctypes.c_size_t(chunk)
                    output = ctypes.create_string_buffer(chunk)
                    status = decoder.pm_zstd_decode(context, data[offset:], ctypes.byref(used), output,
                                                    ctypes.byref(written))
                    if status < 0:
                        raise ValueError("invalid frame")
                    offset += used.value
                    result.extend(output.raw[:written.value])
                    if status == 0 and offset == len(data):
                        return bytes(result)
                    if used.value == 0 and written.value == 0:
                        raise ValueError("truncated frame")
            finally:
                decoder.pm_zstd_destroy(context)

        assert decode(wire) == plain
        assert decode(wire, chunk=1) == plain
        assert decode(wire + wire, chunk=7) == plain + plain
        # Valid skippable frame followed by a normal frame.
        assert decode(bytes.fromhex("502a4d1803000000") + b"abc" + wire) == plain
        for invalid in [wire[:-1], b"not zstandard", wire + b"garbage"]:
            try:
                decode(invalid)
            except ValueError:
                pass
            else:
                raise AssertionError("corrupt/truncated input accepted")
        # Declaring a 2 GiB window is rejected before allocating that window.
        oversized_window = bytes.fromhex("28b52ffd00a8000000")
        try:
            decode(oversized_window)
        except ValueError:
            pass
        else:
            raise AssertionError("oversized decoder window accepted")
        print("PASS: vendored Zstd UTF-8, chunked output, concatenation, skippable frames, corrupt/truncated input, window cap")


if __name__ == "__main__":
    main()
