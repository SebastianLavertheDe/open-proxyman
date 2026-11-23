import Foundation
@testable import ProxyMirrorCore

func checkLocalizationStorage(_ test: CoreAssertions) throws {
    let directory = try makeCheckDirectory()
    let outside = try makeCheckDirectory()
    let suite = "ProxyMirror.LocalizationStorage.Check." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: outside)
    }
    let ca = directory.appendingPathComponent("CA", isDirectory: true)
    try FileManager.default.createDirectory(at: ca, withIntermediateDirectories: true)
    let certificate = ca.appendingPathComponent("preserved.pem")
    try Data("certificate and private key".utf8).write(to: certificate)
    let recovery = directory.appendingPathComponent("system-proxy-recovery.json")
    try Data("preserved recovery".utf8).write(to: recovery)
    let external = outside.appendingPathComponent("keep.txt")
    try Data("external user file".utf8).write(to: external)
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("Backups"), withDestinationURL: outside)
    let rules = directory.appendingPathComponent("rules.json")
    try Data("obsolete rules".utf8).write(to: rules)
    defaults.set("深色", forKey: "ui.appearance")
    defaults.set(8099, forKey: "proxy.port")
    defaults.set(["zh-Hans"], forKey: "AppleLanguages")
    defaults.set("keep", forKey: "systemProxy.recovery")

    try LocalizationStorage.prepare(defaults: defaults, supportDirectory: directory)
    test.expect(!FileManager.default.fileExists(atPath: rules.path), "Initial storage upgrade removes obsolete application rules")
    test.expect(defaults.object(forKey: "ui.appearance") == nil && defaults.object(forKey: "proxy.port") == nil,
                "Initial storage upgrade clears obsolete application preferences")
    test.equal(defaults.integer(forKey: LocalizationStorage.defaultsVersionKey), LocalizationStorage.currentVersion,
               "Storage version is recorded after a successful reset")
    test.equal(try String(contentsOf: certificate, encoding: .utf8), "certificate and private key", "Reset preserves CA material")
    test.equal(try String(contentsOf: recovery, encoding: .utf8), "preserved recovery", "Reset preserves system proxy recovery state")
    test.equal(try String(contentsOf: external, encoding: .utf8), "external user file", "Reset removes a named symlink without traversing its external target")
    test.equal(defaults.stringArray(forKey: "AppleLanguages"), ["zh-Hans"], "Reset preserves native per-app language preferences")
    test.equal(defaults.string(forKey: "systemProxy.recovery"), "keep", "Reset preserves non-application preference keys")

    defaults.set("dark", forKey: "ui.appearance")
    defaults.set("en", forKey: "ui.applicationLanguage")
    try Data("current rules".utf8).write(to: rules)
    try LocalizationStorage.prepare(defaults: defaults, supportDirectory: directory)
    test.equal(defaults.string(forKey: "ui.appearance"), "dark", "Repeated startup preserves current preferences")
    test.equal(defaults.string(forKey: "ui.applicationLanguage"), "en", "Language changes never trigger another reset")
    test.equal(try String(contentsOf: rules, encoding: .utf8), "current rules", "Repeated startup preserves current rule data")

    let marker = directory.appendingPathComponent(LocalizationStorage.markerName)
    try Data("999\n".utf8).write(to: marker)
    test.rejects(try LocalizationStorage.prepare(defaults: defaults, supportDirectory: directory), with: NSError.self,
                 "Future storage versions are rejected without resetting newer data")
    test.equal(try String(contentsOf: rules, encoding: .utf8), "current rules", "Unsupported storage never deletes current files")
    try Data("corrupted".utf8).write(to: marker)
    test.rejects(try LocalizationStorage.prepare(defaults: defaults, supportDirectory: directory), with: NSError.self,
                 "A corrupt marker is an error rather than a reason to reset")
    test.equal(try String(contentsOf: rules, encoding: .utf8), "current rules", "Marker read failure does not clear captured application data")
}

@MainActor
func checkLocalizationModelStorage(_ test: CoreAssertions) throws {
    test.equal(RewriteAction.HeaderOp.set.rawValue, "set", "Header operation IDs are stable English values")
    test.equal(TrafficCondition.Field.requestHeader.rawValue, "requestHeader", "Filter field IDs do not use localized labels")
    test.equal(TrafficCondition.Comparison.notContains.rawValue, "notContains", "Filter comparison IDs do not use localized labels")
    test.equal(TrafficConditionGroup.Mode.all.rawValue, "all", "AND/OR identity is independent of display language")
    test.equal(CustomTrafficColumn.Source.requestJSON.rawValue, "requestJSON", "Custom column IDs are language independent")
    test.equal(FilterChip.all.id, "all", "Filter chip identity is language independent")
    test.rejects(try JSONDecoder().decode(RewriteAction.HeaderOp.self, from: Data("\"设置\"".utf8)), with: DecodingError.self,
                 "Obsolete Chinese enum encodings are not accepted by the new storage format")
    let issue = OperationIssue.modelRuleNameInvalid
    let failure = RuleMutation.Failure(issue)
    test.equal(failure.localizedDescription, "Rule names must contain 1–512 bytes and no control characters.",
               "Model errors keep a stable English diagnostic for CLI and logs")
    test.equal(failure.operationIssue.code, "models.rule_name_invalid", "Model errors retain a stable code")
    test.equal(LocalizedErrorPresentation.message(for: failure), Strings.Models.ruleNameInvalid,
               "The GUI renders model errors from resources at the presentation boundary")
    let invalidOrganization = RuleOrganization(folders: [RuleFolder(tool: "dns", name: "", parentID: nil, enabled: nil)])
    test.equal(invalidOrganization.validationError, "Folders need a valid tool ID and name.",
               "Shared validators return stable diagnostics to machine callers")
    test.equal(invalidOrganization.localizedValidationError, Strings.Models.folderNameInvalid,
               "Shared validators expose a separate translated GUI message")
    let value = TrafficCondition(field: .method, comparison: .equals, value: "GET")
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(value)
    test.expect(String(decoding: encoded, as: UTF8.self).contains("\"method\""), "Encoded filters store IDs, not translated titles")
    _ = Strings.Models.fieldMethod
    test.equal(try encoder.encode(value), encoded, "Rendering a translated title never mutates encoded filter data")
    let restored = try JSONDecoder().decode(TrafficCondition.self, from: encoded)
    test.equal(restored, value, "New filter data has a lossless round trip")
    test.rejects(try RuleBackup.read(Data("{\"version\":1,\"noCaching\":true}".utf8)), with: RuleBackup.BackupError.self,
                 "Obsolete proprietary backup versions are rejected")
}
