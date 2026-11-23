import Foundation

/// Stable page identity used by navigation, search and snapshot selection.
enum PreferencesPage: String, CaseIterable, Identifiable {
    case general, appearance, privacy, mcp, github, tools, networkExtension, advanced, workspace, products

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return Strings.Settings.general
        case .appearance: return Strings.Settings.appearance
        case .privacy: return Strings.Settings.privacy
        case .mcp: return "MCP"
        case .github: return "GitHub"
        case .tools: return Strings.Settings.tools
        case .networkExtension: return Strings.Settings.networkExtension
        case .advanced: return Strings.Settings.advanced
        case .workspace: return Strings.Settings.workspace
        case .products: return Strings.Settings.products
        }
    }

    // 双语别名用于跨界面语言检索；页面身份仍是稳定 rawValue。
    var searchAliases: String {
        switch self {
        case .general: return "常规 General"
        case .appearance: return "外观 Appearance"
        case .privacy: return "隐私 Privacy"
        case .mcp: return "MCP Model Context Protocol"
        case .github: return "GitHub"
        case .tools: return "工具 Tools"
        case .networkExtension: return "网络扩展 Network Extension"
        case .advanced: return "高级 Advanced"
        case .workspace: return "工作区 Workspace"
        case .products: return "产品 Products"
        }
    }

}
