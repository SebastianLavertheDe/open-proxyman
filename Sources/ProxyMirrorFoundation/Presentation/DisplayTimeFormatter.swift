import Foundation

package enum DisplayTimeFormatter {
    private struct Key: Hashable {
        let uses24HourClock: Bool
        let includesDate: Bool
        let timezone: String
        let locale: String
    }
    private static let lock = NSLock()
    private static var formatters: [Key: DateFormatter] = [:]

    package static func string(from date: Date, uses24HourClock: Bool, includesDate: Bool,
                       timeZone: TimeZone = .autoupdatingCurrent,
                       locale: Locale = .autoupdatingCurrent) -> String {
        let key = Key(uses24HourClock: uses24HourClock, includesDate: includesDate,
                      timezone: timeZone.identifier, locale: locale.identifier)
        lock.lock(); defer { lock.unlock() }
        let formatter: DateFormatter
        if let existing = formatters[key] { formatter = existing }
        else {
            formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateFormat = (includesDate ? "yyyy-MM-dd " : "")
                + (uses24HourClock ? "HH:mm:ss.SSS" : "hh:mm:ss.SSS a") + (includesDate ? " xxx" : "")
            if formatters.count >= 16 { formatters.removeAll() }
            formatters[key] = formatter
        }
        return formatter.string(from: date)
    }
}
