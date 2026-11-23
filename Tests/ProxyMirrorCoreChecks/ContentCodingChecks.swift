import Foundation
@testable import ProxyMirrorCore

/// G1：Content-Encoding 解码（gzip / zlib 包装 deflate / raw deflate / 组合与失败路径）
@MainActor
func checkContentCoding(_ test: CoreAssertions) {
    let unit = "ondehä localization 汉字 {\"k\": [1,2,3], \"msg\": \"hello gzip deflate 中文\"}"
    let plain = Data(String(repeating: unit, count: 20).utf8)

    let fixtures: [(Data, [String], String)] = [
        (ContentCodingFixtures.b64("H4sIABad9moC/8vPS0nNOLxEISc/OTEnsyqxJDM/T+HZxs6na6crVCtlK1kpRBvqGOkYx+ooKOUWpwP5ShmpOTn5CulVmQUKKalpOYklqQpPdqx9Nq1dqTZ/1LRR00ZNGzVt1LQhbhoAES141BgGAAA="), ["gzip"], "gzip"),
        (ContentCodingFixtures.b64("H4sICBad9moC/3NhbXBsZS5qc29uAMvPS0nNOLxEISc/OTEnsyqxJDM/T+HZxs6na6crVCtlK1kpRBvqGOkYx+ooKOUWpwP5ShmpOTn5CulVmQUKKalpOYklqQpPdqx9Nq1dqTZ/1LRR00ZNGzVt1LQhbhoAES141BgGAAA="), ["gzip"], "gzip + FNAME 头"),
        (ContentCodingFixtures.b64("eJzLz0tJzTi8RCEnPzkxJ7MqsSQzP0/h2cbOp2unK1QrZStZKUQb6hjpGMfqKCjlFqcD+UoZqTk5+QrpVZkFCimpaTmJJakKT3asfTatXak2f9S0UdNGTRs1bdS0IW4aAKVgY4c="), ["deflate"], "zlib 包装 deflate"),
        (ContentCodingFixtures.b64("y89LSc04vEQhJz85MSezKrEkMz9P4dnGzqdrpytUK2UrWSlEG+oY6RjH6igo5RanA/lKGak5OfkK6VWZBQopqWk5iSWpCk92rH02rV2pNn/UtFHTRk0bNW3UtCFuGgA="), ["deflate"], "raw deflate"),
    ]
    for (data, encodings, label) in fixtures {
        let result = ContentCoding.decodeIfCompressed(data, encodings: encodings)
        guard case .success(let decoded)? = result else {
            test.expect(false, "\(label) 解码应成功（实际 \(String(describing: result))）")
            continue
        }
        test.equal(decoded.0, plain, "\(label) 解码还原原文")
        test.equal(decoded.1, encodings[0], "\(label) 编码标签")
    }

    let gzip = fixtures[0].0
    if case .failure(.outputLimit)? = ContentCoding.decodeIfCompressed(gzip, encodings: ["gzip"], maxOutputBytes: 12) {
        test.expect(true, "Small inspection limits stop decoded output")
    } else { test.expect(false, "Small inspection limits must reject full-body decoding") }
    if case .success(let prefix)? = ContentCoding.decodeIfCompressed(
        gzip, encodings: ["gzip"], maxOutputBytes: 12, allowTruncatedOutput: true) {
        test.equal(prefix.0, Data(plain.prefix(12)), "Prefix inspection returns bounded decoded bytes")
    } else { test.expect(false, "Bounded prefix decoding should succeed") }
    if case .success(let decoded)? = ContentCoding.decodeIfCompressed(gzip + gzip, encodings: ["gzip"]) {
        test.equal(decoded.0, plain + plain, "拼接 gzip 成员逐个还原")
    } else {
        test.expect(false, "拼接 gzip 成员应能解码")
    }
    var badCRC = gzip
    badCRC[badCRC.count - 8] ^= 0x01
    if case .failure(.invalidStream)? = ContentCoding.decodeIfCompressed(badCRC, encodings: ["gzip"]) {
        test.expect(true, "gzip 校验值错误时保留原始正文")
    } else {
        test.expect(false, "gzip 校验值错误时应拒绝解码")
    }

    // 无编码：返回 nil（不压缩）
    test.expect(ContentCoding.decodeIfCompressed(plain, encodings: []) == nil, "空编码返回 nil")
    test.expect(ContentCoding.decodeIfCompressed(plain, encodings: ["identity"]) == nil, "identity 返回 nil")

    // 不支持的编码
    if case .failure(.unsupported(let list))? = ContentCoding.decodeIfCompressed(ContentCodingFixtures.b64("H4sIABad9moC/8vPS0nNOLxEISc/OTEnsyqxJDM/T+HZxs6na6crVCtlK1kpRBvqGOkYx+ooKOUWpwP5ShmpOTn5CulVmQUKKalpOYklqQpPdqx9Nq1dqTZ/1LRR00ZNGzVt1LQhbhoAES141BgGAAA="), encodings: ["zstd"]) {
        test.equal(list, ["zstd"], "zstd 报 unsupported 且列出编码")
    } else {
        test.expect(false, "zstd 应报 unsupported")
    }

    // 损坏流
    if case .failure(.invalidStream)? = ContentCoding.decodeIfCompressed(ContentCodingFixtures.b64("H4sIABad9moC/8vPS0nNOLxEISc/OTEnsyqxJDM/T+HZxs6na6crVA=="), encodings: ["gzip"]) {
        test.expect(true, "截断 gzip 报 invalidStream")
    } else {
        test.expect(false, "截断 gzip 应报 invalidStream")
    }

    // 组合编码 gzip 声明但实际是 zlib 包装：按容器探测兜底
    if case .success(let decoded)? = ContentCoding.decodeIfCompressed(ContentCodingFixtures.b64("eJzLz0tJzTi8RCEnPzkxJ7MqsSQzP0/h2cbOp2unK1QrZStZKUQb6hjpGMfqKCjlFqcD+UoZqTk5+QrpVZkFCimpaTmJJakKT3asfTatXak2f9S0UdNGTRs1bdS0IW4aAKVgY4c="), encodings: ["gzip"]) {
        test.equal(decoded.0, plain, "声明与实际不符时按容器格式兜底解码")
    } else {
        test.expect(false, "容器探测兜底应成功")
    }
    checkHTTPProtobuf(test)
    checkCursorBodies(test)
    checkJSONBodyPresentation(test)
}

@MainActor
private func checkJSONBodyPresentation(_ test: CoreAssertions) {
    // Independent gzip fixture shaped like a Feishu pc_log request; no captured user data.
    let wire = ContentCodingFixtures.b64("H4sIAAAAAAACA4uuVkpJLElUsqpWSiwoiC9LLSrOzM9TslKy0DPXMzRU0lFKTixJTc8vqgSKFaQWpQFFUstS80ri8xJzU4FiIF35eanxuZl5pSWp8ckFpfGlxYnpqUB1uanFYJaV0rOG5S+a9z7fPf/FuoVKtbWxAFARGDp2AAAA")
    let plain = Data(#"[{"data":{"app_version":"8.7.11","category":"perf","event_name":"app_one_minute_cpu_usage","message":"性能统计"}}]"#.utf8)
    guard case .success(let decoded)? = ContentCoding.decodeIfCompressed(wire, encodings: ["gzip"]) else {
        test.expect(false, "Gzipped Feishu-style JSON decodes before presentation")
        return
    }
    test.equal(decoded.0, plain, "Gzipped telemetry decodes to the expected JSON")
    for mime in ["application/octet-stream", "Application/Octet-Stream; charset=binary",
                 "application/x-telemetry", "application/json", ""] {
        test.expect(BodyContentView.isJSON(data: decoded.0, contentType: mime),
                    "Decoded JSON enables pretty, tree and query presentation for \(mime)")
        test.expect(!BodyContentView.isBinary(data: decoded.0, contentType: mime),
                    "Decoded JSON uses text instead of hex for \(mime)")
        test.expect(BodyContentView.isBinary(data: wire, contentType: mime),
                    "Original gzip bytes retain binary presentation for \(mime)")
    }
    let object = Data(" \r\n\t{\"message\":\"hello\"}".utf8)
    test.expect(BodyContentView.isJSON(data: object, contentType: "application/octet-stream") &&
                !BodyContentView.isBinary(data: object, contentType: "application/octet-stream"),
                "JSON object detection ignores leading whitespace")
    let incomplete = Data("{\"message\":".utf8)
    test.expect(!BodyContentView.isBinary(data: incomplete, contentType: "application/octet-stream"),
                "An uncompressed JSON prefix can display as text while receiving")
    let splitUTF8 = Data(("{\"message\":\"" + String(repeating: "a", count: 1011) + "中文\"}").utf8)
    test.expect(!BodyContentView.isBinary(data: splitUTF8, contentType: "application/octet-stream"),
                "JSON sniffing preserves text when the preview ends inside a UTF-8 scalar")
    for bytes in [Data([0, 255, 1]), object + Data([0]), object + Data([255])] {
        test.expect(BodyContentView.isBinary(data: bytes, contentType: "application/octet-stream"),
                    "Control bytes and invalid UTF-8 retain the binary fallback")
    }
    test.expect(BodyContentView.isBinary(data: Data("opaque".utf8), contentType: "application/octet-stream"),
                "Printable binary content is not assumed to be JSON")
}

private func checkHTTPProtobuf(_ test: CoreAssertions) {
    test.expect(HTTPProtobuf.matches(contentType: "Application/Proto; charset=binary", query: "", isRequest: true) &&
                HTTPProtobuf.matches(contentType: "application/proto", query: "", isRequest: false),
                "Connect unary requests and responses select the HTTP Protobuf decoder")
    test.expect(!HTTPProtobuf.matches(contentType: "application/connect+proto", query: "", isRequest: true),
                "Connect streaming frames are not parsed as an unframed HTTP Protobuf message")
    test.expect(HTTPProtobuf.matches(contentType: "Application/X-Google-Protobuf; charset=binary", query: "", isRequest: false),
                "HTTP Protobuf recognizes Google content type")
    test.expect(HTTPProtobuf.matches(contentType: "application/octet-stream", query: "x=1&alt=proto", isRequest: false),
                "alt=proto selects the response parser for binary HTTP content")
    test.expect(!HTTPProtobuf.matches(contentType: "application/json", query: "alt=proto", isRequest: false) &&
                !HTTPProtobuf.matches(contentType: "", query: "alt=proto", isRequest: true),
                "alt=proto preserves explicit JSON responses and request formats")

    let fixture = ContentCodingFixtures.b64("H4sIAAAAAAAC/+NgFhJyDPBUyE6tVMjLL1EoS8zJTNGTKuDSKKksSNVLz89Pz0lNLMgs1kvOz9WHcPWKCpL1XIuK8os889LyhVy4+IEmxHu7RsZ7+oU5+ni6CPGh6pNS5GIvTi0qy0xOFRJLy6woKS1CN1oqgEufgI0++clAx1WlpvimFhcnpqcKyXKxpubphgYLiYQWpyokQtyuAPWNHgCLUrom2gAAAA==")
    if case .success(let decoded)? = ContentCoding.decodeIfCompressed(fixture, encodings: ["gzip"]),
       let rendered = try? GRPCProtobuf.describeHTTP(decoded.0, isError: true) {
        test.equal(rendered.type, "google.rpc.Status", "HTTP Protobuf recognizes a gzipped Google RPC status")
        test.expect(rendered.text.contains("code [1]: 3") && rendered.text.contains("message [2]: \"API key not valid.\""),
                    "HTTP Protobuf renders the error code and message")
        test.expect(rendered.text.contains("reason [1]: \"API_KEY_INVALID\"") &&
                    rendered.text.contains("value [2]: \"fixture.googleapis.com\"") &&
                    rendered.text.contains("locale [1]: \"en-US\""),
                    "HTTP Protobuf unpacks known error detail messages")
    } else {
        test.expect(false, "HTTP gzip decoding hands the resulting payload to the Protobuf parser")
    }
    let generic = try? GRPCProtobuf.describeHTTP(Data([18, 2, 111, 107]), isError: false)
    test.expect(generic?.type == nil && generic?.text == "#2: \"ok\"", "Unknown HTTP Protobuf shows field numbers and readable strings")
    test.rejects(try GRPCProtobuf.describeHTTP(Data([18, 5, 111, 107]), isError: false),
                 with: GRPCInspectionError.self, "HTTP Protobuf rejects an incomplete field")
}

@MainActor
private func checkCursorBodies(_ test: CoreAssertions) {
    // Independent Python gzip/protobuf fixtures model the two captured formats.
    let compressedProto = ContentCodingFixtures.b64("H4sIAAAAAAACA+NomHF0/iNDIf60zIqS0qJU3YKi/OTU4mIpBy4DfceCgpzM5MSSzPy8Yn03iAK9xIICfef8vJLUvJJifd/EZP9gmJSAlhQXF1t5flF2apEAOwBhdvwqWgAAAA==")
    if case .success(let decoded)? = ContentCoding.decodeIfCompressed(compressedProto, encodings: ["gzip"]),
       let rendered = try? GRPCProtobuf.describeHTTP(decoded.0, isError: false) {
        test.expect(rendered.type == nil && rendered.text.contains("#1: 1710000000000") &&
                    rendered.text.contains("#2: \"fixture-process\""),
                    "Gzipped application/proto shows field numbers, integers and text")
        test.expect(rendered.text.contains("#3: {") && rendered.text.contains("#2: 42") &&
                    rendered.text.contains("/Applications/Fixture.app/Contents/MacOS/Fixture") &&
                    rendered.text.contains("#1: \"worker\"") && rendered.text.contains("#2: 7"),
                    "Schema-free HTTP Protobuf expands nested process metrics")
    } else {
        test.expect(false, "Gzipped application/proto decodes to readable Protobuf fields")
    }

    let opaque = try? GRPCProtobuf.describeHTTP(Data([10, 3, 0, 255, 1]), isError: false)
    test.equal(opaque?.text, "#1: 3 字节 · 00 ff 01", "Opaque Protobuf bytes remain binary")
    var deep = Data([8, 1])
    for _ in 0..<20 { deep = Data([10, UInt8(deep.count)]) + deep }
    let limited = try? GRPCProtobuf.describeHTTP(deep, isError: false)
    test.expect(limited?.text.contains("嵌套层级上限") == true, "Inferred Protobuf messages obey the nesting limit")

    let compressedEnvelope = ContentCodingFixtures.b64("H4sIAAAAAAACA6tWSi1LzSuJz0xRslIyMDQyNjE1M7ewTExKTklNQ+cr1XJVK5VUFqQC1YK1Keko5aTmpZdkKFmZGoMkc1OLixPTQfIv1m9/trHp6fZNT9f1POuYAFRZkJNYkpZflAuUzEosSyxOLsosKAEaCQCjrLI4gwAAAA==")
    let envelope = ContentCodingFixtures.b64("eyJldmVudF9pZCI6IjAxMjM0NTY3ODlhYmNkZWYwMTIzNDU2Nzg5YWJjZGVmIn0KeyJ0eXBlIjoiZXZlbnQiLCJsZW5ndGgiOjUzfQp7Im1lc3NhZ2UiOiLor7fmsYLlt7LlrozmiJAiLCJwbGF0Zm9ybSI6ImphdmFzY3JpcHQifQo=")
    let mime = "application/x-sentry-envelope"
    if case .success(let decoded)? = ContentCoding.decodeIfCompressed(compressedEnvelope, encodings: ["gzip"]) {
        test.equal(decoded.0, envelope, "Sentry gzip preserves the envelope lines and UTF-8 payload")
        test.expect(!BodyContentView.isBinary(data: decoded.0, contentType: mime),
                    "Decoded Sentry envelopes use a text preview instead of hex")
        let preview = BodyPreviewRenderer.renderAll(decoded.0, format: .text)
        test.expect(preview?.contains("请求已完成") == true && preview?.contains("\"type\":\"event\"") == true,
                    "Raw text preview displays the decompressed Sentry event")
    } else {
        test.expect(false, "Gzipped Sentry envelope decodes")
    }
    test.expect(BodyContentView.isBinary(data: compressedEnvelope, contentType: mime),
                "Captured gzip bytes remain available as a binary preview")
    test.expect(BodyContentView.isBinary(data: envelope + Data([0, 255]), contentType: mime),
                "A Sentry envelope containing binary data retains the hex fallback")
    if case .failure(.invalidStream)? = ContentCoding.decodeIfCompressed(compressedEnvelope.dropLast(4), encodings: ["gzip"]) {
        test.expect(true, "An incomplete gzip envelope cannot be presented as decoded text")
    } else {
        test.expect(false, "An incomplete gzip envelope must report a decoding failure")
    }
}

private enum ContentCodingFixtures {
    static func b64(_ base64: String) -> Data { Data(base64Encoded: base64)! }
}
