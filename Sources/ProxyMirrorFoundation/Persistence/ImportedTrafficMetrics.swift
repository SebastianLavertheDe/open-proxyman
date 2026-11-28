import Foundation

/// Numeric metadata can describe bytes that were not captured. Validate those
/// counts without allocating them, and keep every display conversion in range.
package struct ImportedTrafficMetrics: Equatable, Sendable {
    package enum Invalid: Error { case byteCount, duration }
    package static let maximumDurationSeconds = Double(Int.max / 1000 - 1)
    package let requestBytes: Int
    package let responseBytes: Int
    package let durationSeconds: Double

    package init(requestBytes: Int, responseBytes: Int, capturedRequest: Int = 0, capturedResponse: Int = 0,
                 durationSeconds: Double) throws {
        guard requestBytes >= 0, responseBytes >= 0, capturedRequest >= 0, capturedResponse >= 0 else {
            throw Invalid.byteCount
        }
        let request = max(requestBytes, capturedRequest), response = max(responseBytes, capturedResponse)
        guard !request.addingReportingOverflow(response).overflow else { throw Invalid.byteCount }
        guard durationSeconds.isFinite, durationSeconds >= 0,
              durationSeconds <= Self.maximumDurationSeconds else { throw Invalid.duration }
        self.requestBytes = request; self.responseBytes = response; self.durationSeconds = durationSeconds
    }

    package static func har(requestBytes: Int?, responseBytes: Int?, capturedRequest: Int, capturedResponse: Int,
                            milliseconds: Double?) throws -> Self {
        func count(_ value: Int?, captured: Int) throws -> Int {
            guard let value, value != -1 else { return captured }
            guard value >= 0 else { throw Invalid.byteCount }
            return value
        }
        let time = milliseconds ?? 0
        guard time.isFinite else { throw Invalid.duration }
        return try Self(requestBytes: count(requestBytes, captured: capturedRequest),
                        responseBytes: count(responseBytes, captured: capturedResponse),
                        capturedRequest: capturedRequest, capturedResponse: capturedResponse,
                        durationSeconds: max(0, time) / 1000)
    }

    /// Defensive aggregation also covers manually created or edited records.
    package static func saturatingTotal(_ first: Int, _ second: Int) -> Int {
        let result = max(0, first).addingReportingOverflow(max(0, second))
        return result.overflow ? Int.max : result.partialValue
    }
}
