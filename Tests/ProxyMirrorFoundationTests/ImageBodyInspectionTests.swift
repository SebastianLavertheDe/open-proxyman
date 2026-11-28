import Foundation
import ProxyMirrorFoundation
import XCTest
#if canImport(ImageIO)
import ImageIO
#endif

final class ImageBodyInspectionTests: XCTestCase {
    // Complete 2 × 2 JPEG, including its scan and end marker.
    private let jpeg = Data(base64Encoded:
        "/9j/4AAQSkZJRgABAgAAAQABAAD//gAPTGF2YzYxLjMuMTAwAP/bAEMACAQEBAQEBQUFBQUFBgYGBgYGBgYGBgYGBgcHBwgICAcHBwYGBwcICAgICQkJCAgICAkJCgoKDAwLCw4ODhERFP/EAEwAAQEAAAAAAAAAAAAAAAAAAAAHAQEBAAAAAAAAAAAAAAAAAAAFBxABAAAAAAAAAAAAAAAAAAAAABEBAAAAAAAAAAAAAAAAAAAAAP/AABEIAAIAAgMBIgACEQADEQD/2gAMAwEAAhEDEQA/AI4Av4t//9k=")!

    func testJPEGWithMissingOrGenericMIMEKeepsItsOriginalBytes() {
        for type in ["", "application/octet-stream", " Binary/Octet-Stream ; charset=binary "] {
            let result = HTTPBodyInspection.inspect(jpeg, contentType: type)
            XCTAssertEqual(result.contentType, "image/jpeg", type)
            XCTAssertEqual(result.data, jpeg)
            XCTAssertNil(result.format)
            XCTAssertNil(result.issue)
        }
        // An APP0/JFIF segment is optional. Remove it but keep the JPEG scan intact.
        let withoutJFIF = Data(jpeg.prefix(2) + jpeg.dropFirst(20))
        let result = HTTPBodyInspection.inspect(withoutJFIF, contentType: "", allowUnhintedTars: true)
        XCTAssertEqual(result.contentType, "image/jpeg")
        XCTAssertEqual(result.data, withoutJFIF)
    }

    func testPNGAndGIFAndWebPSignatures() throws {
        let images = [
            ("image/png", "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAACXBIWXMAAAABAAAAAQBPJcTWAAAAD0lEQVR4nGNgYPgLRmAKABfGA/UJtwtdAAAAAElFTkSuQmCC"),
            ("image/gif", "R0lGODdhAQABAIAAAAAAAP///ywAAAAAAQABAAACAkQBADs="),
            ("image/gif", "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"),
            ("image/webp", "UklGRjgAAABXRUJQVlA4ICwAAACQAQCdASoCAAIAAgA0JaACdLoAA5gA/vmTb/+QH/+QH/+QH/8gP+IXexhQAA=="),
        ]
        for (mime, encoded) in images {
            let image = try XCTUnwrap(Data(base64Encoded: encoded))
            let result = HTTPBodyInspection.inspect(image, contentType: "application/octet-stream", allowUnhintedTars: true)
            XCTAssertEqual(result.contentType, mime)
            XCTAssertEqual(result.data, image)
            XCTAssertNil(result.format)
        }
    }

    func testExplicitMIMEIsPreservedEvenWithJPEGSignature() {
        for type in ["image/png", "image/jpeg; profile=example", "text/plain", "application/pdf"] {
            let result = HTTPBodyInspection.inspect(jpeg, contentType: type)
            XCTAssertEqual(result.contentType, type)
            XCTAssertEqual(result.data, jpeg)
            XCTAssertNil(result.format)
        }
    }

    func testIncompleteOrUnrelatedSignaturesKeepTheBinaryFallback() {
        let samples = [
            Data(), Data([0xff, 0xd8]), Data([0xff, 0xd8, 0]),
            Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a]),
            Data("GIF89".utf8), Data("GIF99a".utf8),
            Data("RIFFxxxxWEBPV".utf8), Data("RIFFxxxxWAVEfmt ".utf8), Data("RIFFxxxxWEBPdata".utf8),
            Data(#"{"filename":"photo.jpeg"}"#.utf8)
        ]
        for bytes in samples {
            let result = HTTPBodyInspection.inspect(bytes, contentType: "application/octet-stream")
            XCTAssertEqual(result.contentType, "application/octet-stream", "\(bytes.prefix(16))")
            XCTAssertEqual(result.data, bytes)
            XCTAssertNil(result.format)
        }
    }

    #if canImport(ImageIO)
    func testInspectedJPEGDecodesIntoANativeThumbnail() throws {
        let result = HTTPBodyInspection.inspect(jpeg, contentType: "application/octet-stream")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil))
        let thumbnail = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2
        ] as CFDictionary))
        XCTAssertEqual(thumbnail.width, 2)
        XCTAssertEqual(thumbnail.height, 2)
    }
    #endif
}
