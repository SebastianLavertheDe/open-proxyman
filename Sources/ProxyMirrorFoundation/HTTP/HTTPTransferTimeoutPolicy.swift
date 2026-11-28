import Foundation

/// Monotonic progress clocks. Upload activity must not consume the time allowed
/// for the origin to respond after the complete request has been delivered.
package struct HTTPTransferTimeoutPolicy {
    package let interval: TimeInterval
    package private(set) var lastUpload: TimeInterval
    package private(set) var lastDownload: TimeInterval

    package init(interval: TimeInterval = 30, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.interval = interval
        lastUpload = now
        lastDownload = now
    }

    package mutating func uploaded(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) { lastUpload = now }
    package mutating func downloaded(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) { lastDownload = now }

    package func deadline(requestPending: Bool, responseStarted: Bool, eventStream: Bool) -> TimeInterval? {
        if responseStarted && eventStream { return nil }
        if requestPending { return lastUpload + interval }
        return (responseStarted ? lastDownload : max(lastUpload, lastDownload)) + interval
    }
}
