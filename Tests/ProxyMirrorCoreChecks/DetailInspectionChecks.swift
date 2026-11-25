import Foundation
@testable import ProxyMirrorCore

@MainActor
func checkDetailInspection(_ test: CoreAssertions) {
    let tarsWire = Data(base64Encoded: "H4sIAAAAAAAC/2NkOCHGb2horGdoYKFnaGSiZ2hhrszAwLiI18hNx4y9uDQ5ObW4GAAXJUxMJgAAAA==")!
    if case .success(let decoded)? = ContentCoding.decodeIfCompressed(tarsWire,
        encodings: ContentCoding.inspectionEncodings(tarsWire, declared: [])) {
        let body = HTTPBodyInspection.inspect(decoded.0, contentType: "application/octet-stream", allowUnhintedTars: true)
        test.equal(body.format, .tars, "Screenshot gzip/JCE response reaches the shared application-payload inspector")
        test.expect(BodyContentView.isJSON(data: body.data, contentType: body.contentType)
            && !BodyContentView.isBinary(data: body.data, contentType: body.contentType),
            "Decoded JCE uses the actual text/JSON tree rendering decision instead of Hex")
        let object = (try? JSONSerialization.jsonObject(with: body.data)) as? [String: Any]
        test.equal((object?["0"] as? NSNumber)?.intValue, 200, "Screenshot JCE numeric field is preserved")
        test.equal(object?["3"] as? String, "success", "Screenshot JCE string field is readable")
    } else { test.expect(false, "Headerless screenshot gzip must decode in the detail path") }
    test.expect(BodyContentView.isBinary(data: tarsWire, contentType: "application/octet-stream"),
                "Raw captured gzip remains binary for the captured-bytes toggle")
    let captured = Data([0x81, 0xa1, 0x6b, 0x01])
    let inspected = MessagePackBody.inspect(captured, contentType: "application/msgpack")
    test.equal(inspected.data, Data("{\"k\":1}".utf8), "MessagePack inspection produces the decoded JSON bytes")
    test.equal(inspected.contentType, "application/json", "MessagePack inspection passes a JSON content type to body and raw previews")
    test.expect(inspected.decoded && !BodyContentView.isBinary(data: inspected.data, contentType: inspected.contentType),
                "Decoded MessagePack uses readable JSON instead of a hex dump of JSON bytes")
    let corrupt = MessagePackBody.inspect(Data([0x81]), contentType: "application/msgpack")
    test.expect(!corrupt.decoded && corrupt.contentType == "application/msgpack",
                "An incomplete MessagePack capture remains binary instead of claiming successful decoding")
    let timestamp = Data(base64Encoded: "gaF01/8dbzRUZVPxAA==")!
    let decodedTimestamp = MessagePackBody.decodeIfMessagePack(timestamp, contentTypeHint: "application/msgpack")
    test.equal(decodedTimestamp.map { String(decoding: $0, as: UTF8.self) }, "{\"t\":\"2023-11-14T22:13:20Z\"}",
               "MessagePack timestamp64 reads the 34-bit seconds and 30-bit nanoseconds in their specified positions")
    let ext32 = Data([0xc9, 0, 0, 0, 1, 7, 42])
    test.equal(MessagePackBody.decodeIfMessagePack(ext32, contentTypeHint: "application/msgpack")
        .map { String(decoding: $0, as: UTF8.self) }, "{\"_ext\":7,\"data\":\"Kg==\"}", "MessagePack ext32 consumes its payload")

    test.equal(JSONTreeAvailability.unavailableReason(bytes: 256 * 1024, complete: true, truncated: false), nil,
               "A JSON tree at the supported input boundary remains enabled")
    test.expect(JSONTreeAvailability.unavailableReason(bytes: 256 * 1024 + 1, complete: true, truncated: false)?.contains("256 KiB") == true,
                "Oversized JSON trees expose the actual input limit")
    test.expect(JSONTreeAvailability.unavailableReason(bytes: 10, complete: false, truncated: false) != nil &&
                JSONTreeAvailability.unavailableReason(bytes: 10, complete: true, truncated: true) != nil,
                "Incomplete and truncated bodies explain why the JSON tree cannot be expanded")

    let text = String(repeating: "a", count: 500) + "needle after the row preview"
    let frame = WSFrame(direction: .downstream, opcode: 1, fin: true, masked: false,
                        payload: Data(text.utf8), rsv1: false)
    test.expect(!frame.previewText.contains("needle"), "WS regression fixture places the search term beyond the row preview")
    let result = WSMessageSearch.find("needle", in: [frame], headers: HTTPHeaders())
    test.equal(result.ids, [frame.id], "WS search matches the complete available message after the first 500 characters")
    test.equal(WSMessageSearch.find("absent", in: [frame], headers: HTTPHeaders()).ids, [], "WS search excludes nonmatching full messages")

    let headers = HTTPHeaders([("Sec-WebSocket-Extensions", "permessage-deflate")])
    let encoder = WebSocketDeflate.Encoder(WebSocketDeflate(windowBits: 15, noContextTakeover: false))
    if let firstBytes = encoder.encode(Data(String(repeating: "history", count: 1000).utf8)),
       let bytes = encoder.encode(Data((String(repeating: "history", count: 50_000) + "dictionaryneedle").utf8)) {
        let first = WSFrame(direction: .downstream, opcode: 1, fin: true, masked: false, payload: firstBytes, rsv1: true)
        let second = WSFrame(direction: .downstream, opcode: 1, fin: true, masked: false, payload: bytes, rsv1: true,
                             decompressedPreview: Data("history".utf8), decompressedPreviewTruncated: true)
        let compressed = WSMessageSearch.find("dictionaryneedle", in: [first, second], headers: headers)
        test.equal(compressed.ids, [second.id], "WS full-text search replays the sender's deflate dictionary beyond a truncated preview")
        test.equal(compressed.unavailable, 0, "Fully recoverable compressed WS messages are not silently excluded")
    } else {
        test.expect(false, "Construct the context-dependent WS search fixture")
    }

    let tx = Transaction(startedAt: Date(timeIntervalSince1970: 100))
    tx.tConnected = tx.startedAt.addingTimeInterval(1)
    tx.tHeaderAt = tx.startedAt.addingTimeInterval(2)
    tx.duration = 5
    tx.state = .failed
    test.equal(TimingChartView.endDate(for: tx).timeIntervalSince(tx.startedAt), 5,
               "Failed response timing includes time spent downloading before the failure")
}
