import Foundation
import CryptoKit
import Darwin

struct ReleaseFeedError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 在发布前使用App内相同的公钥验证两个签名，并核对版本和实际上传地址。
func verifyReleaseAppcast(feed: Data, archive: Data, publicKey: Data,
                          version: String, build: String, downloadURL: String) throws {
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw ReleaseFeedError(message: message) }
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    let marker = Data("<!-- sparkle-signatures:\n".utf8)
    guard let range = feed.range(of: marker, options: .backwards),
          let trailer = String(data: feed[range.lowerBound...], encoding: .utf8) else {
        throw ReleaseFeedError(message: "Appcast is missing its Sparkle feed signature")
    }
    let lines = trailer.components(separatedBy: "\n")
    try require(lines.count == 5 && lines[0] == "<!-- sparkle-signatures:" && lines[3] == "-->" && lines[4].isEmpty,
                "Invalid Sparkle feed signature trailer")
    guard lines[1].hasPrefix("edSignature: "), lines[2].hasPrefix("length: "),
          let signature = Data(base64Encoded: String(lines[1].dropFirst("edSignature: ".count))),
          let length = Int(lines[2].dropFirst("length: ".count)) else {
        throw ReleaseFeedError(message: "Invalid Sparkle feed signature metadata")
    }
    let content = Data(feed[..<range.lowerBound])
    try require(length == content.count, "Appcast signature length does not match its bytes")
    try require(key.isValidSignature(signature, for: content), "Appcast signature does not match PM_UPDATE_PUBLIC_KEY")

    let document = try XMLDocument(data: content, options: [])
    let items = try document.nodes(forXPath: "/rss/channel/item").compactMap { $0 as? XMLElement }
    try require(items.count == 1, "Release appcast must contain exactly the current update")
    let item = items[0]
    let namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    let itemBuild = item.elements(forLocalName: "version", uri: namespace).first?.stringValue
    let itemVersion = item.elements(forLocalName: "shortVersionString", uri: namespace).first?.stringValue
    try require(itemBuild == build && itemVersion == version, "Appcast version does not match the signed app")
    guard let enclosure = item.elements(forName: "enclosure").first,
          let archiveSignatureText = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue,
          let archiveSignature = Data(base64Encoded: archiveSignatureText) else {
        throw ReleaseFeedError(message: "Update archive is missing its Ed25519 signature")
    }
    try require(enclosure.attribute(forName: "url")?.stringValue == downloadURL,
                "Appcast download URL differs from the release upload URL")
    try require(enclosure.attribute(forName: "length")?.stringValue.flatMap(Int.init) == archive.count,
                "Appcast archive length does not match the uploaded DMG")
    try require(key.isValidSignature(archiveSignature, for: archive),
                "Update archive signature does not match PM_UPDATE_PUBLIC_KEY")
}

#if !APPCAST_TESTING
@main
struct ReleaseFeedVerifier {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 7, let publicKey = Data(base64Encoded: arguments[3].trimmingCharacters(in: .whitespacesAndNewlines)) else {
            fputs("Usage: verify-appcast <appcast.xml> <update.dmg> <public-key> <version> <build> <download-url>\n", stderr)
            exit(2)
        }
        do {
            try verifyReleaseAppcast(feed: Data(contentsOf: URL(fileURLWithPath: arguments[1])),
                                     archive: Data(contentsOf: URL(fileURLWithPath: arguments[2])), publicKey: publicKey,
                                     version: arguments[4], build: arguments[5], downloadURL: arguments[6])
            print("Verified Sparkle feed and archive signatures, versions, size and release URL")
        } catch {
            fputs("Release appcast verification failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
#endif
