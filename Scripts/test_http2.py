"""End-to-end HTTP/2 and gRPC proxy regression using a local Go standard-library fixture."""

import argparse
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile

from test_loopback import certificates, executable, positive_integer, selftest_binary


def fixture_ports(origin):
    with selectors.DefaultSelector() as selector:
        selector.register(origin.stdout, selectors.EVENT_READ)
        if not selector.select(timeout=10):
            raise RuntimeError("HTTP/2 fixture did not report its ports within 10 seconds")
    fields = origin.stdout.readline().split()
    if len(fields) != 3 or not all(field.isascii() and field.isdigit() and 1 <= int(field) <= 65535
                                   for field in fields):
        raise RuntimeError(f"HTTP/2 fixture returned invalid ports: {fields!r}")
    return fields


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=positive_integer, default=90, help="SelfTest timeout in seconds")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        binary = selftest_binary(root)
        fixture_override = os.environ.get("PM_HTTP2_FIXTURE_BIN")
        override = executable(fixture_override, "HTTP/2 fixture") if fixture_override is not None else None
    except ValueError as error:
        parser.error(str(error))
    with tempfile.TemporaryDirectory(prefix="proxymirror-http2-") as tmp:
        directory = Path(tmp)
        fixture = override or directory / "http2_fixture"
        if override is None:
            build_env = dict(os.environ)
            if "PM_FIXTURE_GO" in build_env:
                build_env.pop("GOROOT", None)
            subprocess.run([os.environ.get("PM_FIXTURE_GO", "go"), "build", "-o", fixture,
                            root / "Scripts/http2_fixture.go"], check=True, env=build_env)
        ca, leaf, key = certificates(directory)
        with subprocess.Popen([fixture, "server", leaf, key], stdout=subprocess.PIPE, text=True) as origin:
            try:
                first, fallback, external = fixture_ports(origin)
                env = {
                    **os.environ,
                    "PM_SUPPORT_DIR": str(directory / "app-support"),
                    "PM_HTTP2_FIXTURE": str(fixture),
                    "PM_HTTP2_ORIGIN": first,
                    "PM_HTTP2_FALLBACK": fallback,
                    "PM_HTTP2_EXTERNAL": external,
                    "PM_HTTP2_CA": str(ca),
                }
                return subprocess.run([binary, "--http2-loopback"], env=env, timeout=args.timeout).returncode
            finally:
                if origin.poll() is None:
                    origin.terminate()
                    try:
                        origin.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        origin.kill()


if __name__ == "__main__":
    sys.exit(main())
