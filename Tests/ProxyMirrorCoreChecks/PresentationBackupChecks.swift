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

    var object = try JSONSerialization.jsonObject(with: backup.exportData()) as! [String: Any]
    var settings = object["settings"] as! [String: Any]
    var extras = settings["extras"] as! [String: Any]
    let invalidValues: [(String, Any)] = [("codeTabWidth", 0), ("codeTabWidth", 17),
                                         ("defaultCopyFormat", "unsupported"), ("monospacedFontFamily", "bad\0font")]
    for (key, invalid) in invalidValues {
        var changed = extras
        changed[key] = invalid
        settings["extras"] = changed
        object["settings"] = settings
        let invalidData = try JSONSerialization.data(withJSONObject: object)
        test.rejects(try RuleBackup.read(invalidData), with: RuleBackup.BackupError.self,
                     "备份导入拒绝无效 \(key)")
    }
    // Legacy backups lack these keys and must preserve the destination's preferences.
    for key in ["monospacedFontFamily", "codeTabWidth", "use24HourClock", "showFullDate", "showAlternatingRows", "defaultCopyFormat"] {
        extras.removeValue(forKey: key)
    }
    settings["extras"] = extras; object["settings"] = settings
    let (legacy, _) = try RuleBackup.read(JSONSerialization.data(withJSONObject: object))
    target.codeTabWidth = 2; target.defaultCopyFormat = .python
    legacy.settings?.apply(to: target)
    test.equal(target.codeTabWidth, 2, "旧备份缺省字段保留当前 Tab 宽度")
    test.equal(target.defaultCopyFormat, .python, "旧备份缺省字段保留当前复制格式")
}
