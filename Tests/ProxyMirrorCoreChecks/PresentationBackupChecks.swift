import Foundation
@testable import ProxyMirrorCore

@MainActor
func checkPresentationBackup(_ test: CoreAssertions) throws {
    let sourceSuite = "ProxyMirror.PresentationBackup.Source.\(UUID().uuidString)"
    let targetSuite = "ProxyMirror.PresentationBackup.Target.\(UUID().uuidString)"
    let sourceDefaults = UserDefaults(suiteName: sourceSuite)!
    let targetDefaults = UserDefaults(suiteName: targetSuite)!
    defer {
        sourceDefaults.removePersistentDomain(forName: sourceSuite)
        targetDefaults.removePersistentDomain(forName: targetSuite)
    }
    let source = AppSettings(defaults: sourceDefaults)
    source.monospacedFontFamily = "Menlo"
    source.codeTabWidth = 8
    source.use24HourClock = false
    source.showFullDate = true
    source.showAlternatingRows = false
    source.defaultCopyFormat = .httpie
    source.fontSize = 18
    source.useMonospacedFont = false
    source.scrollBeyondLastLine = true
    source.contentLayout = "horizontal"
    source.appIconStyle = "mars"
    source.appearance = "dark"
    source.autoStartRecording = false
    source.warnBeforeQuit = true
    source.showUpdateNotifications = false
    source.applicationLanguage = "en"
    source.mcpEnabled = false
    source.mcpRedactSensitiveData = false
    source.preserveOriginalHeaders = true
    source.restorePreviousSystemProxy = false
    source.automaticTrafficCleanup = false
    source.cleanupMemoryLimitMB = 4096
    source.cleanupIntervalMinutes = 10
    let backup = RuleBackup(settings: .init(source))
    let (decoded, warnings) = try RuleBackup.read(backup.exportData())
    test.expect(warnings.isEmpty, "新增显示偏好随标准规则备份导出且不产生未知字段")
    let target = AppSettings(defaults: targetDefaults)
    decoded.settings?.apply(to: target)
    test.equal(target.monospacedFontFamily, "Menlo", "备份恢复字体选择")
    test.equal(target.codeTabWidth, 8, "备份恢复真实 Tab 宽度")
    test.expect(!target.use24HourClock && target.showFullDate, "备份恢复时间显示偏好")
    test.expect(!target.showAlternatingRows, "备份恢复斑马纹偏好")
    test.equal(target.defaultCopyFormat, .httpie, "备份恢复默认复制格式")
    test.expect(target.fontSize == 18 && !target.useMonospacedFont && target.scrollBeyondLastLine,
                "备份恢复字号、字体开关和末行外滚动")
    test.expect(target.contentLayout == "horizontal" && target.appIconStyle == "mars" && target.appearance == "dark",
                "备份恢复请求响应布局、应用图标及主题")
    test.expect(!target.autoStartRecording && target.warnBeforeQuit && !target.showUpdateNotifications
                && target.applicationLanguage == "en", "备份恢复启动、退出、更新与应用语言偏好")
    test.expect(!target.mcpEnabled && !target.mcpRedactSensitiveData && target.preserveOriginalHeaders,
                "备份恢复 MCP 与复制请求头偏好")
    test.expect(!target.restorePreviousSystemProxy && !target.automaticTrafficCleanup
                && target.cleanupMemoryLimitMB == 4096 && target.cleanupIntervalMinutes == 10,
                "备份恢复代理还原和自动清理策略")

    var object = try JSONSerialization.jsonObject(with: backup.exportData()) as! [String: Any]
    var settings = object["settings"] as! [String: Any]
    var extras = settings["extras"] as! [String: Any]
    let invalidValues: [(String, Any)] = [("codeTabWidth", 0), ("codeTabWidth", 17),
                                         ("defaultCopyFormat", "unsupported"), ("monospacedFontFamily", "bad\0font"),
                                         ("fontSize", 7), ("fontSize", 33), ("contentLayout", "diagonal"),
                                         ("appIconStyle", "unknown"), ("applicationLanguage", "invalid"),
                                         ("cleanupMemoryLimitMB", 63), ("cleanupMemoryLimitMB", 65537),
                                         ("cleanupIntervalMinutes", 0), ("cleanupIntervalMinutes", 61),
                                         ("appearance", "invalid")]
    for (key, invalid) in invalidValues {
        var changed = extras
        changed[key] = invalid
        settings["extras"] = changed
        object["settings"] = settings
        let invalidData = try JSONSerialization.data(withJSONObject: object)
        test.rejects(try RuleBackup.read(invalidData), with: RuleBackup.BackupError.self,
                     "备份导入拒绝无效 \(key)")
    }
    // Current-format partial preference snapshots preserve omitted destination settings.
    for key in ["monospacedFontFamily", "codeTabWidth", "use24HourClock", "showFullDate", "showAlternatingRows", "defaultCopyFormat",
                "fontSize", "useMonospacedFont", "scrollBeyondLastLine", "contentLayout", "appIconStyle", "autoStartRecording",
                "warnBeforeQuit", "showUpdateNotifications", "applicationLanguage", "mcpEnabled", "mcpRedactSensitiveData",
                "preserveOriginalHeaders", "restorePreviousSystemProxy", "automaticTrafficCleanup", "cleanupMemoryLimitMB",
                "cleanupIntervalMinutes", "appearance"] {
        extras.removeValue(forKey: key)
    }
    settings["extras"] = extras; object["settings"] = settings
    let (partial, _) = try RuleBackup.read(JSONSerialization.data(withJSONObject: object))
    target.codeTabWidth = 2; target.defaultCopyFormat = .python
    target.fontSize = 14; target.mcpRedactSensitiveData = true; target.applicationLanguage = "zh-Hans"
    partial.settings?.apply(to: target)
    test.equal(target.codeTabWidth, 2, "新版部分备份省略字段保留当前 Tab 宽度")
    test.equal(target.defaultCopyFormat, .python, "新版部分备份省略字段保留当前复制格式")
    test.expect(target.fontSize == 14 && target.mcpRedactSensitiveData && target.applicationLanguage == "zh-Hans",
                "新版部分备份省略字段保留现有新增偏好")

    target.port = 9091; target.warnBeforeQuit = true; target.showMenuBarIcon = true
    target.resetAppearanceDefaults()
    test.expect(target.fontSize == 12 && target.useMonospacedFont && !target.scrollBeyondLastLine
                && target.appIconStyle == "earth" && target.appearance == "system",
                "外观重置恢复默认显示配置")
    test.expect(target.port == 9091 && target.warnBeforeQuit && target.showMenuBarIcon
                && target.defaultCopyFormat == .python && target.applicationLanguage == "zh-Hans",
                "外观重置保留代理、常规、导出和语言偏好")
}
