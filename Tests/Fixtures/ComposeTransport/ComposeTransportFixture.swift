import Foundation
import ProxyMirrorFoundation

/// A real SwiftPM executable importing the same production transport as Compose.
/// Platform UI, capture objects, engines and CA implementations are not replaced.
@main
struct ComposeTransportFixture {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let method = args[1], url = args[2], bytes = Data(base64Encoded: args[3])!
        var headers = [("Content-Type", "application/octet-stream"), ("Authorization", "Bearer fixture-secret"),
                       ("Cookie", "session=fixture-secret"), ("X-Test", "retained")]
        if args[0] == "curl" {
            if method == "HEAD" { headers.append(("Content-Length", String(bytes.count))) }
            let request = HTTPRequest(method: method, url: url, headers: headers, body: bytes)
            print(CurlCommandGenerator.command(request, preserveOriginalHeaders: method == "HEAD"))
            return
        }
        let request = HTTPRequest(method: method, url: url, headers: headers,
            body: bytes.isEmpty ? nil : bytes, timeoutSeconds: Int(args[4])!, followRedirects: args[5] == "true")
        let cancellation = HTTPRequestTransport.Cancellation()
        if args.count > 6, args[6] == "cancel" {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { cancellation.cancel() }
        }
        let result = HTTPRequestTransport.send(request, cancellation: cancellation)
        let object: [String: Any] = ["status": result.head?.status ?? 0,
            "state": result.failure == nil ? "completed" : "failed", "body": result.body.base64EncodedString(),
            "bytes": result.receivedBytes, "error": result.failure?.localizedDescription ?? "",
            "headers": Dictionary((result.head?.headers.pairs ?? []).map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
}
