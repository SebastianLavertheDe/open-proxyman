import Foundation
#if canImport(ProxyMirrorCore)
@testable import ProxyMirrorCore
#endif

/// 使用真实 Foundation bundle，不复制资源查找和语言算法。
func checkLocalization(_ test: CoreAssertions) throws {
    let cases: [(String, [String], AppLanguage)] = [
        ("en", ["zh-Hans"], .english),
        ("zh-Hans", ["en"], .simplifiedChinese),
        ("es-419", ["en"], .spanish),
        ("ja", ["en"], .japanese),
        ("pt-BR", ["en"], .portuguese),
        ("system", ["es-ES"], .spanish),
        ("system", ["ja-JP"], .japanese),
        ("system", ["pt-PT"], .portuguese),
        ("system", ["fr-FR", "en-GB", "zh-Hans"], .english),
        ("system", ["fr-FR", "zh-Hans"], .simplifiedChinese),
        ("system", ["zh-CN"], .simplifiedChinese),
        ("system", ["zh-SG"], .simplifiedChinese),
        ("system", ["zh-Hans-CN"], .simplifiedChinese),
        ("system", ["zh-Hans-TW"], .simplifiedChinese),
        ("system", ["zh-Hant-CN", "en"], .english),
        ("system", ["zh_Hans_CN"], .simplifiedChinese),
        ("system", ["zh"], .simplifiedChinese),
        ("system", ["en-US"], .english),
        ("system", ["zh-Hant-TW", "en"], .english),
        ("system", ["zh-TW", "fr", "zh-Hans"], .simplifiedChinese),
        ("system", ["zh-HK"], .english),
        ("system", ["zh-MO"], .english),
        ("system", [], .english),
        ("invalid", ["fr-FR", "zh-CN"], .simplifiedChinese)
    ]
    for (selection, preferences, expected) in cases {
        test.expect(AppLanguage.resolve(selection: selection, preferredLanguages: preferences) == expected,
                    "语言协商 \(selection) / \(preferences)")
    }

    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory.appendingPathComponent("ProxyMirror.Localization.\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: directory) }
    let resourceRoot = directory.appendingPathComponent("Fixture.bundle", isDirectory: true)
    #if os(macOS)
    let resourceDirectory = resourceRoot.appendingPathComponent("Contents/Resources", isDirectory: true)
    let infoURL = resourceRoot.appendingPathComponent("Contents/Info.plist")
    #else
    let resourceDirectory = resourceRoot
    let infoURL = resourceRoot.appendingPathComponent("Info.plist")
    #endif
    for language in AppLanguage.allCases.map(\.rawValue) {
        try fileManager.createDirectory(at: resourceDirectory.appendingPathComponent(language + ".lproj"),
                                        withIntermediateDirectories: true)
        if !["en", "zh-Hans"].contains(language) {
            try "\"hello\" = \"Preview\";".write(to: resourceDirectory.appendingPathComponent(language + ".lproj/Fixture.strings"), atomically: true, encoding: .utf8)
        }
    }
    let info = ["CFBundleIdentifier": "com.proxymirror.localization-fixture.\(UUID().uuidString)", "CFBundleDevelopmentRegion": "en"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
    try #"""
    "hello" = "Hello";
    "fallback" = "English fallback";
    "percentage" = "100%% ready";
    "formatted_percentage" = "%ld%% ready";
    "message" = "%1$@ has %2$ld requests";
    """#.write(to: resourceDirectory.appendingPathComponent("en.lproj/Fixture.strings"), atomically: true, encoding: .utf8)
    try #"""
    "hello" = "你好";
    "percentage" = "已完成 100%%";
    "formatted_percentage" = "已完成 %ld%%";
    "message" = "%1$@ 有 %2$ld 条请求";
    """#.write(to: resourceDirectory.appendingPathComponent("zh-Hans.lproj/Fixture.strings"), atomically: true, encoding: .utf8)
    #if os(macOS)
    // Darwin caches a Bundle's resource inventory. Create every table before
    // constructing the Bundle or performing its first localization lookup.
    let plural: [String: Any] = [
        "requests": [
            "NSStringLocalizedFormatKey": "%#@count@",
            "count": [
                "NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "ld",
                "one": "%ld request", "other": "%ld requests"
            ]
        ]
    ]
    try PropertyListSerialization.data(fromPropertyList: plural, format: .xml, options: 0)
        .write(to: resourceDirectory.appendingPathComponent("en.lproj/Plural.stringsdict"))
    #endif
    guard let resources = Bundle(url: resourceRoot) else {
        test.expect(false, "创建真实测试资源 bundle")
        return
    }
    test.expect(LocalizationResources.hasLanguages(resources), "资源容器包含两套语言")
    let english = LocalizationContext(language: .english, resources: resources, regionLocale: Locale(identifier: "zh_CN"),
                                      reportMissing: { _, _ in })
    let chinese = LocalizationContext(language: .simplifiedChinese, resources: resources, reportMissing: { _, _ in })
    test.expect(english.render(table: "Fixture", key: "hello", englishFallback: "Wrong") == "Hello", "英文资源查询")
    test.expect(chinese.render(table: "Fixture", key: "hello", englishFallback: "Wrong") == "你好", "简中资源查询")
    let fallback = chinese.lookup(table: "Fixture", key: "fallback", englishFallback: "Wrong")
    test.expect(fallback.value == "English fallback" && fallback.language == .english && fallback.usedFallback,
                "简中缺项返回英文并记录实际命中语言")
    test.expect(chinese.render(table: "Fixture", key: "missing", englishFallback: "Readable English") == "Readable English",
                "整个资源缺项仍返回可读英文")
    test.expect(english.render(table: "Fixture", key: "percentage", englishFallback: "") == "100% ready",
                "静态百分比只反转义，不调用 printf")
    test.expect(chinese.render(table: "Fixture", key: "formatted_percentage", arguments: [37], englishFallback: "") == "已完成 37%",
                "带参数百分比使用正确格式化")
    test.expect(english.render(table: "Fixture", key: "message", arguments: ["Client", 2], englishFallback: "") == "Client has 2 requests",
                "参数类型与位置正确")
    test.expect(english.formattingLocale(for: .english).languageCode == "en",
                "中文地区设置下的英文语法使用英文 locale")

    let appURL = directory.appendingPathComponent("Broken.app", isDirectory: true)
    try fileManager.createDirectory(at: appURL.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.proxymirror.broken"], format: .xml, options: 0)
        .write(to: appURL.appendingPathComponent("Contents/Info.plist"))
    if let app = Bundle(url: appURL) {
        var queriedDevelopment = false
        let missing = LocalizationResources.resolve(in: app, developmentBundle: {
            queriedDevelopment = true
            return resources
        })
        test.expect(missing.bundle == nil && missing.issue != nil && !queriedDevelopment,
                    "发布 App 丢资源时不会提前求值开发目录回退")
        if let appResources = app.resourceURL {
            let embedded = appResources.appendingPathComponent(LocalizationResources.expectedBundleName, isDirectory: true)
            try fileManager.copyItem(at: resourceRoot, to: embedded)
            // Simulate a fresh app launch without reusing CFBundle's cached
            // identity for the original bundle that is still open above.
            let embeddedInfoURL = embedded.appendingPathComponent(infoURL.path.replacingOccurrences(of: resourceRoot.path + "/", with: ""))
            var embeddedInfo = info
            embeddedInfo["CFBundleIdentifier"] = "com.proxymirror.localization-embedded.\(UUID().uuidString)"
            try PropertyListSerialization.data(fromPropertyList: embeddedInfo, format: .xml, options: 0).write(to: embeddedInfoURL)
            let relocated = LocalizationResources.resolve(in: app, developmentBundle: {
                queriedDevelopment = true
                return nil
            })
            test.expect(relocated.bundle?.bundleURL == embedded && relocated.issue == nil && !queriedDevelopment,
                        "搬移后的 App 使用自带语言资源容器")
            let moved = LocalizationContext(language: .simplifiedChinese, resources: relocated.bundle, reportMissing: { _, _ in })
            test.expect(moved.render(table: "Fixture", key: "hello", englishFallback: "Wrong") == "你好",
                        "移动后语言查找不依赖原资源目录")
        } else { test.expect(false, "App 资源目录可定位") }
    } else { test.expect(false, "构造缺语言资源的 App bundle") }

    #if os(macOS)
    for count in [0, 1, 2, 101, 1000] {
        let formatted = count == 1000 ? "1,000" : String(count)
        let expected = "\(formatted) " + (count == 1 ? "request" : "requests")
        test.expect(english.render(table: "Plural", key: "requests", arguments: [count], englishFallback: "%ld requests") == expected,
                    "真实 Foundation 英文复数 \(count)")
    }
    #endif
}
