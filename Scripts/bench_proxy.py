"""Measure fixed HTTP/1.1 workloads over loopback, with optional baseline comparison."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import os
from pathlib import Path
import platform
import selectors
from statistics import median
import subprocess
import sys
import tempfile
import threading
import time

from test_loopback import executable, positive_integer


LOOPBACK = "127.0.0.1"
REQUEST_PATH = "/benchmark"
BODY = bytes(range(256)) * 4
RESPONSE = b"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 1024\r\n\r\n" + BODY
SAMPLE_INTERVAL = 0.2
MODES = ("direct", "paused", "recording")


class Origin(ThreadingHTTPServer):
    request_queue_size = 128


class OriginHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path == REQUEST_PATH:
            self.wfile.write(RESPONSE)
        else:
            self.send_error(404)

    def log_message(self, *_):
        pass


def percentile(samples, fraction):
    if not samples:
        return None
    ordered = sorted(samples)
    return ordered[math.ceil(fraction * len(ordered)) - 1]


def load_worker(port, target, count, barrier):
    connection = http.client.HTTPConnection(LOOPBACK, port, timeout=8)
    latencies = []
    errors = []
    barrier.wait()
    try:
        for _ in range(count):
            started = time.perf_counter()
            try:
                connection.request("GET", target)
                response = connection.getresponse()
                body = response.read(len(BODY) + 1)
                if response.status != 200 or body != BODY:
                    raise ValueError(f"unexpected response {response.status}, {len(body)} bytes")
                latencies.append((time.perf_counter() - started) * 1000)
            except (OSError, ValueError, http.client.HTTPException) as error:
                connection.close()
                errors.append(str(error))
                if isinstance(error, TimeoutError):
                    break
    finally:
        connection.close()
    return latencies, errors


def load_round(executor, port, target, requests, concurrency):
    barrier = threading.Barrier(concurrency + 1, timeout=10)
    base, remainder = divmod(requests, concurrency)
    futures = [executor.submit(load_worker, port, target, base + (index < remainder), barrier)
               for index in range(concurrency)]
    started = time.perf_counter()
    barrier.wait()
    results = [future.result() for future in futures]
    duration = time.perf_counter() - started
    latencies = [latency for samples, _ in results for latency in samples]
    errors = [error for _, failures in results for error in failures]
    skipped = requests - len(latencies) - len(errors)
    return {
        "requested": requests,
        "succeeded": len(latencies),
        "failed": len(errors),
        "skipped_after_timeout": skipped,
        "errors": errors[:5],
        "seconds": duration,
        "throughput_rps": len(latencies) / duration,
        "p50_ms": percentile(latencies, 0.50),
        "p95_ms": percentile(latencies, 0.95),
    }


def integer_line(proxy, timeout, field):
    with selectors.DefaultSelector() as selector:
        selector.register(proxy.stdout, selectors.EVENT_READ)
        if not selector.select(timeout=timeout):
            raise RuntimeError(f"proxy did not report {field} within {timeout}s")
    line = proxy.stdout.readline().strip()
    if not line.isascii() or not line.isdigit():
        raise RuntimeError(f"proxy reported invalid {field}: {line!r}")
    return int(line)


@contextmanager
def proxy_process(binary, mode, timeout):
    with tempfile.TemporaryDirectory(prefix="pm-bench-") as tmp, tempfile.TemporaryFile(mode="w+t") as log:
        env = {**os.environ, "PM_SUPPORT_DIR": str(Path(tmp) / "support")}
        with subprocess.Popen([binary, "--benchmark-proxy", mode], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=log, env=env, text=True) as proxy:
            try:
                port = integer_line(proxy, timeout, "listen port")
                if not 1 <= port <= 65535:
                    raise RuntimeError(f"proxy reported invalid port: {port}")
                yield proxy, port
            except BaseException:
                if proxy.poll() is None:
                    proxy.kill()
                proxy.wait()
                log.seek(0)
                print(log.read()[-4000:], file=sys.stderr, end="")
                raise


def sample_process(pid, stop, samples):
    while not stop.is_set():
        result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "rss=", "-o", "time="],
                                capture_output=True, text=True)
        fields = result.stdout.split()
        if len(fields) == 2:
            rss, elapsed = fields
            cpu_seconds = 0.0
            for component in elapsed.split(":"):
                cpu_seconds = cpu_seconds * 60 + float(component)
            samples.append((int(rss), cpu_seconds))
        stop.wait(SAMPLE_INTERVAL)


def run_rounds(args, port, target, mode):
    concurrency = min(args.concurrency, args.requests)
    with ThreadPoolExecutor(max_workers=concurrency) as executor:
        warmup = [load_round(executor, port, target, args.requests, concurrency) for _ in range(args.warmup)]
        measured = []
        for index in range(args.rounds):
            row = load_round(executor, port, target, args.requests, concurrency)
            measured.append(row)
            print(f"{mode} {index + 1}/{args.rounds}  {row['throughput_rps']:.0f} req/s  "
                  f"p95={row['p95_ms']} ms  ok={row['succeeded']}/{args.requests}", flush=True)
    return warmup, measured


def summarize(warmup, measured):
    succeeded = sum(row["succeeded"] for row in measured)
    requested = sum(row["requested"] for row in measured)
    p50 = [row["p50_ms"] for row in measured if row["p50_ms"] is not None]
    p95 = [row["p95_ms"] for row in measured if row["p95_ms"] is not None]
    return {
        "warmup": warmup,
        "measured": measured,
        "p50_ms": median(p50) if p50 else None,
        "p95_ms": median(p95) if p95 else None,
        "throughput_rps": succeeded / sum(row["seconds"] for row in measured),
        "error_rate": (requested - succeeded) / requested,
        "failed_or_skipped": sum(row["requested"] - row["succeeded"] for row in warmup + measured),
    }


def run_proxy(args, mode, origin_port):
    target = f"http://{LOOPBACK}:{origin_port}{REQUEST_PATH}"
    with proxy_process(args.binary, mode, args.timeout) as (proxy, port):
        stop = threading.Event()
        samples = []
        sampler = threading.Thread(target=sample_process, args=(proxy.pid, stop, samples), daemon=True)
        sampler.start()
        try:
            warmup, measured = run_rounds(args, port, target, mode)
            proxy.stdin.write("\n")
            proxy.stdin.flush()
            captured = integer_line(proxy, args.timeout, "capture count")
            if proxy.wait(timeout=args.timeout) != 0:
                raise RuntimeError(f"proxy exited with status {proxy.returncode}")
        finally:
            stop.set()
            sampler.join()
    expected = args.requests * (args.warmup + args.rounds) if mode == "recording" else 0
    return {
        **summarize(warmup, measured),
        "captured_requests": captured,
        "expected_captured_requests": expected,
        "proxy_peak_rss_kib_sampled": max((rss for rss, _ in samples), default=None),
        "proxy_cpu_seconds_sampled": max((cpu for _, cpu in samples), default=None),
    }


def comparison(baseline, result):
    for key in ("schema_version", "scenario", "workload", "machine", "python"):
        if baseline.get(key) != result[key]:
            raise ValueError(f"baseline {key} does not match this run")
    regressions = []
    for mode, current in result["modes"].items():
        previous = baseline["modes"][mode]
        if previous["failed_or_skipped"] or previous.get("captured_requests") != previous.get("expected_captured_requests"):
            raise ValueError(f"baseline {mode} contains a failed workload")
        for metric, limit, direction in (
            ("p95_ms", 0.15, 1),
            ("proxy_peak_rss_kib_sampled", 0.15, 1),
            ("throughput_rps", 0.10, -1),
        ):
            before, after = previous.get(metric), current.get(metric)
            if before and after is not None:
                change = (after / before - 1) * direction
                if change > limit:
                    regressions.append({"mode": mode, "metric": metric, "baseline": before, "current": after,
                                        "regression_fraction": change, "allowed_fraction": limit})
    return regressions


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=root / ".build/release/ProxyMirrorSelfTest")
    parser.add_argument("--scenario", default="small-requests", choices=["small-requests"])
    parser.add_argument("--requests", type=positive_integer, default=5000, help="requests per round")
    parser.add_argument("--concurrency", type=positive_integer, default=32, help="concurrent connections")
    parser.add_argument("--warmup", type=int, default=1, help="unmeasured rounds per mode")
    parser.add_argument("--rounds", type=positive_integer, default=5, help="measured rounds per mode")
    parser.add_argument("--timeout", type=positive_integer, default=20, help="proxy startup/exit deadline in seconds")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, help="compare to a previous run from the same machine and workload")
    args = parser.parse_args()
    if args.warmup < 0:
        parser.error("--warmup must be zero or more")
    try:
        args.binary = executable(args.binary, "ProxyMirror benchmark")
        baseline = json.loads(args.baseline.read_text(encoding="utf-8")) if args.baseline else None
        model = subprocess.run(["/usr/sbin/sysctl", "-n", "hw.model"], check=True, capture_output=True, text=True)
        result = {
            "schema_version": 1,
            "scenario": args.scenario,
            "workload": {"requests_per_round": args.requests, "concurrency": min(args.concurrency, args.requests),
                         "warmup_rounds": args.warmup, "measured_rounds": args.rounds, "response_bytes": len(BODY)},
            "machine": {"model": model.stdout.strip(), "architecture": platform.machine(),
                        "macos": platform.mac_ver()[0], "kernel": platform.release()},
            "binary": str(args.binary),
            "binary_sha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
            "python": platform.python_version(),
            "latency_summary": "median of measured round percentiles",
            "resource_sample_interval_seconds": SAMPLE_INTERVAL,
            "modes": {},
        }
        with Origin((LOOPBACK, 0), OriginHandler) as origin:
            thread = threading.Thread(target=origin.serve_forever, daemon=True)
            thread.start()
            try:
                warmup, measured = run_rounds(args, origin.server_port, REQUEST_PATH, "direct")
                result["modes"]["direct"] = summarize(warmup, measured)
                for mode in MODES[1:]:
                    result["modes"][mode] = run_proxy(args, mode, origin.server_port)
            finally:
                origin.shutdown()
                thread.join()
        result["regressions"] = comparison(baseline, result) if baseline is not None else []
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(f"Report: {args.output.resolve()}", flush=True)
        failed = [mode for mode, stats in result["modes"].items()
                  if stats["failed_or_skipped"] or stats.get("captured_requests") != stats.get("expected_captured_requests")]
        if failed:
            print(f"Workload/capture validation failed: {', '.join(failed)}", file=sys.stderr)
        if result["regressions"]:
            print(f"Performance regressions: {len(result['regressions'])}", file=sys.stderr)
        return int(bool(failed or result["regressions"]))
    except (OSError, ValueError, RuntimeError, KeyError, subprocess.SubprocessError) as error:
        print(f"Proxy benchmark failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
