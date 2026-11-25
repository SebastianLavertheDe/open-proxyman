import Foundation
import CryptoKit

@main
struct AppcastVerificationChecks {
    static func main() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let archive = Data("fixture signed update archive".utf8)
        let publicKey = key.publicKey.rawRepresentation
        let downloadURL = "https://github.com/owner/project/releases/download/v1.2.3/ProxyMirror-1.2.3.dmg"
        let signature = try key.signature(for: archive).base64EncodedString()
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><item>
        <sparkle:version>123</sparkle:version><sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
        <enclosure url="\(downloadURL)" sparkle:edSignature="\(signature)" length="\(archive.count)" type="application/octet-stream"/>
        </item></channel></rss>
        """
        func sign(_ content: String) throws -> Data {
            let bytes = Data(content.utf8)
            let signature = try key.signature(for: bytes).base64EncodedString()
            return bytes + Data("<!-- sparkle-signatures:\nedSignature: \(signature)\nlength: \(bytes.count)\n-->\n".utf8)
        }
        let feed = try sign(xml)
        try verifyReleaseAppcast(feed: feed, archive: archive, publicKey: publicKey,
                                 version: "1.2.3", build: "123", downloadURL: downloadURL)
        var checked = 1
        func rejects(_ body: () throws -> Void) {
            do { try body(); fatalError("Invalid release feed was accepted") }
            catch { checked += 1 }
        }
        rejects { try verifyReleaseAppcast(feed: Data(xml.utf8), archive: archive, publicKey: publicKey, version: "1.2.3", build: "123", downloadURL: downloadURL) }
        rejects { try verifyReleaseAppcast(feed: feed + Data("changed".utf8), archive: archive, publicKey: publicKey, version: "1.2.3", build: "123", downloadURL: downloadURL) }
        rejects { try verifyReleaseAppcast(feed: feed, archive: archive + Data([0]), publicKey: publicKey, version: "1.2.3", build: "123", downloadURL: downloadURL) }
        rejects { try verifyReleaseAppcast(feed: feed, archive: archive, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, version: "1.2.3", build: "123", downloadURL: downloadURL) }
        rejects { try verifyReleaseAppcast(feed: feed, archive: archive, publicKey: publicKey, version: "1.2.4", build: "123", downloadURL: downloadURL) }
        rejects { try verifyReleaseAppcast(feed: feed, archive: archive, publicKey: publicKey, version: "1.2.3", build: "124", downloadURL: downloadURL) }
        rejects { try verifyReleaseAppcast(feed: feed, archive: archive, publicKey: publicKey, version: "1.2.3", build: "123", downloadURL: "https://other.example/update.dmg") }
        for damaged in [
            xml.replacingOccurrences(of: "sparkle:edSignature=\"\(signature)\"", with: ""),
            xml.replacingOccurrences(of: "length=\"\(archive.count)\"", with: "length=\"1\""),
            xml.replacingOccurrences(of: "\(signature)", with: Data(repeating: 0, count: 64).base64EncodedString()),
            xml.replacingOccurrences(of: "</channel>", with: "<item/></channel>"),
        ] {
            rejects { try verifyReleaseAppcast(feed: sign(damaged), archive: archive, publicKey: publicKey, version: "1.2.3", build: "123", downloadURL: downloadURL) }
        }
        print("PASS: \(checked) production Sparkle signature and release metadata checks")
    }
}
