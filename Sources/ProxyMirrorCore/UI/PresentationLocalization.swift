import Foundation

/// 文案只通过生成的 Strings 接口访问，语言选择与资源查询在进程内保持一致。
enum L10n {
    private static let resolution = LocalizationResources.resolve()
    static let context = LocalizationContext(language: AppLanguage.resolve(
        selection: requestedSelection, preferredLanguages: Locale.preferredLanguages), resources: resolution.bundle)

    static var locale: Locale { context.formattingLocale(for: context.language) }
    static var effectiveLanguage: String { context.language.rawValue }
    static var startupIssue: String? { resolution.issue }

    private static var requestedSelection: String {
        if let override = ProcessInfo.processInfo.environment["PM_SETTINGS_LANGUAGE"],
           ["system", "en", "zh-Hans"].contains(override) { return override }
        return UserDefaults.standard.string(forKey: "ui.applicationLanguage") ?? "system"
    }

    static func resolvedLanguage(_ language: String? = nil,
                                 preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        guard let language else { return effectiveLanguage }
        return AppLanguage.resolve(selection: language, preferredLanguages: preferredLanguages).rawValue
    }

    static func contextForLanguage(_ language: String) -> LocalizationContext {
        LocalizationContext(language: AppLanguage.resolve(selection: language, preferredLanguages: Locale.preferredLanguages),
                            resources: resolution.bundle)
    }

    static func render(table: String, key: String, arguments: [CVarArg] = [], englishFallback: String,
                       language: String? = nil) -> String {
        let selected = language.map(contextForLanguage) ?? context
        return selected.render(table: table, key: key, arguments: arguments, englishFallback: englishFallback)
    }
}
