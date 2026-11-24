import Foundation

/// Bytes alone do not identify an inspected message: changing its encoding or
/// completeness changes the interpretation even without appending body bytes.
package struct BodyInspectionKey: Hashable, Sendable {
    package let transaction: ObjectIdentifier
    package let revision: UInt64
    package let encodings: [String]
    package let contentType: String
    package let complete: Bool
    package let truncated: Bool
    package let epoch: UInt64
    package init(transaction: ObjectIdentifier, revision: UInt64, encodings: [String], contentType: String,
                 complete: Bool, truncated: Bool, epoch: UInt64) {
        self.transaction = transaction; self.revision = revision; self.encodings = encodings
        self.contentType = contentType; self.complete = complete; self.truncated = truncated; self.epoch = epoch
    }
}
