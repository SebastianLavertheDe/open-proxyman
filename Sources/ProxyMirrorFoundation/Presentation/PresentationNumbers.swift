import Foundation

package enum PresentationNumbers {
    private struct Key: Hashable { let locale: String; let digits: Int }
    private static let lock = NSLock()
    private static var formatters: [Key: NumberFormatter] = [:]

    package static func decimal(_ value: Double, fractionDigits: Int = 1, locale: Locale = .autoupdatingCurrent) -> String {
        guard value.isFinite else { return "—" }
        let digits = min(6, max(0, fractionDigits))
        let key = Key(locale: locale.identifier, digits: digits)
        lock.lock(); defer { lock.unlock() }
        let formatter: NumberFormatter
        if let cached = formatters[key] { formatter = cached }
        else {
            formatter = NumberFormatter(); formatter.locale = locale; formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = digits; formatter.maximumFractionDigits = digits
            if formatters.count >= 32 { formatters.removeAll() }
            formatters[key] = formatter
        }
        return formatter.string(from: NSNumber(value: value)) ?? "—"
    }

    package static func integer(_ value: Int, locale: Locale = .autoupdatingCurrent) -> String {
        decimal(Double(value), fractionDigits: 0, locale: locale)
    }

    package static func milliseconds(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        decimal(value, locale: locale) + " ms"
    }

    package static func duration(seconds: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        if seconds < 1 { return decimal(seconds * 1000, fractionDigits: 0, locale: locale) + " ms" }
        if seconds < 60 { return decimal(seconds, fractionDigits: 2, locale: locale) + " s" }
        return decimal(seconds / 60, fractionDigits: 2, locale: locale) + " min"
    }

    package static func byteCount(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
