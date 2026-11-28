import Foundation

/// 语言 ID 用于存储与资源定位，不能以翻译后的显示名替代。
enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case spanish = "es-419"
    case japanese = "ja"
    case portuguese = "pt-BR"

    static func resolve(selection: String, preferredLanguages: [String]) -> AppLanguage {
        if let explicit = AppLanguage(rawValue: selection) { return explicit }
        for preference in preferredLanguages {
            let parts = preference.lowercased().replacingOccurrences(of: "_", with: "-")
                .split(separator: "-").map(String.init)
            guard let language = parts.first else { continue }
            if language == "en" { return .english }
            if language == "es" { return .spanish }
            if language == "ja" { return .japanese }
            if language == "pt" { return .portuguese }
            guard language == "zh" else { continue }
            // 首版没有繁体翻译；继续尝试用户列表中之后的受支持语言。
            if parts.contains("hant") { continue }
            if parts.contains("hans") { return .simplifiedChinese }
            if parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) { continue }
            return .simplifiedChinese
        }
        return .english
    }
}
