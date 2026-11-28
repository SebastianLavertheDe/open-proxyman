import Foundation

/// 只读产物检查入口，不创建窗口、启动监听或重置用户存储。
enum LocalizationDiagnostics {
    static func runIfRequested(_ arguments: [String]) -> Int32? {
        guard arguments.first == "--check-localization" else { return nil }
        guard arguments.count == 1 else {
            FileHandle.standardError.write(Data("Usage: ProxyMirror --check-localization\n".utf8))
            return 2
        }
        let resolution = LocalizationResources.resolve()
        guard let resources = resolution.bundle, L10n.startupIssue == nil else {
            FileHandle.standardError.write(Data(((resolution.issue ?? L10n.startupIssue ?? "Missing language resources.") + "\n").utf8))
            return 78
        }
        let counts: [[String: Any]] = [0, 1, 2, 101, 1000].map {
            ["count": $0, "text": Strings.Diagnostics.selectedCount($0)]
        }
        let result: [String: Any] = [
            "version": 1,
            "language": L10n.effectiveLanguage,
            "resourceBundle": resources.bundleURL.path,
            "label": Strings.Diagnostics.interfaceLabel,
            "counts": counts,
        ]
        do {
            var data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
            return 0
        } catch {
            FileHandle.standardError.write(Data("Unable to encode localization diagnostics.\n".utf8))
            return 1
        }
    }
}
