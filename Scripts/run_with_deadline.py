#!/usr/bin/env python3
"""Run a native check with streamed output and a process-group deadline."""
import argparse
import math
import os
import signal
import subprocess
import sys


class Interrupted(Exception):
    def __init__(self, number):
        self.number = number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", required=True, type=float)
    parser.add_argument("--grace", type=float, default=5)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0 or not math.isfinite(args.grace) or args.grace < 0:
        parser.error("timeout must be positive and grace must be nonnegative")
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a command is required after --")
    process = subprocess.Popen(command, start_new_session=True)

    def interrupted(number, _frame):
        raise Interrupted(number)

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)

    def stop_group(sig):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass

    try:
        result = process.wait(timeout=args.timeout)
        return result if result >= 0 else 128 - result
    except subprocess.TimeoutExpired:
        print(f"FAIL: native check exceeded {args.timeout:g}s: {command[0]}", file=sys.stderr, flush=True)
        status = 124
    except KeyboardInterrupt:
        status = 130
    except Interrupted as interruption:
        status = 128 + interruption.number
    stop_group(signal.SIGTERM)
    try:
        process.wait(timeout=args.grace)
    except subprocess.TimeoutExpired:
        pass
    # A child can exit before its descendants; terminate the whole check group.
    stop_group(signal.SIGKILL)
    process.wait()
    return status


if __name__ == "__main__":
    sys.exit(main())
