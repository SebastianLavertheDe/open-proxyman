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
        if let imageType = imageTypeForGenericBody(data, contentType: contentType) {
            return Self(data: data, contentType: imageType)
        }
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

    /// Use raster signatures on the decoded bytes of a generically labelled attachment.
    /// https://mimesniff.spec.whatwg.org/#matching-an-image-type-pattern
    private static func imageTypeForGenericBody(_ data: Data, contentType: String) -> String? {
        let mime = contentType.prefix { $0 != ";" }.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard mime.isEmpty || mime == "application/octet-stream" || mime == "binary/octet-stream" else { return nil }

        if data.starts(with: [0xff, 0xd8, 0xff]) { return "image/jpeg" }
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) { return "image/png" }
        if data.starts(with: "GIF87a".utf8) || data.starts(with: "GIF89a".utf8) { return "image/gif" }
        if data.starts(with: "RIFF".utf8), data.dropFirst(8).starts(with: "WEBPVP".utf8) { return "image/webp" }
        return nil
    }
}
