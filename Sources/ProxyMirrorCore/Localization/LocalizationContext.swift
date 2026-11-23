import Foundation

/// 启动后保持不可变，后台任务与所有窗口共享同一语言，偏好改动下次启动生效。
struct LocalizationContext {
    struct Lookup {
        let value: String
        let language: AppLanguage
        let usedFallback: Bool
    }

    let language: AppLanguage
    let regionLocale: Locale
    private let selectedBundle: Bundle?
    private let englishBundle: Bundle?
    private let reportMissing: (String, String) -> Void

    init(language: AppLanguage, resources: Bundle?, regionLocale: Locale = .current,
         reportMissing: @escaping (String, String) -> Void = { table, key in
             NSLog("ProxyMirror missing localization: %@.%@", table, key)
         }) {
        self.language = language
        self.regionLocale = regionLocale
        self.selectedBundle = resources.flatMap { LocalizationResources.languageBundle(language, in: $0) }
        self.englishBundle = resources.flatMap { LocalizationResources.languageBundle(.english, in: $0) }
        self.reportMissing = reportMissing
    }

    func lookup(table: String, key: String, englishFallback: String) -> Lookup {
        let marker = "\u{001F}ProxyMirrorMissing:\(table).\(key)"
        if let value = selectedBundle?.localizedString(forKey: key, value: marker, table: table), value != marker {
            return Lookup(value: value, language: language, usedFallback: false)
        }
        reportMissing(table, key)
        if let value = englishBundle?.localizedString(forKey: key, value: marker, table: table), value != marker {
            return Lookup(value: value, language: .english, usedFallback: true)
        }
        return Lookup(value: englishFallback, language: .english, usedFallback: true)
    }

    /// 命中英文兜底时也必须使用英文复数规则，不能沿用原选择语言。
    func render(table: String, key: String, arguments: [CVarArg] = [], englishFallback: String) -> String {
        let hit = lookup(table: table, key: key, englishFallback: englishFallback)
        guard !arguments.isEmpty else { return hit.value.replacingOccurrences(of: "%%", with: "%") }
        return String(format: hit.value, locale: formattingLocale(for: hit.language), arguments: arguments)
    }

    func formattingLocale(for language: AppLanguage) -> Locale {
        let suffix = regionLocale.regionCode.map { "_" + $0 } ?? ""
        return Locale(identifier: language.rawValue + suffix)
    }
}
