import Foundation
import ProxyMirrorFoundation
import XCTest

final class PresentationFormattingTests: XCTestCase {
    func testClockUsesEveryUserPreferenceAndTimeZone() {
        let date = Date(timeIntervalSince1970: 13 * 3600 + 4 * 60 + 5.123)
        let utc = TimeZone(secondsFromGMT: 0)!, east = TimeZone(secondsFromGMT: 8 * 3600)!
        let english = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(DisplayTimeFormatter.string(from: date, uses24HourClock: true, includesDate: false,
            timeZone: utc, locale: english), "13:04:05.123")
        XCTAssertEqual(DisplayTimeFormatter.string(from: date, uses24HourClock: false, includesDate: true,
            timeZone: east, locale: english), "1970-01-01 09:04:05.123 PM +08:00")
        XCTAssertEqual(DisplayTimeFormatter.string(from: date, uses24HourClock: false, includesDate: false,
            timeZone: utc, locale: Locale(identifier: "zh_CN")), "01:04:05.123 下午")
        XCTAssertEqual(DisplayTimeFormatter.string(from: date, uses24HourClock: false, includesDate: false,
            timeZone: utc, locale: english), "01:04:05.123 PM")
    }

    func testRegionSensitiveNumbersAreSeparateFromProtocolCodes() {
        XCTAssertEqual(PresentationNumbers.milliseconds(1234.5, locale: Locale(identifier: "de_DE")), "1.234,5 ms")
        XCTAssertEqual(PresentationNumbers.milliseconds(1234.5, locale: Locale(identifier: "en_US")), "1,234.5 ms")
        XCTAssertEqual(PresentationNumbers.duration(seconds: 1.25, locale: Locale(identifier: "de_DE")), "1,25 s")
        XCTAssertEqual(PresentationNumbers.integer(12345, locale: Locale(identifier: "en_US")), "12,345")
        XCTAssertEqual(PresentationNumbers.decimal(.nan), "—")
        XCTAssertEqual(String(201), "201")
    }
}
