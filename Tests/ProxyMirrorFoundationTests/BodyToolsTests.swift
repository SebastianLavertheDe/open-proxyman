import Foundation
import XCTest
@testable import ProxyMirrorFoundation

final class BodyToolsTests: XCTestCase {
    func testMarkupPreservesMixedAndSensitiveContent() {
        XCTAssertEqual(MarkupFormatter.format("<root><p>a <b>b</b> c</p><pre>  one\n two </pre><n>3</n></root>").text,
                       "<root>\n  <p>a <b>b</b> c</p>\n  <pre>  one\n two </pre>\n  <n>3</n>\n</root>")
        let script = "<html><script>if (a < b) x();</script></html>"
        XCTAssertTrue(MarkupFormatter.format(script, html: true).formatted)
        XCTAssertEqual(MarkupFormatter.format("<!DOCTYPE html><html><body><br></body></html>", html: true).text,
                       "<!DOCTYPE html>\n<html>\n  <body>\n    <br>\n  </body>\n</html>")
        XCTAssertTrue(MarkupFormatter.format("<r><![CDATA[a<b]]></r>").text.contains("<![CDATA[a<b]]>"))
    }
    func testInvalidMarkupFallsBackWithoutDataLoss() {
        for text in ["<a><b></a>", "<a x=2/>", "<a x='1' x='2'/>", "<a/><b/>", "<!DOCTYPE r SYSTEM 'file:///etc/passwd'><r/>", "<r><!--oops</r>", "<r>oops & broken</r>", "<r x='&unknown;'/>", "<r><!--a--b--></r>", "<r a='1'b='2'/>", "< r/>", "<r></ r>", "<r / >", "<r 0x='1'/>"] {
            let result = MarkupFormatter.format(text)
            XCTAssertFalse(result.formatted, text)
            XCTAssertEqual(result.text, text)
        }
    }
    func testMultipartBoundaryMustStartOnLineAndHaveValidSuffix() throws {
        let payload = Data([0, 255]) + Data("abc--bound\r\n--boundNO\r\n--bound--NO\r\nxyz".utf8)
        let data = Data("--bound\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"a;b.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8) + payload + Data("\r\n--bound--\r\n".utf8)
        let result = try XCTUnwrap(FormBody.multipart(data, contentType: "multipart/form-data; boundary=\"bound\""))
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.parts.count, 1)
        XCTAssertEqual(result.parts[0].filename, "a;b.bin")
        XCTAssertEqual(data.subdata(in: result.parts[0].range), payload)
        let partial = try XCTUnwrap(FormBody.multipart(data.dropLast(8), contentType: "multipart/form-data; boundary=bound"))
        XCTAssertFalse(partial.complete)
        XCTAssertEqual(partial.parts.count, 0)
    }
    func testPartialMultipartOnlyExposesCompletedParts() throws {
        let bytes = Data("--b\r\nContent-Disposition: form-data; name=\"first\"\r\n\r\none\r\n--b\r\nContent-Disposition: form-data; name=\"second\"\r\n\r\ntwo".utf8)
        let result = try XCTUnwrap(FormBody.multipart(bytes, contentType: "multipart/form-data; boundary=b"))
        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.parts.map(\.name), ["first"])
        XCTAssertEqual(String(decoding: bytes.subdata(in: result.parts[0].range), as: UTF8.self), "one")
    }
    func testMarkupHighlightSpansUseUTF16Bounds() {
        let text = "<r attr=\"你好\"><!-- hi --><p>世界</p></r>"
        let plan = MarkupHighlightPlan.make(text)
        XCTAssertFalse(plan.spans.isEmpty)
        for span in plan.spans { XCTAssertLessThanOrEqual(span.offset + span.length, text.utf16.count) }
        XCTAssertTrue(MarkupHighlightPlan.make(String(repeating: "x", count: 131_073)).limited)
    }
    func testSelectionDecodersPreserveEvidenceAndHandlePadding() {
        XCTAssertEqual(SelectionTransform.decodeBase64.apply("aGVsbG8"), "hello")
        XCTAssertNil(SelectionTransform.decodeBase64.apply("a"))
        let result = SelectionTransform.decodeJWT.apply("eyJhbGciOiJub25lIn0.eyJzdWIiOiIxIn0.")
        XCTAssertTrue(result?.contains("\"sub\"") == true)
        XCTAssertTrue(result?.contains("Signature: 0 bytes") == true)
        XCTAssertEqual(SelectionTransform.convertTimestamp.apply("1700000000000", timeZone: TimeZone(secondsFromGMT: 0)!),
                       "Local: 2023-11-14T22:13:20.000Z\nUTC: 2023-11-14T22:13:20.000Z")
        XCTAssertTrue(FormBody.urlEncoded(Data()).isEmpty)
        let fields = FormBody.urlEncoded(Data("x=a+b&x=%E4%BD%A0&empty=".utf8))
        XCTAssertEqual(fields.map(\.0), ["x", "x", "empty"])
        XCTAssertEqual(fields.map(\.1), ["a b", "你", ""])
    }
}
