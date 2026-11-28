import Foundation

/// Persisted error identity. Diagnostics are stable machine output; localized
/// rendering belongs to the desktop presentation layer and is never serialized.
package struct CapturedFailure: Codable, Equatable, Sendable, LocalizedError {
    package let code: String
    package let arguments: [String]
    package let diagnostic: String

    package init(code: String, arguments: [String] = [], diagnostic: String) {
        self.code = code
        self.arguments = arguments
        self.diagnostic = diagnostic
    }

    package var errorDescription: String? { diagnostic }
}
