#!/usr/bin/env python3
"""Exercise real gzip decoding and binary-payload inspection, without desktop UI.

The screenshot response is recovered byte-for-byte, including its gzip CRC.
Foundation and ContentCoding are production code; unused Brotli/Zstd platform
adapters abort if invoked. No captured headers or replay bytes are rewritten.
"""
import argparse
import gzip
from pathlib import Path
import shutil
import subprocess
import tempfile

from foundation_test_support import build_foundation_module

ROOT = Path(__file__).resolve().parents[1]
BOUNDARY = '''
import Foundation
enum BrotliBody {
    enum DecodeError: Error { case outputLimit }
    static func decode(_ data: Data, limit: Int, allowTruncatedOutput: Bool) throws -> Data {
        fatalError("Brotli is outside this gzip fixture")
    }
}
enum ZstdBody {
    static func decode(_ data: Data, limit: Int, allowTruncatedOutput: Bool) -> Result<Data, ContentCoding.DecodeError> {
        fatalError("Zstd is outside this gzip fixture")
    }
}
'''
MAIN = r'''
import Foundation
import ProxyMirrorFoundation
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }; checks += 1
}
let wire = Data(base64Encoded: "H4sIAAAAAAAC/2NkOCHGb2horGdoYKFnaGSiZ2hhrszAwLiI18hNx4y9uDQ5ObW4GAAXJUxMJgAAAA==")!
let captured = wire
check(wire.count == 58, "The screenshot fixture must retain all 58 captured bytes")
check(ContentCoding.inspectionEncodings(wire, declared: []) == ["gzip"], "Headerless gzip is recognized for inspection")
check(ContentCoding.inspectionEncodings(wire, declared: ["identity"]) == ["gzip"], "Identity does not hide a gzip application payload")
check(ContentCoding.inspectionEncodings(wire, declared: [" GZip, identity "]) == ["gzip"], "Explicit encoding normalization is preserved")
check(ContentCoding.inspectionEncodings(wire, declared: ["compress"]) == ["compress"], "Unknown explicit encodings are never overridden")
check(ContentCoding.inspectionEncodings(wire, declared: ["gzip", "br"]) == ["gzip", "br"], "Declared multilayer order is preserved")
check(ContentCoding.inspectionEncodings(Data([0x1f, 0x8b]), declared: []).isEmpty, "An incomplete magic does not claim gzip")
check(ContentCoding.inspectionEncodings(Data([0x1f, 0x8b, 0x01]), declared: []).isEmpty, "Unsupported gzip compression methods are not guessed")
check(ContentCoding.inspectionEncodings(Data([0x78, 0x9c, 0x03]), declared: []).isEmpty, "Headerless zlib/raw deflate is not guessed")
check(ContentCoding.decodeIfCompressed(wire, encodings: []) == nil, "Strict HTTP decoder semantics remain unchanged")
guard case .success(let decoded)? = ContentCoding.decodeIfCompressed(wire, encodings: ContentCoding.inspectionEncodings(wire, declared: [])) else {
    fatalError("The complete screenshot response must pass actual gzip checksum validation")
}
check(decoded.0.count == 38 && decoded.1 == "gzip", "The screenshot response decompresses to the 38-byte JCE document")
let inspected = HTTPBodyInspection.inspect(decoded.0, contentType: "application/octet-stream", allowUnhintedTars: true)
check(inspected.format == .tars && inspected.contentType == "application/json", "The same body pipeline returns readable Tars/JCE JSON")
let fields = try JSONSerialization.jsonObject(with: inspected.data) as! [String: Any]
check((fields["0"] as? NSNumber)?.intValue == 200 && fields["3"] as? String == "success", "Schema-free preview retains the screenshot's values")
check(Set(fields.keys) == Set(["0", "1", "2", "3"]), "Wire tag numbers are retained instead of invented business names")
check(wire == captured, "Inspection does not change bytes used by raw preview or replay")
check(HTTPBodyInspection.inspect(wire, contentType: "application/octet-stream", allowUnhintedTars: true).format == nil,
      "Compressed bytes never masquerade as an already-decoded application document")
for damaged in [Data(wire.dropLast()), Data(wire.dropLast(8)), wire + Data([0xff])] {
    guard case .failure(.invalidStream)? = ContentCoding.decodeIfCompressed(damaged, encodings: ["gzip"]) else {
        fatalError("Incomplete/corrupt containers must remain unavailable as decoded text")
    }
    checks += 1
}
if case .failure(.outputLimit)? = ContentCoding.decodeIfCompressed(wire, encodings: ["gzip"], maxOutputBytes: 16) { checks += 1 }
else { fatalError("Detected gzip must retain the existing decompression budget") }
let jsonWire = Data(base64Encoded: "__JSON_GZIP__")!
guard case .success(let json)? = ContentCoding.decodeIfCompressed(jsonWire, encodings: ContentCoding.inspectionEncodings(jsonWire, declared: [])) else {
    fatalError("Headerless JSON gzip must decode")
}
let jsonInspection = HTTPBodyInspection.inspect(json.0, contentType: "application/octet-stream", allowUnhintedTars: true)
check(jsonInspection.data == Data(#"{"message":"正常中文","ok":true}"#.utf8) && jsonInspection.format == nil,
      "Ordinary JSON remains JSON and is not relabelled as Tars")
let opaqueWire = Data(base64Encoded: "__OPAQUE_GZIP__")!
guard case .success(let opaque)? = ContentCoding.decodeIfCompressed(opaqueWire, encodings: ["gzip"]) else { fatalError("Opaque fixture must decode") }
let opaqueInspection = HTTPBodyInspection.inspect(opaque.0, contentType: "application/octet-stream", allowUnhintedTars: true)
check(opaqueInspection.data == opaque.0 && opaqueInspection.format == nil, "Genuine binary keeps its hex fallback after gzip")
print("PASS: \(checks) production body inspection checks (gzip + Tars/JCE)")
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default=shutil.which("swiftc"))
    parser.add_argument("--zlib-include", type=Path)
    parser.add_argument("--zlib-library", type=Path)
    args = parser.parse_args()
    if not args.swiftc:
        parser.error("swiftc is required")
    import base64
    main_source = MAIN.replace("__JSON_GZIP__", base64.b64encode(gzip.compress(
        '{"message":"正常中文","ok":true}'.encode(), mtime=0)).decode())
    main_source = main_source.replace("__OPAQUE_GZIP__", base64.b64encode(gzip.compress(bytes([255, 0, 136, 114]), mtime=0)).decode())
    with tempfile.TemporaryDirectory(prefix="pm-body-inspection-") as temporary:
        directory = Path(temporary)
        flags = build_foundation_module(args.swiftc, directory)
        shutil.copy2(ROOT / "Sources/ProxyMirrorCore/UI/Detail/ContentCoding.swift", directory / "ContentCoding.swift")
        (directory / "Boundary.swift").write_text(BOUNDARY)
        (directory / "main.swift").write_text(main_source)
        zlib = directory / "zlib"
        zlib.mkdir()
        (zlib / "shim.h").write_text("#include <zlib.h>\n")
        (zlib / "module.modulemap").write_text('module zlib [system] { header "shim.h" export * }\n')
        libraries = ["-Xlinker", str(args.zlib_library)] if args.zlib_library else ["-lz"]
        include = ["-I", str(args.zlib_include)] if args.zlib_include else []
        binary = directory / "body-inspection"
        subprocess.run([args.swiftc, "-swift-version", "5", *flags, "-I", str(zlib), *include, *libraries,
                        str(directory / "ContentCoding.swift"), str(directory / "Boundary.swift"),
                        str(directory / "main.swift"), "-o", str(binary)], cwd=directory, check=True, timeout=180)
        subprocess.run([str(binary)], cwd=directory, check=True, timeout=30)


if __name__ == "__main__":
    main()
