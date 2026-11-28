#!/usr/bin/env python3
"""Run production SSE parsing, issue identity, Codable and bilingual rendering.

The full Foundation module, SSEService, ContentCoding and error renderers are
compiled unchanged. Transaction is a minimal desktop adapter; macOS Brotli and
Zstd adapters trap if invoked. gzip/deflate use the real zlib decoder. The pacing
error enum is extracted unchanged; this does not test NIO queue scheduling or
the full Core GUI/Session/HAR adapters (covered by native SSEInspectionChecks).
"""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from foundation_test_support import build_foundation_module
from check_localization import load_strings

ROOT = Path(__file__).resolve().parents[1]
MAIN = r'''
import Foundation
import ProxyMirrorFoundation

var count = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message); count += 1
}
let english = ProcessInfo.processInfo.environment["PM_SETTINGS_LANGUAGE"] == "en"
let unsupported = SSEBodyStream(headers: HTTPHeaders([("Content-Encoding", "compress")]))
check(unsupported.issue?.code == "sse_encoding_unsupported", "Unsupported encoding retains its identity")
check(unsupported.issue?.arguments == ["compress"], "Encoding parameter remains original content")
check(unsupported.issue?.diagnostic == "Unsupported SSE Content-Encoding: compress. Captured bytes are available in Raw.", "Machine diagnostic stays English")
check(unsupported.issue?.localizedPresentation == (english ? "Unsupported SSE Content-Encoding: compress. Captured bytes are available in Raw." : "暂不支持 SSE Content-Encoding: compress。可在原文查看捕获字节。"), "Unsupported SSE presentation follows the application language")
let encoded = try JSONEncoder().encode(unsupported.snapshot)
let restored = try JSONDecoder().decode(SSEInspectionSnapshot.self, from: encoded)
check(restored.issue == unsupported.issue, "Snapshot round-trip retains code, arguments and diagnostic")
check(!String(decoding: encoded, as: UTF8.self).contains("暂不支持"), "New snapshots do not serialize localized presentation")
let transaction = Transaction()
transaction.applySSESnapshot(restored)
check(transaction.sseParseIssue == unsupported.issue, "Snapshot application retains typed inspection identity")

let deferred = SSEBodyStream(headers: HTTPHeaders([("Content-Encoding", "br")]))
check(deferred.deferred && deferred.issue?.code == "sse_decoding_deferred", "Supported deferred encoding retains its own informational identity")
check(deferred.issue?.arguments == ["br"], "Deferred encoding argument persists")
check(deferred.issue?.localizedPresentation == (english ? "The SSE br body will be parsed after it has finished receiving." : "SSE 的 br 正文将在接收完成后解析。"), "Deferred message follows the application language")
deferred.finish(complete: false)
check(!deferred.deferred && deferred.issue?.code == "sse_body_incomplete", "Failed deferred streams stop waiting")
let truncated = SSEBodyRecovery.recover(Data([1]), headers: HTTPHeaders([("Content-Encoding", "br")]), complete: false, truncated: true)
check(truncated.issue?.code == "sse_compressed_body_truncated", "Recovery preserves a truncated body's issue identity")
let failed = SSEBodyRecovery.recover(Data([1]), headers: HTTPHeaders([("Content-Encoding", "br")]), complete: false, truncated: false, failed: true)
check(failed.issue?.code == "sse_body_incomplete", "Recovery preserves incomplete connection identity")

let first = Data(base64Encoded: "H4sIAAAAAAAAA0pJLEm0UkjLLCou4eICAAAA//8=")!
let last = Data(base64Encoded: "SwFzilOT8/NSuLgAaL6WWhsAAAA=")!
let gzipHeaders = HTTPHeaders([("Content-Encoding", "gzip")])
let valid = SSEBodyStream(headers: gzipHeaders)
for byte in first { valid.append(CollectionOfOne(byte)) }
check(valid.snapshot.events.map(\.data) == ["first"], "Production zlib emits an event before EOF")
valid.append(last); valid.finish()
check(valid.snapshot.events.map(\.data) == ["first", "second"] && valid.issue == nil, "Valid incremental gzip behavior is preserved")
let recovered = SSEBodyRecovery.recover(first + last, headers: gzipHeaders, complete: true, truncated: false)
check(recovered.events.map(\.data) == ["first", "second"] && recovered.issue == nil, "Actual ContentCoding recovers gzip SSE")
let incomplete = SSEBodyStream(headers: gzipHeaders)
incomplete.append(first); incomplete.finish()
check(incomplete.issue?.code == "sse_compressed_body_incomplete", "Incomplete gzip reports a typed issue")
var corrupt = first + last; corrupt[corrupt.count - 8] ^= 1
let invalid = SSEBodyStream(headers: gzipHeaders); invalid.append(corrupt)
check(invalid.issue?.code == "sse_compressed_body_invalid", "Checksum failure reports a typed issue")
let oversized = SSEBodyStream(headers: HTTPHeaders())
oversized.append(Data(repeating: 0, count: ContentCoding.maxDecodedBytes + 1))
check(oversized.issue?.code == "sse_body_output_limit", "SSE output limit retains its own typed issue")

let legacy: [(String, String, [String])] = [
    ("SSE 的 br 正文将在接收完成后解析。", "sse_decoding_deferred", ["br"]),
    ("暂不支持 SSE Content-Encoding: compress。可在原文查看捕获字节。", "sse_encoding_unsupported", ["compress"]),
    ("SSE 正文超过 32 MiB 解析上限，后续事件未解析。", "sse_body_output_limit", []),
    ("连接已结束，未完整接收 SSE 压缩正文，无法恢复事件。", "sse_body_incomplete", []),
    ("SSE 压缩正文不完整，已显示可恢复的事件。", "sse_compressed_body_incomplete", []),
    ("无法初始化 SSE 压缩解码。", "sse_decoder_initialization_failed", []),
    ("SSE 压缩正文包含多余数据。", "sse_compressed_body_extra_data", []),
    ("SSE 压缩正文损坏，已显示可恢复的事件。", "sse_compressed_body_invalid", []),
    ("SSE 压缩正文已截断，无法完整解码。", "sse_compressed_body_truncated", []),
    ("SSE 解压正文超过 32 MiB。", "sse_compressed_body_output_limit", []),
    ("无法解码 SSE 压缩正文。可在原文查看捕获字节。", "sse_decode_failed", []),
    ("没有可解码的 SSE 正文。", "sse_no_decodable_body", []),
]
for (message, code, arguments) in legacy {
    let bytes = try JSONSerialization.data(withJSONObject: ["events": [], "truncated": false, "deferred": false, "issue": message])
    let issue = try JSONDecoder().decode(SSEInspectionSnapshot.self, from: bytes).issue!
    check(issue.code == code && issue.arguments == arguments, "Known legacy SSE text restores its issue identity")
    check(issue.diagnostic == message, "Legacy diagnostic content is retained")
    check(issue.localizedPresentation == OperationIssue.restored(code: code, arguments: arguments, diagnostic: "Wrong").localizedPresentation,
          "Known legacy SSE text uses the current presentation resources")
}
let unknown = "external decoder diagnostic / 原文"
let bytes = try JSONSerialization.data(withJSONObject: ["events": [], "truncated": false, "deferred": false, "issue": unknown])
let external = try JSONDecoder().decode(SSEInspectionSnapshot.self, from: bytes)
check(external.issue?.localizedPresentation == unknown, "Unknown legacy diagnostics remain verbatim")
let future = SSEInspectionSnapshot(events: [], issue: CapturedFailure(code: "future_issue", arguments: ["value"], diagnostic: unknown))
let futureCopy = try JSONDecoder().decode(SSEInspectionSnapshot.self, from: JSONEncoder().encode(future))
check(futureCopy.issue == future.issue && futureCopy.issue?.localizedPresentation == unknown, "Unknown typed identities remain forward compatible")
let pacing = NetworkFailure.capture(BytePacingQueue.QueueError.capacityExceeded)
check(pacing.code == "network_pacing_capacity_exceeded", "Pacing errors are captured as known own errors")
check(pacing.diagnostic == "The network throttling buffer is full.", "Pacing diagnostic is stable")
check(pacing.localizedPresentation == (english ? "The network throttling buffer is full." : "弱网限速缓冲已满。"), "Pacing presentation follows the UI language")
print("SSE issues: \(count) checks passed (\(english ? "en" : "zh-Hans"))")
'''

BOUNDARY = r'''
import Foundation
import ProxyMirrorFoundation
final class Transaction {
    enum State { case completed, failed }
    var sseEvents: [SSEEvent] = []
    var sseEventsTruncated = false
    var sseParseIssue: CapturedFailure?
    var sseDecodingDeferred = false
    var isSSE = true
    var responseBody = Data()
    var responseHeaders = HTTPHeaders()
    var responseBodyComplete = false
    var responseTruncated = false
    var state = State.completed
}
enum BrotliBody {
    enum DecodeError: Error { case outputLimit }
    static func decode(_ data: Data, limit: Int, allowTruncatedOutput: Bool) throws -> Data {
        fatalError("macOS Brotli decoding is outside this fixture")
    }
}
enum ZstdBody {
    static func decode(_ data: Data, limit: Int, allowTruncatedOutput: Bool) -> Result<Data, ContentCoding.DecodeError> {
        fatalError("Zstd decoding is outside this fixture")
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default=shutil.which("swiftc"))
    parser.add_argument("--zlib-include", type=Path, help="Optional extracted zlib development headers")
    parser.add_argument("--zlib-library", type=Path, help="Optional full path to the zlib shared library")
    args = parser.parse_args()
    if not args.swiftc:
        parser.error("swiftc is required")
    with tempfile.TemporaryDirectory(prefix="pm-sse-issues-") as temporary:
        directory = Path(temporary)
        flags = build_foundation_module(args.swiftc, directory)
        sources = directory / "SSEChecks"
        sources.mkdir()
        relative_sources = ["Proxy/SSEService.swift", "UI/Detail/ContentCoding.swift",
                            "System/LocalizedErrorPresentation.swift", "System/NetworkFailure.swift",
                            "System/GeneratedOperationIssues.swift", "System/GeneratedModelOperationIssues.swift",
                            "Localization/AppLanguage.swift", "Localization/LocalizationResources.swift",
                            "Localization/LocalizationContext.swift", "UI/PresentationLocalization.swift",
                            "Localization/Generated/Strings.swift", "Localization/Generated/EnglishFallbacks.swift"]
        for relative in relative_sources:
            shutil.copy2(ROOT / "Sources/ProxyMirrorCore" / relative, sources / Path(relative).name)
        (sources / "Boundary.swift").write_text(BOUNDARY)
        pacing = (ROOT / "Sources/ProxyMirrorCore/Proxy/BytePacingQueue.swift").read_text()
        error_enum = pacing[pacing.index("    enum QueueError:"):pacing.index("    private struct Pending")]
        (sources / "PacingError.swift").write_text("import Foundation\nfinal class BytePacingQueue {\n" + error_enum + "}\n")
        (sources / "main.swift").write_text("@_exported import ProxyMirrorFoundation\n" + MAIN)
        zlib = directory / "zlib"
        zlib.mkdir()
        (zlib / "shim.h").write_text("#include <zlib.h>\n")
        (zlib / "module.modulemap").write_text('module zlib [system] { header "shim.h" export * }\n')
        resources = directory / "Resources.bundle"
        shutil.copytree(ROOT / "Sources/ProxyMirrorCore/Resources", resources)
        if sys.platform != "darwin":
            for strings in resources.rglob("*.strings"):
                strings.write_bytes(plistlib.dumps(load_strings(strings)))
        executable = directory / "sse-issues"
        zlib_flags = ["-I", str(args.zlib_include)] if args.zlib_include else []
        zlib_flags += ["-Xlinker", str(args.zlib_library)] if args.zlib_library else ["-lz"]
        subprocess.run([args.swiftc, "-swift-version", "5", *flags, "-I", str(zlib), *zlib_flags,
                        *map(str, sorted(sources.glob("*.swift"))), "-o", str(executable)],
                       cwd=directory, check=True, timeout=180)
        for language in ("en", "zh-Hans"):
            environment = dict(os.environ, PM_SETTINGS_LANGUAGE=language, PM_LOCALIZATION_RESOURCE_DIR=str(resources))
            subprocess.run([str(executable)], cwd=directory, env=environment, check=True, timeout=30)
        if sys.platform != "darwin":
            print("BOUNDARY: Core Transaction/GUI/Session/HAR and Brotli/Zstd remain native checks; zlib and full Foundation are real")


if __name__ == "__main__":
    main()
