import Foundation

struct CustomTrafficColumn: Codable, Hashable, Identifiable {
    enum Source: String, Codable, CaseIterable {
        case requestHeader = "请求头", responseHeader = "响应头", query = "Query"
        case requestJSON = "请求 JSON", responseJSON = "响应 JSON"
    }

    var id = UUID()
    var title = ""
    var source = Source.responseHeader
    var key = ""

    static let defaultsKey = "ui.customTrafficColumns"

    private final class JSONValues {
        var requestRevision: UInt64?
        var responseRevision: UInt64?
        var request: [String: String] = [:]
        var response: [String: String] = [:]
    }

    @MainActor private static let jsonValues = NSMapTable<Transaction, JSONValues>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)

    @MainActor
    func value(for tx: Transaction) -> String {
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
                if values.requestRevision != tx.requestBodyRevision {
                    values.requestRevision = tx.requestBodyRevision
                    values.request.removeAll()
                }
                return jsonValue(in: tx.requestBody, cache: &values.request)
            }
            if values.responseRevision != tx.responseBodyRevision {
                values.responseRevision = tx.responseBodyRevision
                values.response.removeAll()
            }
            return jsonValue(in: tx.responseBody, cache: &values.response)
        }
    }

    private func jsonValue(in data: @autoclosure () -> Data, cache: inout [String: String]) -> String {
        if let cached = cache[key] { return cached }
        let value = jsonValue(in: data())
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
