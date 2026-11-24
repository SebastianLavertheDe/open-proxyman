import Foundation

enum LocalizationResources {
    static let expectedBundleName = "ProxyMirror_ProxyMirrorCore.bundle"

    struct Resolution {
        let bundle: Bundle?
        let issue: String?
    }

    /// 发布 App 必须自带资源；仅命令行开发和单测可回退 SwiftPM 的构建目录。
    static func resolve(in mainBundle: Bundle = .main,
                        developmentBundle: (() -> Bundle?)? = nil) -> Resolution {
        if let resources = mainBundle.resourceURL {
            let url = resources.appendingPathComponent(expectedBundleName, isDirectory: true)
            if let bundle = Bundle(url: url), hasLanguages(bundle) { return Resolution(bundle: bundle, issue: nil) }
        }
        if mainBundle.bundleURL.pathExtension.lowercased() == "app" {
            return Resolution(bundle: nil,
                              issue: "ProxyMirror's language resources are missing or damaged. Reinstall the application.")
        }
        // 仅非 App 的隔离测试可显式指定资源根目录，不影响发布 App 的严格查找。
        if let path = ProcessInfo.processInfo.environment["PM_LOCALIZATION_RESOURCE_DIR"],
           let bundle = Bundle(path: path), hasLanguages(bundle) {
            return Resolution(bundle: bundle, issue: nil)
        }
        // 闭包必须延迟调用，避免丢资源的 .app 提前触发 Bundle.module 的 fatalError。
        let development = developmentBundle?() ?? swiftPackageBundle()
        if let development, hasLanguages(development) { return Resolution(bundle: development, issue: nil) }
        return Resolution(bundle: nil, issue: "ProxyMirror's language resources could not be loaded.")
    }

    static func languageBundle(_ language: AppLanguage, in bundle: Bundle) -> Bundle? {
        if let path = bundle.path(forResource: language.rawValue, ofType: "lproj") {
            return Bundle(path: path)
        }
        // SwiftPM normalizes processed localization directories (zh-hans.lproj).
        // Match only our supported identifiers, including on case-sensitive disks;
        // this does not permit an App to fall back to a development resource root.
        guard let root = bundle.resourceURL,
              let contents = try? FileManager.default.contentsOfDirectory(at: root,
                  includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        let name = (language.rawValue + ".lproj").lowercased()
        let matches = contents.filter {
            $0.lastPathComponent.lowercased() == name &&
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard matches.count == 1 else { return nil }
        return Bundle(url: matches[0])
    }

    static func hasLanguages(_ bundle: Bundle) -> Bool {
        AppLanguage.allCases.allSatisfy { language in
            guard let resource = languageBundle(language, in: bundle), let url = resource.resourceURL,
                  let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return false }
            return files.contains { $0.pathExtension == "strings" }
        }
    }

    private static func swiftPackageBundle() -> Bundle? {
        #if SWIFT_PACKAGE
        return .module
        #else
        return nil
        #endif
    }
}
