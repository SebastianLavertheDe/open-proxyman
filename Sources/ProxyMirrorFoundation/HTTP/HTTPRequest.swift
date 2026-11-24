import Foundation

package struct HTTPRequest: Sendable, Codable {
    package var method: String
    package var url: String           // 绝对 URL
    package var headers: [(String, String)]
    package var body: Data?
    /// 0 disables the overall deadline; connection setup remains bounded.
    package var timeoutSeconds: Int = 60
    package var followRedirects: Bool = false

    private enum CodingKeys: String, CodingKey {
        case method, url, headers, body, timeoutSeconds, followRedirects
    }
    private struct Header: Codable { let name: String; let value: String }

    package init(method: String, url: String, headers: [(String, String)], body: Data?,
         timeoutSeconds: Int = 60, followRedirects: Bool = false) {
        self.method = method; self.url = url; self.headers = headers; self.body = body
        self.timeoutSeconds = timeoutSeconds; self.followRedirects = followRedirects
    }

    package init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        method = try fields.decode(String.self, forKey: .method)
        url = try fields.decode(String.self, forKey: .url)
        headers = try fields.decode([Header].self, forKey: .headers).map { ($0.name, $0.value) }
        body = try fields.decodeIfPresent(Data.self, forKey: .body)
        timeoutSeconds = try fields.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 60
        followRedirects = try fields.decodeIfPresent(Bool.self, forKey: .followRedirects) ?? false
    }

    package func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(method, forKey: .method); try fields.encode(url, forKey: .url)
        try fields.encode(headers.map { Header(name: $0.0, value: $0.1) }, forKey: .headers)
        try fields.encodeIfPresent(body, forKey: .body)
        try fields.encode(timeoutSeconds, forKey: .timeoutSeconds)
        try fields.encode(followRedirects, forKey: .followRedirects)
    }
}
