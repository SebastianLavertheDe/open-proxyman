import Foundation
import XCTest
@testable import ProxyMirrorFoundation

final class TarsBodyTests: XCTestCase {
    private let mime = "application/jce"
    // Independently recovered from the screenshot's 58-byte gzip response.
    private let response = Data(base64Encoded: "AQDIFg8xMTMuMTA4LjEyNC4xODcjAAABog0yRiw2B3N1Y2Nlc3M=")!

    private func object(_ data: Data, contentType: String = "application/jce", unhinted: Bool = false) throws -> [String: Any] {
        let decoded = try XCTUnwrap(TarsBody.decodeIfTars(data, contentTypeHint: contentType, allowUnhinted: unhinted))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: decoded) as? [String: Any])
    }

    func testScreenshotResponseAndPresentationPipeline() throws {
        let result = try object(response, contentType: "application/octet-stream", unhinted: true)
        XCTAssertEqual((result["0"] as? NSNumber)?.intValue, 200)
        XCTAssertEqual(result["1"] as? String, "113.108.124.187")
        XCTAssertEqual((result["2"] as? NSNumber)?.int64Value, 1_795_517_728_300)
        XCTAssertEqual(result["3"] as? String, "success")
        let inspection = HTTPBodyInspection.inspect(response, contentType: "application/octet-stream", allowUnhintedTars: true)
        XCTAssertEqual(inspection.format, .tars)
        XCTAssertEqual(inspection.contentType, "application/json")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: inspection.data) as? NSDictionary, result as NSDictionary)
        XCTAssertEqual(response.count, 38)
    }

    func testConservativeDetectionPreservesOtherFormats() throws {
        XCTAssertNil(try TarsBody.decodeIfTars(response, contentTypeHint: "application/octet-stream"))
        for type in ["application/json", "text/plain", "application/protobuf", "image/png"] {
            XCTAssertNil(try TarsBody.decodeIfTars(response, contentTypeHint: type, allowUnhinted: true))
        }
        for data in [Data([0, 1]), Data("plain text".utf8), Data(#"{"already":"json"}"#.utf8), Data([0x0a, 3, 0x61, 0x62, 0x63])] {
            XCTAssertNil(try TarsBody.decodeIfTars(data, allowUnhinted: true))
        }
        let messagePack = Data([0x81, 0xa1, 0x6b, 1])
        let inspected = HTTPBodyInspection.inspect(messagePack, contentType: "application/msgpack", allowUnhintedTars: true)
        XCTAssertEqual(inspected.format, .messagePack)
        XCTAssertEqual(String(decoding: inspected.data, as: UTF8.self), #"{"k":1}"#)
        let opaque = Data([0xff, 0x00, 0x88, 0x72])
        let original = HTTPBodyInspection.inspect(opaque, contentType: "application/octet-stream", allowUnhintedTars: true)
        XCTAssertNil(original.format)
        XCTAssertEqual(original.data, opaque)
    }

    func testNumericTypesExtendedTagsAndNonfiniteFloats() throws {
        let bytes: [UInt8] = [0x00, 0xff, 0x11, 0xff, 0xfe, 0x22, 0xff, 0xff, 0xff, 0xfd,
            0x33, 0x80, 0, 0, 0, 0, 0, 0, 0, 0x44, 0x3f, 0xc0, 0, 0,
            0x55, 0x7f, 0xf0, 0, 0, 0, 0, 0, 0, 0x6c, 0xfc, 0xff]
        let values = try object(Data(bytes))
        XCTAssertEqual((values["0"] as? NSNumber)?.intValue, -1)
        XCTAssertEqual((values["1"] as? NSNumber)?.intValue, -2)
        XCTAssertEqual((values["2"] as? NSNumber)?.intValue, -3)
        XCTAssertEqual((values["3"] as? NSNumber)?.int64Value, Int64.min)
        XCTAssertEqual((values["4"] as? NSNumber)?.doubleValue, 1.5)
        XCTAssertEqual((values["5"] as? [String: String])?["_float"], "Infinity")
        XCTAssertEqual((values["6"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((values["255"] as? NSNumber)?.intValue, 0)
    }

    func testCollectionsNestedStructAndBinaryValues() throws {
        let bytes: [UInt8] = [
            0x08, 0x00, 2, 0x00, 1, 0x16, 1, 0x61, 0x00, 1, 0x16, 1, 0x62,
            0x19, 0x00, 2, 0x00, 7, 0x0c,
            0x2a, 0x06, 2, 0x68, 0x69, 0x0b,
            0x3d, 0x00, 0x00, 3, 0, 0xff, 1,
            0x47, 0, 0, 0, 1, 0xff
        ]
        let result = try object(Data(bytes))
        let pairs = try XCTUnwrap((result["0"] as? [String: Any])?["_map"] as? [[Any]])
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs.compactMap { $0[1] as? String }, ["a", "b"])
        XCTAssertEqual((result["1"] as? [NSNumber])?.map(\.intValue), [7, 0])
        XCTAssertEqual((result["2"] as? [String: String])?["0"], "hi")
        XCTAssertEqual((result["3"] as? [String: String])?["_bytes"], "AP8B")
        XCTAssertEqual((result["4"] as? [String: String])?["_bytes"], "/w==")
    }

    func testMalformedCountsTagsAndUnterminatedStructs() {
        let malformed: [[UInt8]] = [
            [0x06, 3, 0x61], [0x0a, 0x0c], [0x0b], [0x0e], [0xf0],
            [0x0c, 0x0c], [0x1c, 0x0c], [0x09, 0x00, 0xff],
            [0x08, 0x00, 1, 0x1c, 0x1c], [0x09, 0x00, 1, 0x1c],
            [0x0d, 0x01, 0x0c], [0x0d, 0x00, 0x00, 2, 0xff],
            [0x09, 0x02, 0x7f, 0xff, 0xff, 0xff]
        ]
        for data in malformed {
            XCTAssertThrowsError(try TarsBody.decodeIfTars(Data(data), contentTypeHint: mime), "\(data)")
            XCTAssertNil(try? TarsBody.decodeIfTars(Data(data), allowUnhinted: true))
        }
    }

    func testDepthAndInputLimits() {
        let nested = Data(repeating: 0x0a, count: 66) + Data([0x0c]) + Data(repeating: 0x0b, count: 66)
        XCTAssertThrowsError(try TarsBody.decodeIfTars(nested, contentTypeHint: mime)) {
            XCTAssertEqual($0 as? TarsBody.DecodeError, .tooDeep)
        }
        XCTAssertThrowsError(try TarsBody.decodeIfTars(Data(repeating: 0, count: TarsBody.maxInputBytes + 1), contentTypeHint: mime)) {
            XCTAssertEqual($0 as? TarsBody.DecodeError, .tooLarge)
        }
    }

    func testByteArrayUsesByteBudgetInsteadOfCollectionElementBudget() throws {
        let length = 100_001
        let wire = Data([0x0d, 0, 0x02, 0, UInt8(length >> 16), UInt8((length >> 8) & 255), UInt8(length & 255)])
            + Data(repeating: 0xff, count: length)
        let values = try object(wire)
        let bytes = try XCTUnwrap((values["0"] as? [String: String])?["_bytes"])
        XCTAssertEqual(Data(base64Encoded: bytes)?.count, length)
    }

    func testEscapingCannotExceedOutputBudget() {
        let length = 200_000
        let wire = Data([0x07, 0, UInt8(length >> 16), UInt8((length >> 8) & 255), UInt8(length & 255)])
            + Data(repeating: 0, count: length)
        XCTAssertThrowsError(try TarsBody.decodeIfTars(wire, contentTypeHint: mime)) {
            XCTAssertEqual($0 as? TarsBody.DecodeError, .outputLimit)
        }
        let result = HTTPBodyInspection.inspect(wire, contentType: mime)
        XCTAssertEqual(result.issue, .outputLimit)
        XCTAssertEqual(result.data, wire)
        XCTAssertNil(result.format)
    }

    func testCancelledInspectionStopsWithoutPublishingJSON() async {
        let gate = DispatchSemaphore(value: 0)
        let input = response
        let worker = Task.detached {
            gate.wait()
            return try TarsBody.decodeIfTars(input, contentTypeHint: "application/jce")
        }
        worker.cancel(); gate.signal()
        do { _ = try await worker.value; XCTFail("Cancellation must interrupt inspection") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
