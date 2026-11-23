import Foundation
import Security

/// GitHub API: https://docs.github.com/en/rest/gists/gists#create-a-gist
/// Tokens are stored only in the login Keychain, never in settings or backups.
enum GistService {
    enum GistError: LocalizedError, OperationIssueProviding {
        case invalidToken, emptySelection, invalidPreview, tooLarge, keychain(OSStatus), response(OperationIssue)
        var errorDescription: String? { operationIssue.diagnostic }
        var operationIssue: OperationIssue {
            switch self {
            case .invalidToken: return OperationIssue.gistServiceEnterAGithubTokenWithGistsWritePermission
            case .emptySelection: return OperationIssue.gistServiceSelectTheRequestsToPublish
            case .invalidPreview: return OperationIssue.gistServiceThePreviewMustBeValidHarJson
            case .tooLarge: return OperationIssue.gistServiceThisGistExceeds8MibReduceTheSelection
            case .keychain(let status): return OperationIssue.gistServiceUnableToAccessTheKeychain(Int(status))
            case .response(let message): return message
            }
        }
    }

    private static let service = "com.proxymirror.github-gist"
    private static let account = "github-token"
    private static var key: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func savedToken() throws -> String? {
        var query = key
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw GistError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }

    static func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(key as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = key
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw GistError.keychain(added) }
        } else if status != errSecSuccess { throw GistError.keychain(status) }
    }

    static func deleteToken() throws {
        let status = SecItemDelete(key as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GistError.keychain(status) }
    }

    static func preview(_ transactions: [Transaction]) throws -> String {
        guard !transactions.isEmpty else { throw GistError.emptySelection }
        let har = ExportRedaction.har(ExportService.buildHAR(transactions))
        let bytes = try JSONSerialization.data(withJSONObject: har, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard bytes.count <= 8 * 1024 * 1024 else { throw GistError.tooLarge }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func request(preview: String, description: String, isPublic: Bool, token: String) throws -> URLRequest {
        let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty, !credential.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw GistError.invalidToken }
        guard let object = try JSONSerialization.jsonObject(with: Data(preview.utf8)) as? [String: Any],
              let log = object["log"] as? [String: Any], log["entries"] is [Any] else { throw GistError.invalidPreview }
        // Redact again after user edits to the preview.
        let safe = try JSONSerialization.data(withJSONObject: ExportRedaction.har(object), options: [.prettyPrinted, .sortedKeys])
        guard safe.count <= 8 * 1024 * 1024 else { throw GistError.tooLarge }
        let payload: [String: Any] = ["description": description, "public": isPublic,
                                    "files": ["proxymirror.har": ["content": String(decoding: safe, as: UTF8.self)]]]
        var request = URLRequest(url: URL(string: "https://api.github.com/gists")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ProxyMirror", forHTTPHeaderField: "User-Agent")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    static func publish(preview: String, description: String, isPublic: Bool, token: String) async throws -> URL {
        let request = try request(preview: preview, description: description, isPublic: isPublic, token: token)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        // Management credentials must not be captured through our own system proxy.
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                                           "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GistError.response(OperationIssue.gistServiceGithubDidNotReturnAnHttpResponse) }
        guard http.statusCode == 201 else {
            throw GistError.response(OperationIssue.gistServiceGithubPublishingFailedHttpCheckTokenPermissionsAnd(Int(http.statusCode)))
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let text = object?["html_url"] as? String, let url = URL(string: text),
              url.scheme == "https", url.host == "gist.github.com" else { throw GistError.response(OperationIssue.gistServiceGithubReturnedAnInvalidGistUrl) }
        return url
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
