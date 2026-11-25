import Foundation

/// Classify the filename before opening a directory package or reading private binary data.
package enum SessionImportCompatibility {
    package static let proxymanExtensions = [
        "proxymanlog", "proxymanlogv2", "proxymansession", "proxymansessionv2",
    ]

    package static func needsProxymanConversion(_ url: URL) -> Bool {
        proxymanExtensions.contains(url.pathExtension.lowercased())
    }

    package static let documentationURL = URL(string: "https://proxyman.com/docs/basic-features/import-export")!
    package static let exportCommand = "proxyman-cli export flows --format har"
}
