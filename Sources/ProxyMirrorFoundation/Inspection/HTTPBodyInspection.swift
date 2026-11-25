import Foundation

/// Bounded application-payload conversion shared by body, preview and raw
/// presentation. Captured bytes, HTTP headers and replay input remain intact.
package struct HTTPBodyInspection: Sendable {
    package enum Format: Sendable { case messagePack, tars }
    package enum Issue: Sendable { case outputLimit }
    package let data: Data
    package let contentType: String
    package let format: Format?
    package let issue: Issue?
    package init(data: Data, contentType: String, format: Format? = nil, issue: Issue? = nil) {
        self.data = data; self.contentType = contentType; self.format = format; self.issue = issue
    }
    package static func inspect(_ data: Data, contentType: String, allowUnhintedTars: Bool = false) -> Self {
        let messagePack = MessagePackBody.inspect(data, contentType: contentType)
        if messagePack.decoded { return Self(data: messagePack.data, contentType: messagePack.contentType, format: .messagePack) }
        if messagePack.issue == .outputLimit { return Self(data: data, contentType: contentType, issue: .outputLimit) }
        do {
            if let json = try TarsBody.decodeIfTars(data, contentTypeHint: contentType, allowUnhinted: allowUnhintedTars) {
                return Self(data: json, contentType: "application/json", format: .tars)
            }
        } catch TarsBody.DecodeError.outputLimit {
            return Self(data: data, contentType: contentType, issue: .outputLimit)
        } catch {}
        return Self(data: data, contentType: contentType)
    }
}
