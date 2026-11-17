import AppKit
import SwiftUI

/// Proxyman 实测配色（证据：Assets.car via assetutil，见 UI-SPEC.md §1）
/// 全部为动态颜色，自动适配深浅色。
enum ProxymanTheme {
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: appearanceColor(light: light, dark: dark))
    }

    private static func appearanceColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    // 状态色
    static let status2xx = dynamic(light: NSColor(hex: 0x34C759), dark: NSColor(hex: 0x5AB45B))
    static let status3xx = dynamic(light: NSColor(hex: 0xFFCC00), dark: NSColor(hex: 0xFFB400))
    static let status4xx = Color(nsColor: .systemOrange)
    static let status5xx = Color(nsColor: .systemRed)

    // 方法徽章
    static let methodGET = Color(nsColor: NSColor(hex: 0x4CD137))
    static let methodPOST = Color(nsColor: .systemBlue)
    static let methodPUT = Color(nsColor: .systemOrange)
    static let methodDELETE = Color(nsColor: .systemRed)
    static let methodPATCH = Color(nsColor: .systemPurple)
    static let methodChipBackground = dynamic(light: NSColor(hex: 0xE6E5E6), dark: NSColor(hex: 0x3A3B3E))
    static let methodChipText = dynamic(light: NSColor(hex: 0x737373), dark: NSColor(hex: 0xD9D9D9))

    // JSON 树 / Raw 内容
    static let jsonKey = dynamic(light: NSColor(hex: 0x1565C0), dark: NSColor(hex: 0x86BFA3))
    static let jsonString = dynamic(light: NSColor(hex: 0xC13D2A), dark: NSColor(hex: 0xFF8170))
    static let jsonNumber = dynamic(light: NSColor(hex: 0xAA78D0), dark: NSColor(hex: 0xA89CF7))
    static let jsonBoolNull = dynamic(light: NSColor(hex: 0xFE9926), dark: NSColor(hex: 0xF174A8))
    static let rawFullURL = dynamic(light: NSColor(hex: 0x990055), dark: NSColor(hex: 0xA89CF7))

    // 主窗口
    static let toolbarBackground = dynamic(light: NSColor(hex: 0xF1F1F1), dark: NSColor(hex: 0x383838))
    static let sidebarBackground = dynamic(light: NSColor(hex: 0xF1F1F1), dark: NSColor(hex: 0x4C4C4C))
    static let headerBackground = dynamic(light: NSColor(hex: 0xEAEAEA), dark: NSColor(hex: 0x1E1E1E))
    static let tableBackgroundColor = appearanceColor(light: .white, dark: NSColor(hex: 0x1E1E1E))
    static let tableAlternateColor = appearanceColor(light: NSColor(hex: 0xF3F3F3), dark: NSColor(hex: 0x2C2C2C))
    static let tableBackground = Color(nsColor: tableBackgroundColor)
    static let inspectorChrome = dynamic(light: NSColor(hex: 0xF1F1F1), dark: NSColor(hex: 0x282828))
    static let paneDivider = dynamic(light: NSColor(hex: 0xC4C4C4), dark: NSColor(hex: 0x141414))
    static let tableSelectionColor = appearanceColor(light: NSColor(hex: 0x2461CE), dark: NSColor(hex: 0x1E59D1))
    static let sidebarSelection = dynamic(light: NSColor(hex: 0xD7D7D7), dark: NSColor(hex: 0x686868))
    static let controlBackground = dynamic(light: NSColor(hex: 0xD8D8D8), dark: NSColor(hex: 0x656565))
    static let rowHeight: CGFloat = 24
    static let bottomBarHeight: CGFloat = 35

    // 详情面板
    static let contentBackground = dynamic(light: NSColor(hex: 0xECECEC), dark: NSColor(hex: 0x2E2F31))
    static let topBarBackground = dynamic(light: NSColor(hex: 0xF7F5F7), dark: NSColor(hex: 0x202122))
    static let prettyTextBackground = dynamic(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x292A2F))
    static let statusText = dynamic(light: NSColor(hex: 0x666666), dark: NSColor(hex: 0xC4C6C9))

    static func methodColor(_ method: String) -> Color {
        switch method {
        case "GET": return methodGET
        case "POST": return methodPOST
        case "PUT": return methodPUT
        case "DELETE": return methodDELETE
        case "PATCH": return methodPATCH
        default: return Color(nsColor: .systemGray)
        }
    }

    static func statusColorNS(status: Int, failed: Bool, completed: Bool) -> NSColor {
        if failed { return NSColor.systemRed }
        if !completed { return NSColor.systemGray }
        switch status {
        case 200...299: return NSColor(hex: 0x34C759)
        case 300...399: return NSColor(hex: 0xFFCC00)
        case 400...499: return NSColor.systemOrange
        case 500...599: return NSColor.systemRed
        default: return NSColor.systemGray
        }
    }

    static func methodColorNS(_ method: String) -> NSColor {
        switch method {
        case "GET": return NSColor(hex: 0x4CD137)
        case "POST": return .systemBlue
        case "PUT": return .systemOrange
        case "DELETE": return .systemRed
        case "PATCH": return .systemPurple
        default: return .systemGray
        }
    }

    static func statusColor(status: Int, failed: Bool, completed: Bool) -> Color {
        if failed { return .red }
        if !completed { return Color(nsColor: .systemGray) }
        switch status {
        case 200...299: return status2xx
        case 300...399: return status3xx
        case 400...499: return status4xx
        case 500...599: return status5xx
        default: return Color(nsColor: .systemGray)
        }
    }

    /// Highlight 子菜单六色（行标记）
    static let highlightNames = ["Red", "Yellow", "Green", "Blue", "Purple", "Gray"]
    static func highlightColor(_ name: String) -> Color {
        switch name {
        case "Red": return .red
        case "Yellow": return .yellow
        case "Green": return .green
        case "Blue": return .blue
        case "Purple": return .purple
        case "Gray": return .gray
        default: return .clear
        }
    }
}

extension NSColor {
    convenience init(hex: Int, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: alpha)
    }
}

extension Transaction {
    /// Flow ▸ Highlight 的标记色名（Red/Yellow/...），nil=无（属性本体在 Transaction 中）
}
