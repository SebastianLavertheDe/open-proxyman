import Foundation

struct CustomTrafficColumn: Codable, Hashable, Identifiable {
    enum Source: String, Codable, CaseIterable {
        case requestHeader, responseHeader, query
        case requestJSON, responseJSON
        var localizedTitle: String {
            switch self {
            case .requestHeader: return Strings.Models.columnSourceRequestHeader
            case .responseHeader: return Strings.Models.columnSourceResponseHeader
            case .query: return Strings.Models.columnSourceQuery
            case .requestJSON: return Strings.Models.columnSourceRequestJSON
            case .responseJSON: return Strings.Models.columnSourceResponseJSON
            }
        }
    }

    var id = UUID()
    var title = ""
    var source = Source.responseHeader
    var key = ""

    static let defaultsKey = "ui.customTrafficColumns"

    private struct Input: Equatable {
        let revision: UInt64
        let encodings: [String]
        let complete: Bool
        let truncated: Bool
    }

    private final class JSONValues {
        var requestInput: Input?
        var responseInput: Input?
        var request: [String: String] = [:]
        var response: [String: String] = [:]
    }

    @MainActor private static let jsonValues = NSMapTable<Transaction, JSONValues>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)

    @MainActor
    func value(for tx: Transaction) -> String {
        guard !Task.isCancelled else { return "" }
        switch source {
        case .requestHeader: return tx.requestHeaders.values(of: key).joined(separator: ", ")
        case .responseHeader: return tx.responseHeaders.values(of: key).joined(separator: ", ")
        case .query:
            return (URLComponents(string: "?\(tx.query)")?.queryItems ?? [])
                .filter { $0.name == key }.compactMap(\.value).joined(separator: ", ")
        case .requestJSON, .responseJSON:
            let values = Self.jsonValues.object(forKey: tx) ?? JSONValues()
            Self.jsonValues.setObject(values, forKey: tx)
            if source == .requestJSON {
                let input = Input(revision: tx.requestBodyRevision,
                                  encodings: tx.requestHeaders.values(of: "Content-Encoding"),
                                  complete: tx.requestBodyComplete, truncated: tx.requestTruncated)
                if values.requestInput != input {
                    values.requestInput = input
                    values.request.removeAll()
                }
                return jsonValue(in: InspectionBody.data(for: tx, request: true, limit: 131_072) ?? Data(),
                                 cache: &values.request)
            }
            let input = Input(revision: tx.responseBodyRevision,
                              encodings: tx.responseHeaders.values(of: "Content-Encoding"),
                              complete: tx.responseBodyComplete, truncated: tx.responseTruncated)
            if values.responseInput != input {
                values.responseInput = input
                values.response.removeAll()
            }
            return jsonValue(in: InspectionBody.data(for: tx, request: false, limit: 131_072) ?? Data(),
                             cache: &values.response)
        }
    }

    private func jsonValue(in data: @autoclosure () -> Data, cache: inout [String: String]) -> String {
        if let cached = cache[key] { return cached }
        let value = jsonValue(in: data())
        guard !Task.isCancelled else { return "" }
        if cache.count < 16 { cache[key] = value }
        return value
    }

    private func jsonValue(in data: Data) -> String {
        guard !data.isEmpty, data.count <= 131_072,
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return "" }
        let path = key.split(separator: ".")
        var current: Any? = root
        for component in path {
            if let object = current as? [String: Any] {
                current = object[String(component)]
            } else if let array = current as? [Any], let index = Int(component), array.indices.contains(index) {
                current = array[index]
            } else {
                return ""
            }
        }
        guard let current else { return "" }
        if let text = current as? String { return String(text.prefix(500)) }
        guard let encoded = try? JSONSerialization.data(withJSONObject: current, options: [.fragmentsAllowed, .sortedKeys])
        else { return "" }
        return String(decoding: encoded.prefix(500), as: UTF8.self)
    }
}
