import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Metadata only: capturing a CSV snapshot never retains request/response bodies.
package struct CSVExportRecord: Sendable {
    package let method: String, url: String, contentType: String
    package let status: Int, size: Int
    package let duration: TimeInterval, startedAt: Date
    package init(method: String, status: Int, url: String, contentType: String, size: Int,
                 duration: TimeInterval, startedAt: Date) {
        self.method = method; self.status = status; self.url = url; self.contentType = contentType
        self.size = size; self.duration = duration; self.startedAt = startedAt
    }
}

package enum AtomicCSVWriter {
    package struct DateStyle: Sendable {
        package let uses24HourClock: Bool, includesDate: Bool
        package let timeZone: TimeZone, locale: Locale
        package init(uses24HourClock: Bool, includesDate: Bool, timeZone: TimeZone = .current, locale: Locale = Locale(identifier: "en_US_POSIX")) {
            self.uses24HourClock = uses24HourClock; self.includesDate = includesDate
            self.timeZone = timeZone; self.locale = locale
        }
    }

    /// One 64 KiB output buffer is reused. Only the final rename touches target.
    package static func write(_ records: [CSVExportRecord], to target: URL, dateStyle: DateStyle,
                              cancellation: WorkCancellation = WorkCancellation(),
                              progress: (Int) -> Void = { _ in }) throws {
        try cancellation.check()
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".pm-csv-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw currentError() }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close(); _ = unlink(temporary.path) }
        let formatter = DateFormatter()
        formatter.locale = dateStyle.locale; formatter.timeZone = dateStyle.timeZone
        formatter.dateFormat = (dateStyle.includesDate ? "yyyy-MM-dd " : "")
            + (dateStyle.uses24HourClock ? "HH:mm:ss.SSS" : "hh:mm:ss.SSS a") + (dateStyle.includesDate ? " xxx" : "")
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        func append(_ byte: UInt8) throws {
            buffer.append(byte)
            if buffer.count == 64 * 1024 {
                try cancellation.check()
                try file.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        func row(_ cells: [String]) throws {
            for (index, cell) in cells.enumerated() {
                if index != 0 { try append(44) }
                try append(34)
                for byte in cell.utf8 { if byte == 34 { try append(34) }; try append(byte) }
                try append(34)
            }
            try append(10)
        }
        try row(["Method", "Status", "URL", "Content Type", "Size", "Duration(ms)", "Start Time"])
        progress(0)
        for (index, record) in records.enumerated() {
            try cancellation.check()
            try row([record.method, String(record.status), record.url, record.contentType, String(record.size),
                     String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), record.duration * 1000),
                     formatter.string(from: record.startedAt)])
            if (index + 1) % 256 == 0 || index + 1 == records.count { progress(index + 1) }
        }
        try cancellation.check()
        if !buffer.isEmpty { try file.write(contentsOf: buffer) }
        guard fsync(descriptor) == 0 else { throw currentError() }
        try file.close()
        try cancellation.whileActive {
            guard rename(temporary.path, target.path) == 0 else { throw currentError() }
        }
    }

    private static func currentError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
