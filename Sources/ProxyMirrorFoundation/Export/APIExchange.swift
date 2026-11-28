import Foundation

/// An immutable HTTP sample shared by desktop, CLI and MCP exporters.
package struct APIExchange: Sendable {
    package let method: String
    package let url: String
    package let requestHeaders: [(String, String)]
    package let requestBody: Data
    package let status: Int
    package let responseHeaders: [(String, String)]
    package let responseBody: Data
    package let requestComplete: Bool
    package let responseComplete: Bool

    package init(method: String, url: String, requestHeaders: [(String, String)] = [], requestBody: Data = Data(),
                 status: Int = 0, responseHeaders: [(String, String)] = [], responseBody: Data = Data(),
                 requestComplete: Bool = true, responseComplete: Bool = true) {
        self.method = method; self.url = url; self.requestHeaders = requestHeaders; self.requestBody = requestBody
        self.status = status; self.responseHeaders = responseHeaders; self.responseBody = responseBody
        self.requestComplete = requestComplete; self.responseComplete = responseComplete
    }

    package func header(_ name: String, response: Bool = false) -> String? {
        (response ? responseHeaders : requestHeaders).first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }
}
