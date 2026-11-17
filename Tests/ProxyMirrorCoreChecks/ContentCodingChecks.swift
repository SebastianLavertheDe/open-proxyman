import Foundation
@testable import ProxyMirrorCore

/// G1：Content-Encoding 解码（gzip / zlib 包装 deflate / raw deflate / 组合与失败路径）
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
}

private func checkHTTPProtobuf(_ test: CoreAssertions) {
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

private enum ContentCodingFixtures {
    static func b64(_ base64: String) -> Data { Data(base64Encoded: base64)! }
}
