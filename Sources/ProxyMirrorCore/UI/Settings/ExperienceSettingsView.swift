import SwiftUI

struct ExperienceSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
            Text("显示与复制").font(.headline)
            Toggle("在菜单栏显示图标", isOn: binding(\.showMenuBarIcon))
            Toggle("底部栏显示内存和实时传输速率", isOn: binding(\.showResourceUsage))
            Toggle("隐藏 Apple 后台流量", isOn: binding(\.hideAppleTraffic))
            Picker("列表与 URL 截断位置", selection: Binding(get: { settings.truncationStyle }, set: { settings.truncationStyle = $0 })) {
                Text("开头").tag("head"); Text("中间").tag("middle"); Text("末尾").tag("tail")
            }
            Toggle("正文自动换行", isOn: binding(\.wordWrap))
            Toggle("正文显示空白字符", isOn: binding(\.showInvisibles))
            Toggle("正文显示缩略导航", isOn: binding(\.showMinimap))
            }
            Group {
                Divider()
                Picker("等宽字体", selection: Binding(get: { settings.monospacedFontFamily }, set: { settings.monospacedFontFamily = $0 })) {
                    Text("系统等宽字体").tag("")
                    ForEach(PresentationFonts.availableFamilies, id: \.self) { Text($0).tag($0) }
                    if !settings.monospacedFontFamily.isEmpty && !PresentationFonts.availableFamilies.contains(settings.monospacedFontFamily) {
                        Text("\(settings.monospacedFontFamily)（不可用，使用系统字体）").tag(settings.monospacedFontFamily)
                    }
                }
                Stepper("Tab 宽度：\(settings.codeTabWidth) 个空格", value: Binding(get: { settings.codeTabWidth }, set: { settings.codeTabWidth = $0 }), in: 1...16)
                Text("字体应用于正文、原文、脚本和请求列表。Tab 宽度应用于文本预览及脚本编辑器，并保留实际制表符。").font(.caption).foregroundStyle(.secondary)
                Toggle("使用 24 小时制", isOn: binding(\.use24HourClock))
                Toggle("时间显示完整日期", isOn: binding(\.showFullDate))
                Toggle("请求列表显示斑马纹", isOn: binding(\.showAlternatingRows))
                Picker("默认复制格式（⌘C）", selection: Binding(get: { settings.defaultCopyFormat }, set: { settings.defaultCopyFormat = $0 })) {
                    ForEach(RequestCode.Format.allCases) { Text($0.title).tag($0) }
                }
            }
            Group {
            Divider()
            Toggle("复制和导出时脱敏敏感头", isOn: binding(\.redactSensitiveHeaders))
            Toggle("复制命令时追加本机 --proxy", isOn: binding(\.appendProxyToCommands))
            Toggle("重复请求禁用缓存", isOn: binding(\.noCacheOnRepeat))
            Toggle("给上游请求附加 ProxyMirror 诊断头", isOn: binding(\.appendDiagnosticHeaders))
            }
        }
    }
    private func binding(_ key: ReferenceWritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: key] }, set: { settings[keyPath: key] = $0 })
    }
}
