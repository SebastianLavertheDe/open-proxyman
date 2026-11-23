import Foundation
@testable import ProxyMirrorCore

func checkToolLocalization(_ test: CoreAssertions) {
    test.equal(ToolKind.compose.rawValue, "compose", "Tool identity is independent of its display language")
    test.equal(ToolKind.mapLocal.rawValue, "mapLocal", "Map Local uses a stable storage identifier")
    test.equal(HelpGuideTopic.https.rawValue, "https", "Help navigation uses a topic identifier rather than translated text")
    let aliases = ToolKind.compose.searchAliases
    test.expect(aliases.contains { $0.localizedCaseInsensitiveContains("Compose Request") },
                "The command palette can find Compose using its English title")
    test.expect(aliases.contains { $0.contains("构建请求") },
                "The command palette can find Compose using its Chinese title")

    func render(_ key: String, _ language: String, _ arguments: [CVarArg] = []) -> String {
        L10n.render(table: "Tools", key: key, arguments: arguments,
                    englishFallback: "Missing tool localization", language: language)
    }
    let raw = "/tmp/用户数据/100% original\\n.pem"
    test.equal(render("certificate_subject", "en", [raw]), "Subject: " + raw,
               "Translated certificate labels preserve the original value and percent characters")
    test.equal(render("certificate_subject", "zh-Hans", [raw]), "主题：" + raw,
               "The Chinese label does not translate certificate subject data")
    test.equal(render("state_enabled", "en"), "Enabled", "Rule status does not reuse an Enable action label")
    test.equal(render("state_disabled", "en"), "Disabled", "Rule status does not reuse a Close action label")
    test.equal(render("random_disconnect", "en"), "Random Disconnect (%)",
               "Literal percent characters are displayed without formatting")

    #if os(macOS)
    // 复数必须由真实 Foundation 读取 stringsdict，不能用测试桩模拟词尾。
    for count in [0, 1, 2, 101, 1000] {
        let english = "\(count) " + (count == 1 ? "request" : "requests")
        test.equal(render("requests", "en", [count]), english, "English tool counts select native plural forms")
        test.equal(render("requests", "zh-Hans", [count]), "\(count) 个请求", "Chinese tool counts use the other plural form")
    }
    #endif

    let help = render("scripting_api_help", "en")
    test.expect(help.contains("require('@proxymirror/http')") && help.contains("timeoutMs"),
                "Script help preserves executable API names")
    test.expect(!help.contains("直接编辑"), "The complete script API help has an English translation")
}
