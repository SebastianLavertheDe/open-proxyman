#!/usr/bin/env python3
"""Compile the real diagnostic policy and HTTP wire models without macOS stubs."""
import argparse
from pathlib import Path
from foundation_test_support import build_foundation_module
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
MAIN = r'''
import Foundation

@main struct DiagnosticChecks {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        let id = UUID(uuidString: "62D55452-0E86-412F-8F2E-720773818FE8")!
        let original = HTTPHeaders([("Host", "fixture.invalid"), ("Content-Length", "0"),
                                    ("X-Test", "one"), ("X-Test", "two")])
        let sources: [DiagnosticHeaders.Source] = [.mapLocal, .mapRemote, .scripting, .breakpoint, .block]
        for source in sources {
            for enabled in [false, true] {
                var diagnostics = DiagnosticHeaders(requestID: id, enabled: enabled, version: "2.3.4")
                diagnostics.record(source)
                diagnostics.record(source)
                let request = HTTPRequestHead(method: "POST", target: "http://fixture.invalid/path", version: "HTTP/1.1",
                    headers: diagnostics.appending(to: original))
                let wire = try sanitizedRequestHead(head: request, originFormTarget: "/path", keepAlive: true)
                var parser = RequestHeadParser()
                let parsed = try parser.feed(wire)!
                check(parsed.headers.value(of: "X-ProxyMirror-Rule") == (enabled ? source.rawValue : nil),
                      "Wire request provenance follows the preference")
                check(parsed.headers.value(of: "X-ProxyMirror-Request-ID") == (enabled ? id.uuidString : nil),
                      "Wire request identity follows the preference")
                check(parsed.headers.value(of: "X-ProxyMirror-Version") == (enabled ? "2.3.4" : nil),
                      "Wire request has the build version only when enabled")
                check(parsed.headers.values(of: "X-Test") == ["one", "two"], "Application header order and repeats survive")
                check(parsed.headers.value(of: "Content-Length") == "0", "Diagnostics do not change message framing")
                let response = diagnostics.appending(to: HTTPHeaders([("Content-Length", "2")]))
                var responseWire = Data("HTTP/1.1 200 OK\r\n".utf8)
                responseWire.append(response.rawBytes)
                responseWire.append(Data("\r\nok".utf8))
                var responseParser = ResponseHeadParser()
                let head = try responseParser.feed(responseWire)!
                check(head.headers.value(of: "X-ProxyMirror-Rule") == (enabled ? source.rawValue : nil),
                      "Local and forwarded responses share request provenance")
                check(head.headers.value(of: "X-ProxyMirror-Request-ID") == parsed.headers.value(of: "X-ProxyMirror-Request-ID"),
                      "Request and response remain correlated")
                check(responseParser.trailing == Array("ok".utf8), "Wire body is unaffected")
            }
        }
        var empty = DiagnosticHeaders(requestID: id, enabled: true)
        check(empty.appending(to: original).rawBytes == original.rawBytes, "Unprocessed traffic stays unchanged")
        empty.record(.scripting)
        empty.record(.mapRemote)
        empty.record(.scripting)
        check(empty.appending(to: original).value(of: "X-ProxyMirror-Rule") == "Scripting, Map Remote",
              "Processing order is retained without duplicates")
        let user = HTTPHeaders([("x-proxymirror", "custom"), ("X-ProxyMirror-Rule", "origin"),
                               ("x-proxymirror-request-id", "origin-id"), ("X-PROXYMIRROR-VERSION", "origin-version")])
        check(empty.appending(to: user).rawBytes == user.rawBytes, "Every user-owned diagnostic field is preserved")
        let once = empty.appending(to: original)
        check(empty.appending(to: once).rawBytes == once.rawBytes, "Retries do not accumulate duplicate metadata")
        var unsafe = DiagnosticHeaders(requestID: id, enabled: true, version: "one\r\nInjected: two")
        unsafe.record(.mapLocal)
        check(unsafe.appending(to: original).value(of: "X-ProxyMirror-Version") == "development",
              "Invalid version metadata cannot inject a new wire field")

        let defaults = UserDefaults.standard
        let key = "proxy.appendDiagnosticHeaders"
        let saved = defaults.object(forKey: key)
        defer { if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) } }
        defaults.set(false, forKey: key)
        var offAtStart = DiagnosticHeaders(requestID: id)
        offAtStart.record(.mapLocal)
        defaults.set(true, forKey: key)
        check(offAtStart.appending(to: original).rawBytes == original.rawBytes,
              "Enabling the option midway does not expose diagnostics for an existing request")
        var onAtStart = DiagnosticHeaders(requestID: id)
        onAtStart.record(.mapLocal)
        defaults.set(false, forKey: key)
        check(onAtStart.appending(to: original).contains("X-ProxyMirror"),
              "An existing exchange keeps its diagnostic correlation until completion")
        print("PASS: \(checks) diagnostic and HTTP wire checks")
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default="swiftc")
    arguments = parser.parse_args()
    compiler = shutil.which(arguments.swiftc) or arguments.swiftc
    with tempfile.TemporaryDirectory(prefix="pm-diagnostic-headers-") as temporary:
        directory = Path(temporary)
        module_flags = build_foundation_module(compiler, directory)
        entry = directory / "DiagnosticChecks.swift"
        entry.write_text("@_exported import ProxyMirrorFoundation\n" + MAIN, encoding="utf-8")
        executable = directory / "diagnostic-checks"
        subprocess.run([compiler, "-swift-version", "5", "-module-cache-path", str(directory / "cache"),
                        *module_flags,
                        str(ROOT / "Sources/ProxyMirrorCore/Interception/DiagnosticHeaders.swift"),
                        str(entry), "-o", str(executable)], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=15)


if __name__ == "__main__":
    main()
