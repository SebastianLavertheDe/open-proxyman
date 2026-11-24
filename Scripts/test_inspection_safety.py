#!/usr/bin/env python3
"""Compile the production bounded regex and MessagePack decoder, without UI stubs.

Runs on Linux or macOS with Swift Foundation. The macOS CoreChecks also exercise
TrafficCondition and saved coloring integration; this harness checks the actual
matching interruption and JSON conversion implementations, including cancellation.
"""
import argparse
import os
from pathlib import Path
from foundation_test_support import build_foundation_module
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
import Foundation

@main struct InspectionSafetyChecks {
    static func main() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { fatalError(message) }; checks += 1
        }
        let normal = try BoundedTrafficRegex(pattern: #"^api\.example\.test$"#, options: [.caseInsensitive])
        try expect(normal.matchesAny(in: ["other", "API.EXAMPLE.TEST"]) == true, "ordinary case-insensitive matching changed")
        try expect(normal.matchesAny(in: ["api.example.test.evil"]) == false, "anchoring changed")
        let slowInput = String(repeating: "a", count: 48) + "!"
        let limited = try BoundedTrafficRegex(pattern: "(a+)+$", maximumDuration: 0.004)
        let start = ProcessInfo.processInfo.systemUptime
        try expect(limited.matchesAny(in: [slowInput]) == nil, "catastrophic matching did not exhaust its deadline")
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        try expect(elapsed < 0.5, "the regex deadline did not interrupt the matching engine")
        try expect(limited.matchesAny(in: ["a"]) == nil, "quarantined rule retried its matching budget")
        let workLimited = try BoundedTrafficRegex(pattern: "(a+)+$", maximumDuration: 10, maximumProgressCallbacks: 1)
        try expect(workLimited.matchesAny(in: [slowInput]) == nil, "the progress-work budget did not interrupt matching")
        let cancellable = try BoundedTrafficRegex(pattern: "(a+)+$", maximumDuration: 2, maximumProgressCallbacks: 1_000_000)
        let worker = Task.detached { cancellable.matchesAny(in: [slowInput]) }
        try await Task.sleep(nanoseconds: 2_000_000)
        worker.cancel()
        let cancelled = await worker.value
        try expect(cancelled == nil, "task cancellation did not interrupt an active match")
        try expect(cancellable.matchesAny(in: ["a"]) == true, "cancellation permanently quarantined an otherwise usable pattern")

        let fixtures: [(Data, String)] = [
            (Data([0x81, 0xa1, 0x6b, 0x01]), #"{"k":1}"#),
            (Data([0x81, 0x01, 0xa1, 0x78]), #"{"_map":[[1,"x"]]}"#),
            (Data([0x82, 0x01, 0xa1, 0x78, 0xa1, 0x31, 0xa1, 0x79]), #"{"_map":[[1,"x"],["1","y"]]}"#),
            (Data([0x81, 0x91, 0x01, 0x02]), #"{"_map":[[[1],2]]}"#),
            (Data([0xca, 0x7f, 0xc0, 0x00, 0x00]), #"{"_float":"NaN"}"#),
            (Data([0xca, 0x7f, 0x80, 0x00, 0x00]), #"{"_float":"Infinity"}"#),
            (Data([0xcb, 0xff, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]), #"{"_float":"-Infinity"}"#),
            (Data([0x01]), "1"),
            (Data([0xc0]), "null"),
        ]
        for (wire, expected) in fixtures {
            let inspection = MessagePackBody.inspect(wire, contentType: "application/msgpack")
            try expect(inspection.decoded && inspection.contentType == "application/json", "supported MessagePack value was not decoded")
            try expect(String(decoding: inspection.data, as: UTF8.self) == expected, "MessagePack type representation changed")
            try expect((try? JSONSerialization.jsonObject(with: inspection.data, options: [.fragmentsAllowed])) != nil,
                       "advertised JSON is not valid")
        }
        try expect(MessagePackBody.decodeIfMessagePack(Data([0x81, 0x01]), contentTypeHint: "application/msgpack") == nil,
                   "truncated MessagePack was accepted")
        try expect(MessagePackBody.decodeIfMessagePack(Data(#"{"original":true}"#.utf8), contentTypeHint: "application/json") == nil,
                   "ordinary JSON was converted")
        print("PASS: \(checks) inspection safety checks; catastrophic regex stopped in \(String(format: "%.4f", elapsed)) seconds")
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default=os.environ.get("SWIFTC", shutil.which("swiftc")))
    args = parser.parse_args()
    if not args.swiftc:
        parser.error("Swift compiler is required; pass --swiftc or set SWIFTC")
    with tempfile.TemporaryDirectory(prefix="pm-inspection-safety-") as directory:
        path = Path(directory)
        module_flags = build_foundation_module(args.swiftc, path)
        harness = path / "Checks.swift"
        harness.write_text("import ProxyMirrorFoundation\n" + HARNESS, encoding="utf-8")
        binary = path / "checks"
        subprocess.run([args.swiftc, "-parse-as-library", *module_flags, str(harness), "-o", str(binary)],
                       check=True, timeout=120)
        subprocess.run([str(binary)], check=True, timeout=15)


if __name__ == "__main__":
    main()
