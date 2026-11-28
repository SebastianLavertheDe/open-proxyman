# ProxyMirror 简体中文和英文本地化方案

审查日期：2026-11-23。目标平台：macOS 13 及以上。

审查基线为当日 17:46 CST 的 main 工作区，HEAD 为 `e2a9100aa76274985beffa68150343a1a79fe974`，包括当时未提交和未跟踪的源码。下面的审查章节保留改造前的基线，代码行号不是实施后的现状。

开发已按本方案落地，当前为 2,164 个 key、14 张双语资源表和 25 个复数 key。源码改造与当前环境可执行的检查已经完成；macOS 完整构建、原生复数及签名 UI 产物验收尚待在 Mac 执行。实际文件、验证证据和执行命令见 [本地化实施记录](localization-implementation.md)。

## 推荐决策

首版提供 `zh-Hans` 和 `en` 两套完整界面，采用 Apple 原生 `.strings`、`.stringsdict` 和 `InfoPlist.strings`，通过 SwiftPM 管理资源，以稳定语义 key 和带类型的 Swift 接口访问。保留现有 `ui.applicationLanguage` 偏好和 `system / zh-Hans / en` 三个值，语言变更在下次启动生效。

按用户确认，旧版本地设置、规则、过滤器和其他应用自有历史数据允许全部清空，不要求迁移或读取旧格式。新版直接将内部存储标识统一为稳定英文 ID，中文和英文只作为界面显示值。新数据仍须在两种界面语言间保持一致。

这条路线直接适配当前 `swift build` 加 shell 组装 `.app` 的发布方式。现有 `L10n` 可以保留为访问接口，但其中的中文到英文字典应迁走，不能继续作为长期翻译来源。首版不引入自建翻译引擎或运行时翻译服务。

Apple 在现代 Xcode 中推荐 String Catalog。当前项目首版选择原生字符串表，是对现有构建方式的适配；将来切换 `.xcstrings` 时保留相同 key、调用接口和验收标准，只替换资源维护及编译流程。[Apple String Catalog 文档](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog)

首发必须同时完成资源打包、新存储格式与一次性重置、动态文本、错误与帮助文案，以及两个语言下的 macOS 产物验收。只翻译设置页或给现有字符串外包一层 `L10n.string`，不足以宣称支持双语。

## 当前项目审查结果

### 已有基础

| 能力 | 当前状态 | 位置 |
| --- | --- | --- |
| 语言偏好 | 已允许 system、zh-Hans、en，默认 system | `Sources/ProxyMirrorCore/Model/AppSettings.swift:35,234–236` |
| 翻译入口 | `L10n.string / format`，快照中有 277 对静态中英文映射 | `Sources/ProxyMirrorCore/UI/PresentationLocalization.swift:5–23` |
| 局部界面接入 | 设置组件及部分菜单、帮助按钮开始使用 L10n；交付前复核时，App 已增加语言偏好的观察和 Scene locale 注入 | `UI/Settings/SettingsView.swift`、`PreferencesComponents.swift`、`Sources/ProxyMirrorCore/DesktopApplication/ProxyMirrorApp.swift` |
| 备份语言偏好 | 语言字段可选，校验允许值，导入旧备份时保留目标端原偏好 | `Export/RuleBackup.swift:93,113,144,189` |
| 相关测试 | 已有语言备份、非法值、旧备份与外观重置的测试 | `Tests/ProxyMirrorCoreChecks/PresentationBackupChecks.swift:26–114` |

表中没有完整路径的源码均位于 `Sources/ProxyMirrorCore/`。语言偏好的 key 和三个允许值可以继续使用；表中旧备份兼容行为是现状记录，不作为新版实现要求。备份测试按新格式调整。

### 必须解决的问题

下面的优先级针对双语首发；“阻断”表示不能带着该问题宣称完整支持双语。

| 优先级 | 审查发现和代码证据 | 影响与处理 |
| --- | --- | --- |
| 阻断 | `PresentationLocalization.swift:8–12` 只看首选语言列表第一项，所有 zh 前缀都当简中 | 无法正确处理第一语言不支持、第二语言支持等情况。独立实现、测试完整语言协商，并明确繁体回退规则 |
| 阻断 | 同文件 `15–16` 用中文原文查字典，缺失时直接返回中文 | 英文界面漏译不会暴露；原本英文的文案在简中模式也无法自动变中文。改为稳定 key，两语言同等完整 |
| 高 | 基线 `ProxyMirrorApp.swift:186` 曾将插值后的“打开对比池”用作查询 key；交付前复核已改为 format 调用 | 此处修正不代表动态文本已全部完成。仍须全面替换动态查询 key，增加类型约束和复数资源 |
| 阻断 | `Package.swift:8–10,30–49` 无 defaultLocalization 和 resources；打包脚本尚未复制 Core 的 SwiftPM resource bundle | 交付前脚本已新增 CFBundleLocalizations 和顶层 lproj 复制逻辑，但未见实际语言资源文件。这不等于 Core 包资源已可用，仍需独立、可搬移的产物验证 |
| 高 | `TrafficConditions.swift:6–21,179–182`、`CustomTrafficColumn.swift:4–6`、`RuleStores.swift:15–19` 的中文 rawValue 已参与 Codable | 旧数据可清空，直接把内部编码规范为 method、contains、set 等稳定英文 ID；另设显示名，不实现旧中文值兼容 |
| 高 | `SettingsView.swift:3–5` 与 `AppSettings.swift:194–197` 将外观名称以中文持久化 | 清空旧外观偏好，新值统一为 system、light、dark；显示值通过资源获取 |
| 高 | `L10n` 每次从 AppSettings.shared 读取语言，当前 App 已观察语言并注入 locale，但仍缺完整生效及状态保留合同 | 观察设置不等于所有窗口、菜单和原生控件同步更新。首版建议冻结本次启动语言，设置变更只影响下次启动；如保留热切换必须按专项标准验收 |
| 高 | `SettingsSearchTarget.swift:11–62` 索引以中文标题和手工混合关键词为主 | 英文界面可能出现“看得见、搜不到”。按稳定 target ID 建双语索引 |
| 高 | `MainWindow.swift:490–507` 命令面板用显示文本作字典键、排序和搜索依据 | 翻译可能改变身份与查找。使用稳定 command ID、窗口 ID，以及独立的本地化标题和别名 |
| 高 | `HelpGuideView.swift:26,32,44` 用中文 topic 字符串控制分支 | 翻译标题可能改变功能。业务分支直接 switch enum case，标题与正文单独本地化 |
| 高 | helper/XPC 返回已渲染中文；例如 `ProxyMirrorSystemProxyHelper/main.swift:31–65` 与 `SystemProxy.swift:121–164` | 错误失去结构，App 难以按语言展示。使用稳定 domain/code/参数，最后由 App 渲染 |
| 高 | `CertificatePlatformGuides.swift:10–104`、多种 LocalizedError、NSAlert 与文件面板自定义文案仍直接构造字符串 | 非 View 文案也必须纳入；不能只扫描 Text、Button |
| 中 | `PresentationSettings.swift:44–64` 默认 en_US_POSIX；`WorkbenchUtilities.swift:45–46` 使用字节格式器 | 需要区分界面语言、用户地区与机器格式，不应切语言时顺带改变抓包数据和导出 |
| 中 | 固定标签宽度、侧栏宽度、弹出窗宽度，见 `PreferencesComponents.swift:54–60`、`SettingsView.swift:34,57`、`ProxyStatusPopover.swift:95` | 英文长度和较大字体可能导致截断，需逐页检查布局、Tooltip 和 VoiceOver |
| 中 | `Scripts/test_app_bundle.py:121–125` 用中文子串判断未授权；若干证书、设置测试也断言中文 | 行为测试应断言退出码、错误码或状态，双语文案另测，避免语言一变就误报行为失败 |

### 全面迁移范围

这次审查覆盖了 App 入口、69 个 UI Swift 文件，以及模型、拦截规则、系统集成、导出、自动化、helper 和构建测试。实现时建立逐条文案清单，不能把“277 对词典”当作全部产品文案。

| 范围 | 主要文件或目录 | 必须检查的内容 |
| --- | --- | --- |
| App 和所有 Scene | `ProxyMirrorApp.swift` | Commands、菜单栏图标菜单、Settings、所有 Window 和 WindowGroup、独立详情窗口标题 |
| 主窗口和状态 | `MainWindow.swift`、`ProxyStatusPopover.swift` | 工具栏、底栏、监听与录制状态、分屏、空状态、批量操作、命令面板 |
| 流量与来源 | `UI/List/`、`UI/Sidebar/` | 表头、筛选项、上下文菜单、来源与 Saved 文件夹、选择计数；用户命名保持原样 |
| 详情检查器 | `UI/Detail/` | 请求/响应、正文、查询、时间线、Diff、WebSocket、SSE、gRPC、Protobuf、MessagePack、预览与截断提示 |
| 全部设置 | `UI/Settings/` | 页面、标签、选项、说明、搜索、校验、连接/隐私/网络扩展/清理/MCP/GitHub/Workspace 设置 |
| 规则工具 | `UI/Tools/`、`Interception/` | Map Local/Remote、Rewrite、断点、脚本、DNS、反向代理、限速、证书、规则组织、规则摘要 |
| 其他工具 | `ToolWindows.swift`、`FlowSummaryView.swift`、`AutomationDashboardView.swift` 等 | Compose、汇总、导入导出、备份、Gist、自动化、代码复制、自定义列与预览器 |
| 帮助和设备指南 | `HelpGuideView.swift`、`CertificatePlatformGuides.swift`、模拟器安装相关文件 | 整段帮助、步骤、错误恢复、链接标题、可复制命令附近的说明 |
| 系统和错误 | `System/`、`App/AppState.swift`、`Export/` | 权限、证书、代理、安装、更新、文件 I/O、导入失败、操作反馈 |
| 原生和辅助功能 | NSAlert、NSOpenPanel、NSSavePanel、NSTableView 等使用点 | 自有标题、按钮、说明、Tooltip、Accessibility label/value/hint，以及 representable 内创建的文字 |
| App 元数据与扩展 | `make_app.sh`、`Resources/TransparentExtension/Info.plist` | 用途说明、文件类型描述、扩展显示名及各自的 InfoPlist.strings |
| 自动化及导出边界 | `LocalControl.swift`、`MCPProtocol.swift`、`AutomationControl.swift`、`ExportService.swift` | 区分人类界面、机器标识、技术原文与用户数据，按下文合同保护 |

## 技术选型和资源组织

### 选型比较

| 方式 | 对本项目的评价 | 结论 |
| --- | --- | --- |
| 当前中文到英文字典 | 容易局部接入，但缺少稳定 key、复数、上下文和标准翻译资源；还会静默漏译 | 只作为迁移输入，随后删除 |
| 原生 strings 和 stringsdict | 支持标准 Foundation/SwiftUI 资源查找与复数；可由 SwiftPM 处理，适配现有命令行构建 | 首版唯一维护源 |
| String Catalog | Apple 推荐的现代 Xcode 编辑流程，便于翻译状态、注释和复数管理 | 构建链验证后可替换资源维护格式 |
| 第三方运行时框架或远程翻译 | 本项目目前不需要动态下发语言包等能力 | 首版不引入 |

SwiftPM 本地化需要声明 `defaultLocalization`，并通过 `Bundle.module` 访问包资源。单纯创建目录不等于应用已经能找到这些资源。[Apple 包资源本地化文档](https://developer.apple.com/documentation/xcode/localizing-package-resources)

不能把“Xcode 中可编译 xcstrings”推导为“当前所有 swift build 后端都会完成同样的处理”。本项目尚未固定发布工具链，也没有这条资源编译验证。后续采用 Catalog 的条件为：固定 macOS/Xcode 版本与构建后端，通过原生构建或显式 `xcstringstool` 编译生成资源，再通过同一套移动产物测试。不要同时手改 Catalog 和导出的 strings；应始终只有一个翻译维护源。[Apple 命令行工具说明](https://developer.apple.com/documentation/xcode/xcode-command-line-tool-reference)

### 文件组织

建议沿用 Core 承载 UI 的结构，不为本地化拆分业务模块：

```text
Sources/ProxyMirrorCore/
  Localization/
    AppLanguage.swift
    LocalizationContext.swift
    LocalizationResources.swift
    LocalizedErrorPresentation.swift
    Generated/Strings.swift
  Resources/
    en.lproj/
      Common.strings
      Menus.strings
      Settings.strings
      Traffic.strings
      Traffic.stringsdict
      Detail.strings
      Tools.strings
      Errors.strings
      Guides.strings
    zh-Hans.lproj/
      同名的双语资源
Resources/
  en.lproj/InfoPlist.strings
  zh-Hans.lproj/InfoPlist.strings
  TransparentExtension/
    Info.plist
    en.lproj/InfoPlist.strings
    zh-Hans.lproj/InfoPlist.strings
Scripts/
  check_localization.py
  generate_localization.sh
  Templates/localization-swift5.stencil
Tests/ProxyMirrorCoreChecks/
  LocalizationChecks.swift
  LocalizationStorageChecks.swift
swiftgen.yml
```

以上是计划新增的位置。顶层 `Resources/en.lproj` 和 `zh-Hans.lproj` 是供 shell 打包主 App 元数据使用的输入，复用当前新增的打包逻辑，与 Core 的资源 bundle 分开；实际布局可按第一批验证结果调整。长篇帮助可继续使用 Guides.strings 保存完整段落；如果确实拆成 Markdown，每个主题用稳定文件名，两种语言必须有对应文件，并使用同一资源解析器，不能另建语言选择逻辑。

Package.swift 的目标变更为：

```swift
let package = Package(
    name: "ProxyMirror",
    defaultLocalization: "en",
    // 保留当前 platforms、products 和 dependencies。
    // 在现有 ProxyMirrorCore target 中增加：
    // resources: [.process("Resources")]
)
```

这是改动位置示意，不是替换现有 manifest 的完整代码。业务依赖与 macOS 13 最低版本保持现状。

### 稳定 key 和类型化访问

使用 `settings.language.title`、`traffic.selection.count`、`errors.proxy.bindFailed` 等语义 key。中文和英文都是 value；修改措辞不改 key。同一个词在不同含义下使用不同 key，例如“应用设置”的动词与“应用程序”的名词分开。

资源示例：

```text
/* Settings.strings，zh-Hans；设置页中的应用语言标签 */
"settings.language.title" = "应用语言";

/* Settings.strings，en */
"settings.language.title" = "Application Language";

/* Errors.strings，zh-Hans；参数依次为端口和技术原因 */
"errors.proxy.bindFailed" = "无法监听端口 %1$ld：%2$@";

/* Errors.strings，en */
"errors.proxy.bindFailed" = "Unable to listen on port %1$ld: %2$@";
```

统一生成带类型的访问接口，例如 `Strings.Settings.settingsLanguageTitle`、`Strings.Errors.proxyBindFailed(port, reason)`。名称以最终生成结果为准。不要让业务调用方任意传格式字符串或 CVarArg，也不要在代码中拼接“条”“requests”“失败”等句子片段。

建议使用固定版本的 SwiftGen 生成访问器。它支持 strings、stringsdict 和参数类型解析；作为开发及 CI 工具使用，生成结果提交仓库，普通编译和用户运行不依赖它。生成器版本、下载来源及校验和固定在生成脚本中。[SwiftGen 字符串解析器说明](https://github.com/SwiftGen/SwiftGen/blob/stable/Documentation/Parsers/strings.md)

SwiftGen 默认模板在 SwiftPM 下使用 Bundle.module，但它不负责本项目的显式语言选择，而且格式化仍使用 Locale.current。仅设置 `lookupFunction` 只替换查找步骤，不能接管格式化。因此首版明确维护一个很小的自定义模板，让生成代码中的查询和参数格式化都委托给统一上下文。只从 en 资源生成一套 Swift API，zh-Hans 由检查器验证同构；生成的静态值只在启动语言初始化后首次求值。[SwiftGen 官方模板](https://raw.githubusercontent.com/SwiftGen/SwiftGen/stable/Sources/SwiftGenCLI/templates/strings/structured-swift5.stencil)

建议生成配置如下，模板在保留上游类型生成逻辑的基础上，只替换最终 render 入口；固定上游版本并保留其许可证信息。第一批验证样例必须覆盖这个自定义入口，不能用默认模板跑通就标记完成。

```yaml
strings:
  inputs:
    - Sources/ProxyMirrorCore/Resources/en.lproj
  outputs:
    - templatePath: Scripts/Templates/localization-swift5.stencil
      output: Sources/ProxyMirrorCore/Localization/Generated/Strings.swift
      params:
        enumName: Strings
        forceFileNameEnum: true
```

模板生成的私有 render 调用传入 `table / key / arguments / englishFallback`，由冻结的 LocalizationContext 返回最终 String。这样所有格式化只维护一份，不会在生成器、View 和错误展示中各写一套。

当工具尚未引入时，第一批可以用少量手写访问器做验证，但不得因此长期保留两套文案来源。生成器只负责代码，不负责机器翻译。

### 资源查询和缺失处理

`LocalizationContext` 在应用启动时初始化一次，至少包含 `effectiveLanguage`、对应语言资源 bundle、英文资源 bundle 与界面格式策略。它不依赖某个 View，不在每次查询时读取 UserDefaults，也不从代理数据面直接访问全局设置。

查找顺序为“本次运行语言的资源 → 英文资源 → 随生成代码提供的英文 fallback”。查询结果保留实际命中的语言；例如简中缺项回退英文时，格式化采用英文语法和复数规则，地区数字策略另外应用。每个语言的 bundle 从资源容器中的指定 `.lproj` 解析，不能仅靠 `String(localized:…, locale:…)` 指望改变资源语言：该参数在相关 String API 中用于格式化插值，不等同于切换查找的 bundle。[Apple String 初始化器说明](https://developer.apple.com/documentation/swift/string/init(localized:options:table:bundle:locale:comment:))

开发和 CI 对未知 key、缺语言、空译文、缺资源立即失败；发行版遇到单项缺译返回英文并记录稳定 key，避免给用户显示 key 或崩溃。日志不记录用户插值参数。整个资源 bundle 缺失属于打包错误，应被产物检查阻断；正常发行运行时也应给出明确的安装损坏诊断。

已经翻译好的 String 用 `Text(verbatim:)` 等明确展示；原始用户内容同样按原文展示。资源 key 的 SwiftUI 用法必须显式指定包资源和语言策略，不能在同一个模块里混用主 bundle、Core bundle 和中文词典。

## 语言选择和生效规则

### 支持范围与协商

设置中的选项采用自称，便于用户找回语言设置：

| 持久化值 | 界面显示 | 含义 |
| --- | --- | --- |
| system | 跟随系统 / System Default，按当前界面翻译 | 使用 macOS 提供给本应用的语言偏好进行协商 |
| zh-Hans | 简体中文 | 自有界面使用简中 |
| en | English | 自有界面使用英文 |

建议把系统协商实现为可注入偏好列表的纯函数。按列表顺序匹配受支持语言，使用 Apple 的语言标识规范，并明确以下产品规则；不要只判断列表首项。[Apple 语言地区和书写系统说明](https://developer.apple.com/documentation/xcode/choosing-localization-regions-and-scripts)

| 输入 | 首版预期 |
| --- | --- |
| 显式 en 或 zh-Hans | 使用显式选择，不受系统语言变化影响 |
| system，偏好 zh-Hans-CN / zh-CN / zh-SG | zh-Hans |
| system，偏好 en-US / en-GB | en |
| system，偏好 fr-FR、en-GB、zh-Hans | en，不能因为第一项不支持而直接终止匹配 |
| system，偏好 fr-FR、zh-Hans | zh-Hans |
| system，偏好 zh-Hant-TW、en | en |
| system，只有 zh-Hant / zh-TW / zh-HK / zh-MO | en；首版没有繁体翻译，也不隐式把繁体当简体 |
| system，通用 zh 且没有繁体脚本或地区 | zh-Hans |
| 空偏好列表或没有可支持语言 | en |
| 保存值非法 | 按现有设置行为归一到 system，再执行以上规则 |

繁体回退为英文本身是本方案的显式产品选择，不是声称 Apple 必然如此。实施协商时先识别不支持的繁体候选，再使用完整列表选择，避免系统匹配器隐式降为简中而违背此合同。将来增加繁体只新增资源与协商规则，不修改业务模型。

系统设置中为 ProxyMirror 指定的单 App 语言属于 system 模式应遵循的来源；必须在 macOS 打包产物上验证这一点，不能只测试手工构造的偏好数组。Apple 提供按 App 设置语言的系统入口，应用可能需要退出重开才能生效。[Apple 单 App 语言设置说明](https://support.apple.com/guide/mac-help/change-the-system-language-mh26684/mac)

### 首版重启后生效

区分 `requestedLanguage` 与 `effectiveLanguage`。前者是保存的选择，后者是本次启动已确定的语言；设置、备份导入和重置流程不能中途覆盖后者。

1. App 启动早期读取偏好、协商语言、校验资源，再创建 Scene、菜单和设置窗口。
2. 在设置中更改语言时仅保存偏好，显示“重启后生效 / Applies after restarting”，让新旧语言用户都能理解。
3. 用户继续使用时，各窗口、菜单、自有弹窗统一保持本次运行语言。
4. 用户按已有正常退出流程退出，再启动后统一使用新语言。不会为切语言自动停止代理或强制结束应用。
5. 新版备份恢复带入另一语言时按同样规则提示；旧版专有备份不要求支持，检测到旧格式时明确提示版本不受支持。

不要用根 View 的 `.id(language)` 强制重建窗口来实现切换；这可能丢失编辑草稿、焦点与选择状态。也不修改全局 AppleLanguages、不 swizzle Bundle、不从 root helper 读取用户 AppSettings。

### 自有界面和系统界面的边界

| 文案归属 | 首版保证 |
| --- | --- |
| 自有 SwiftUI 界面、Commands、窗口标题、菜单、Tooltip、Accessibility、自建 NSAlert | 按 effectiveLanguage 完整翻译 |
| NSOpenPanel / NSSavePanel 的自定义 title、message、prompt | 显式翻译，按 effectiveLanguage 展示 |
| Apple 自带面板内部按钮、系统授权、安全提示 | 由 macOS 及其单 App 语言机制决定，不能承诺只注入 SwiftUI locale 就全部改变 |
| Sparkle 自带 UI | 由其资源 bundle 与支持语言决定；自有更新状态与按钮仍要翻译，并在两语言下验证框架行为 |
| 系统扩展显示名与用途说明 | 在扩展自己的 InfoPlist.strings 中提供双语，按系统 bundle 语言机制选择 |

如果用户希望系统拥有的部分也与界面语言一致，指引使用“系统设置 → 通用 → 语言与地区 → 应用程序”为 ProxyMirror 设置语言，并在 App 内选择跟随系统。此方案不通过私有 API 强改系统界面语言。

如以后需要热切换，应作为独立功能建设可观察上下文，逐个处理 Scene、Commands、已创建的 NSWindow/NSMenu、NSViewRepresentable、搜索索引及已缓存字符串，并验证录制、选中、滚动、草稿不中断。首版无需承担这一范围。

## 动态文案和格式

### 完整句子和复数

每条消息保存完整句子，参数只传数据；例如“打开对比池”和数量作为一个有参数资源，不将数量拼进资源 key。两种语言允许调整参数顺序，以位置占位符保持对应关系。

英语数量使用 stringsdict 的 one / other；简中使用 other。至少覆盖 0、1、2、101、1000，不以条件表达式手写每一处单复数。复数规则及格式说明来自 Apple 的原生字符串字典机制。[Apple 复数本地化说明](https://developer.apple.com/documentation/xcode/localizing-strings-that-contain-plurals)

| key | zh-Hans | en one | en other |
| --- | --- | --- | --- |
| traffic.selection.count | 已选择 %ld 条请求 | %ld request selected | %ld requests selected |
| traffic.diffPool.open | 打开对比池（%ld 条请求）… | Open Comparison Pool (%ld request)… | Open Comparison Pool (%ld requests)… |

格式签名要与 Swift 参数一致，如 `Int` 对应经工具链验证的 `%ld`，文本对应 `%@`；不能把 Int64、Int32 和 Int 随意混用。生成器和检查器共同校验所有语言的签名与位置。复数 key 同表的 strings 与 stringsdict 定义遵循 Apple 的覆盖机制，检查器应区分合法配套定义与误重复。

### 语言与地区分开

保留独立的界面语言与格式策略：

- 普通日期、数字、可读大小优先尊重用户地区设置。
- 抓包时间继续提供现有的毫秒精度、时区、完整日期和 12 / 24 小时选项；切语言不能改变记录的原始时间。
- 英文复数必须在显式中文系统选英文等组合下验证，不默认生成模板的 Locale.current 一定满足应用所选语言。
- URL、端口、HTTP 日期、HAR/JSON、ISO8601 日志、代码生成与机器 CSV 使用各自稳定格式，不接入界面格式器。

统一格式层接收 effectiveLanguage 和地区偏好，并明确复数与插值采用的 locale。已有时间缓存的 key 包含 locale 和时区，可继续使用；不要把所有现有 en_US_POSIX 一律替换成应用语言。

## 数据标识和协议边界

### 新存储使用稳定英文标识

旧本地数据允许全部清空，因此本轮直接整理内部 rawValue，不保留旧中文编码，不增加双读、自动转换或历史 fixture。新的存储值与显示语言完全分离：

```swift
// 示意：编码使用稳定英文 ID，界面用独立的本地化访问器。
enum HeaderOp: String, Codable {
    case set, add, remove, replaceExisting
}

enum Appearance: String, Codable {
    case system, light, dark
}

// rawValue 用于存储和身份；localizedTitle 按 case 选择资源。
// 同一个 set，在简中界面显示“设置”，在英文界面显示“Set”。
```

外观、过滤字段与比较操作、AND/OR、HeaderOp、自定义列 source、FilterChip/ToolKind 均按同一规则整理：英文 ID 固定，显示名从资源获取，条件分支使用 enum case 或稳定 ID。默认名称可以按创建时的语言生成；用户在新版中输入的名称、列名和备注作为原始内容保存，后续切语言不能自动翻译或重命名。

### 一次性重置和版本管理

1. 为应用自有存储定义新版 storageVersion，并更新专有规则备份、会话等需要变更的格式版本。具体值以实施时现有版本为基础确定。
2. 首次使用新版时，一次性清空旧设置、规则、过滤器、自定义列、Saved 请求、应用自有会话和缓存等本地历史数据，按新版默认值初始化，再记录已完成的存储版本。
3. 后续启动继续使用新版数据；修改界面语言、普通文件读取失败或再次启动都不能重复触发清空。
4. 不提供旧专有文件或旧备份的兼容解析。导入时检查格式版本，旧版本给出明确提示；新版导入导出仍须正常往返。HAR、Charles 等外部格式继续按各自既有合同处理。
5. 清理以明确列出的 ProxyMirror 自有存储文件和偏好域为边界。系统钥匙串、系统代理状态及证书信任由各自现有功能管理，不混入通用目录清理；用户指定的工作目录、原始文件和导出目录不做递归清空。

实现位于 `System/LocalizationStorage.swift`，重置名单已逐项列出并经临时目录测试。重置由新版 App 第一次正常启动执行；本次开发和测试未对个人实例运行清理，不保留旧数据迁移层。

### 不受 GUI 语言影响的边界

| 内容 | 合同 |
| --- | --- |
| HTTP method、状态原因、URL、headers、body、Cookie、WebSocket/SSE 数据 | 原始流量，不翻译 |
| 脚本、正则、JSONPath、jq、Protobuf schema、用户备注 | 原始用户或技术内容，不翻译 |
| CLI 命令、参数、退出码，MCP tool name、schema 与 JSON key | 保持稳定，不随 GUI 语言改变 |
| `query_flows` 的 id/method/url/status/state/durationMS 等 | 字段和 enum 稳定，state 继续 pending/awaiting/completed/failed |
| 代码生成 API 的 language | 指 Swift/Python 等代码目标，与应用界面语言无关 |
| HAR/JSON/CSV 公共字段与列头 | 不随 GUI 语言改变；专有 session/规则格式可在本轮显式升级版本 |
| 新版会话的 errorText 与 HAR _error | 保存稳定诊断或原始技术详情，不随切语言改写 |
| 技术日志、脚本 console、系统命令 stderr | 保存原始诊断；界面可额外提供本地化解释 |

首版 CLI/MCP 既有人类描述也不顺带跟随 GUI 语言，保持现有输出合同。未来如需要命令行双语，应另加显式 locale 参数和测试，不能让桌面偏好隐式影响脚本。

## 错误帮助和搜索

### 错误在展示边界翻译

新建或整理的操作错误使用稳定 `domain + code + arguments`，保留底层诊断作为 details。后台处理和 helper 不输出最终 GUI 译文，App 显示时通过 `LocalizedErrorPresentation` 渲染。

优先处理系统代理授权/监听、证书安装与导入、更新失败、文件导入导出、网络访问设置。XPC 可使用共享错误码和结构化属性，或稳定 NSError domain/code；保留旧 helper 返回纯字符串的兼容处理，不假设不同版本 helper 与 App 总是同步替换。

不要向用户原样展示资源 key，也不要将 `error.localizedDescription` 当机器错误标识。系统错误原因和路径可作为保留原文的详情展示，主标题与可执行恢复动作应有双语版本。这样也能保持日志和 CLI 的稳定诊断。

### 帮助与证书指南

帮助主题用 enum case 控制逻辑，标题、正文、按钮和搜索别名独立本地化。macOS、iOS、Android、模拟器、Java 等指南按整段和完整步骤翻译，保留平台路径、必要的系统术语及协议名。

可复制命令使用统一模板生成，两语言只更换附近的说明文字；端口、证书路径、shell quoting、命令参数、环境变量与 URL 不从任意译文拼装。若命令中确实含注释，分别验证两语言结果均可执行。凭证、私钥与会话正文不能进入翻译资源。

### 搜索与命令面板

搜索数据结构使用 `id + titleKey + aliases + action`。SettingsSearchTarget 和窗口 command ID 保持稳定；同时索引当前显示名、另一语言常用名和技术别名，例如 certificate、CA、证书、MITM。

界面始终显示当前语言标题；匹配可以接受另一语言输入。排序由固定产品顺序或明确的本地化排序规则决定，不依赖翻译后的字典 key。首版语言在启动时固定，因此索引每次启动构建一次即可；未来热切换再增加重建。

## 打包和资源验证

### SwiftPM 资源定位

给 Core target 增加 `.process("Resources")` 后，检查当前 macOS 工具链实际生成的 `resource_bundle_accessor.swift`，确认资源 bundle 的名称、结构与查找候选路径。

`Bundle.module` 只在拥有资源的 target 内使用。App 通过 Core 的访问器获取文案，不能复制一份自己的 Core 资源查找逻辑。对于 shell 组装的 `.app`，发布运行优先从 `Bundle.main.resourceURL` 下找明确命名的本项目资源 bundle；只有非发布 App 的开发/测试入口才回退 SwiftPM 的 `.module`。避免缺资源的发布包悄悄借用构建目录。这个开发回退必须惰性求值，不能在全局属性初始化、默认参数或生成的 BundleToken 中提前访问 Bundle.module，否则资源缺失时可能先触发 SwiftPM accessor 的 fatalError，跳过自有诊断。

### 修改 make_app.sh

1. 沿用当前构建参数，使用 `swift build -c "$CONFIG" --show-bin-path` 获取实际输出目录，不再靠 `.build/$CONFIG` 推断。
2. 从该目录显式复制本项目实际生成的 Core resource bundle 到 `Contents/Resources`；名称由第一批构建确认后固定并断言。不要通配复制全部依赖资源或整个 .build。
3. 把主 App 的双语 InfoPlist.strings 放入 `Contents/Resources/en.lproj` 与 `zh-Hans.lproj`。其中包括 Apple Events 用途等可本地化元数据。
4. 声明 `CFBundleLocalizations = [en, zh-Hans]`，development region 统一为 en，品牌名继续 ProxyMirror。普通界面的缺译兜底也使用 en。
5. 为透明代理扩展放入其自己的双语 InfoPlist.strings；不能只放进主 App 或 Core bundle。主 App 与扩展的 development region、用途说明和支持语言保持协调。
6. 所有资源复制完再执行对应扩展与 App 签名，并验证签名。签名后不能继续写资源。
7. 扩展 `Scripts/test_app_bundle.py` 检查资源、两套语言和元数据，并运行可搬移性验证。

SwiftPM 资源 bundle 的名称和 Apple 平台目录结构，以真实产物为准，不能在 Linux 上凭规则猜测后就标记完成。也无需给纯机器协议 helper 强行添加界面语言资源。

### 可搬移性验收

把打包产物复制到临时干净路径后，以不同的当前工作目录启动测试实例。测试环境必须无法访问原构建目录，或把自有资源解析器置于严格发布模式并证明没有回退构建路径。不得为此删除个人开发目录；使用专门的 CI 临时 checkout 或受控隔离环境。

确认当前文案来自 App 内的语言资源，显式 en、zh-Hans 和 system 都可启动；在普通构建和启用透明扩展的构建中验证各自资源。签名 Sparkle 构建按现有发布配置单独验收，不能用 ad-hoc 测试代替所有发布组合。

## 翻译工作流和质量门禁

### 一套资源和术语表

每个新功能在同一次变更中提供 en、zh-Hans 资源、译者注释和参数说明。en 作为开发回退语言，不表示可以把英文资源直接复制到简中冒充完成。开发者可提交初译，由理解抓包产品的审校者确认专业术语、操作语义与恢复步骤。

术语先固定，例如：

| 概念 | 简体中文 | English |
| --- | --- | --- |
| 流量条目 | 请求 | Request |
| 请求/响应数据体 | 正文 | Body |
| 断点队列 | 断点 | Breakpoints |
| 本地映射工具 | 本地映射（Map Local） | Map Local |
| 重写工具 | 重写 | Rewrite |
| 系统代理接管 | 接管系统代理 | Set as System Proxy |
| 已捕获的一组流量 | 流量会话 | Traffic Session |
| 保存的请求 | 已保存请求 | Saved Requests |
| 原始数据 | 原文 | Raw |

具体“会话”的不同业务含义应分 key，不要用一个词覆盖流量会话文件、录制过程和自动化连接。HTTP、TLS、JSON、cURL、MCP、Protobuf、品牌名等按术语表保留。

### 自动检查

`check_localization.py` 负责资源结构及可检测问题，生成器负责类型接口，macOS 测试负责真实 Foundation 行为：

- 各表的两语言 key 集一致，值非空，资源语法有效；辅助检查重复 key。
- 占位符的类型、位置、数量一致，百分号与转义有效；复数有必需类别，英文 one/other、简中 other。
- 生成代码与资源一致；重新生成后 Git 应无差异。
- 缺语言、缺 key、未知 key、格式错误在 CI 失败。
- 文案包含动态插值后再作为查询 key、直接使用中文全文作 key 等用法被禁止。
- 新增用户可见的中文与英文硬编码都需要分类。优先以 SwiftSyntax/编译器辅助提取使用点；初期可使用词法扫描加已审查的 baseline，不用“搜索所有汉字”计算完成率。
- HTTP 夹具、示例 payload、用户数据、日志、注释与第三方代码有明确排除理由。每项豁免保留路径、用途、原因，不能整目录随意忽略。

人工文案清单至少记录：稳定 key、表名、使用位置、中文、英文、参数类型与含义、复数、长度限制、是否已审校、对应截图。迁移完成后不再维护会失真的第二份翻译正文表，资源才是最终文本来源。

## 实施顺序和交付物

每一批都应能独立评审，后续批次依赖前面的资源、新存储和接口合同。所有批次完成后再宣称完整双语。

| 批次 | 主要变更 | 完成条件 |
| --- | --- | --- |
| 0 基线与验证样例 | 固定实施 SHA/工作区；输出硬编码分类清单；确定术语；用一个设置标签、一个复数和一个原生警报打通原生资源 | macOS 上 swift build、打包、干净路径运行均能展示两语言；确认 Bundle 路径和生成器模板 |
| 1 基础设施 | AppLanguage、冻结的 LocalizationContext、资源解析、SwiftGen 配置、资源检查器、Package.swift、make_app.sh、双语 InfoPlist；稳定英文存储 ID、版本与一次性重置 | 默认/显式选择/协商/资源缺失及新版备份测试通过；旧数据清空后初始化成功，后续启动不重复重置 |
| 2 核心工作流 | App Scene/Commands/MenuBarExtra、设置、主窗口、状态、Sidebar、列表、详情主入口、搜索与命令面板 | 用户能用任一语言完成启动监听、筛选、查看详情、设置、保存与重开；新版配置在两语言间一致 |
| 3 深层工具 | 全部 Detail 子检查器、Tools、规则编辑器和摘要、动态计数、复数、自定义预览/列、备份导入导出界面 | 所有工具的空/正常/错误状态、上下文菜单、动态消息双语完整 |
| 4 系统和长文 | 自有 NSAlert/panel、帮助、设备/证书指南、更新、错误码映射、helper 兼容 | 自有可见文案与恢复步骤完整；系统界面的归属边界按合同验收 |
| 5 发布回归 | 清除临时中文词典和旧调用；一次性重置与新版数据往返、CLI/MCP/导出对比、截图、较长文案、VoiceOver、签名移动产物 | 下文首发验收清单全部通过，零未分类用户可见硬编码 |

代码改造可按这些批次拆 PR，但开发期间不能把某一批完成描述为整个产品已经支持英文。工期应在第 0 批得到实际唯一 key 数、状态覆盖数和 macOS 验证结果后确定；翻译审校、系统权限和签名产物验证需要计入，不能只估算替换字符串的时间。

## 测试和首发验收

### 自动化测试矩阵

| 层级 | 必测内容 | 现有位置或新增位置 |
| --- | --- | --- |
| 资源静态检查 | 两语言 key、空值、占位符、复数、重复定义、访问器生成一致性 | 新增 check_localization.py、生成脚本 |
| 语言单测 | 上文所有协商案例、非法值、显式选择覆盖系统、启动冻结与待生效状态 | 新增 LocalizationChecks.swift |
| Foundation 运行测试 | 两语言查找、英文 fallback、0/1/2/101/1000、中文系统显式英文的复数、英文系统显式简中 | macOS 上使用真实资源 bundle 运行 |
| 新版存储与重置 | 旧数据一次性清空；新版英文 ID、两语言序列化一致、重启不重复清空、新版文件往返 | 新增 LocalizationStorageChecks.swift，调整现有规则与存储测试 |
| 偏好与备份 | 新版备份语言字段、非法值拒绝、语言恢复待重启、外观重置保留新版语言；旧专有格式明确拒绝 | 调整 PresentationBackupChecks.swift，移除旧备份兼容要求 |
| 错误与 helper | 稳定错误码、旧字符串兼容、技术详情保留；行为断言与译文断言分开 | 系统代理、证书、设置的现有测试 |
| 机器合同 | 两语言下 CLI/MCP/schema/enum/退出码和固定输入的导出结果不漂移 | Scripts/test_cli.py、test_mcp.py 与导出回归 |
| 安装产物 | 双语资源、主 App 与扩展元数据、bundle 路径、签名、移动运行 | Scripts/test_app_bundle.py |

CLI/MCP 测试复用现有临时 App、新 bundle ID、独立偏好与 `PM_SUPPORT_DIR` 的隔离方式，不修改开发者个人实例、不为验收接管真实系统代理。源码中尚未发现仓库内的 CI 配置；实施时应把这些检查接入实际发布任务，而不是假定已有 CI 会自动执行。

测试命令的目标入口如下。新增脚本须先实现，并遵守非零退出表示失败的合同：

```sh
# 任意可运行 Python 的检查环境：资源与生成结果检查。
python3 Scripts/check_localization.py

# 固定生成器的开发或 CI 环境：生成后检查是否有未提交差异。
Scripts/generate_localization.sh
git diff --exit-code -- Sources/ProxyMirrorCore/Localization/Generated

# macOS：运行真实 Foundation、规则与设置测试，再组装产物。
swift test
Scripts/make_app.sh debug
Scripts/make_app.sh release
```

现有 `Scripts/test_app_bundle.py`、`test_cli.py`、`test_mcp.py` 按各脚本现有参数合同调用，扩展为独立双语测试实例。release 构建必须继续保留当前 App 对 Core 使用 `@testable` 所需的构建参数；本地化工作不顺带改变模块访问方案。

### 人工界面验收

分别在简中和英文环境执行完整工作流，并交叉测试“系统英文、应用简中”和“系统简中、应用英文”。两次都覆盖主窗口、每个设置页面、所有工具窗、独立详情、sheet、菜单栏、右键菜单、警报、打开/保存面板自定义部分、帮助、证书与更新。

截图和操作检查包含最小窗口、较大字体、长路径/文件名、1000 条以上计数、110%–150% 长度的伪本地化文案，以及 Tooltip 和 VoiceOver。优先让标签合理换行和窗口扩展，不用一律缩小字号或截断来掩盖翻译长度。

更改语言偏好后继续录制和编辑，确认本次语言、窗口、选中请求、滚动与草稿保持；退出重开后新语言生效。正常退出的已有行为保持原有合同，不把未承诺的流量会话自动恢复当成本地化功能。

### 首发通过条件

- [ ] 只声明 en、zh-Hans 两套语言；两套自有界面、帮助和操作反馈均完整。
- [ ] 所有已分类文案都有资源或明确豁免，零缺 key，零空翻译，英文模式没有未解释的中文残留，简中模式没有漏译的普通英文操作。
- [ ] 0/1/N、参数重排、较长文案、Tooltip 与辅助功能检查通过。
- [ ] 语言偏好、system 模式、待重启提示和备份恢复符合合同。
- [ ] 旧本地数据可以一次性清空并初始化新版；不做旧格式兼容；新版英文 ID 与序列化内容不随界面语言改变，后续启动不会重复清空。
- [ ] CLI/MCP、HTTP 数据、代码生成、HAR/JSON/CSV、用户命名保持稳定。
- [ ] 真实打包 App 在干净路径中能够离开源码和构建目录运行，双语资源与签名正确。
- [ ] 主 App、透明扩展及实际启用的更新框架完成对应 macOS 验收，系统拥有界面的语言边界清楚。
- [ ] 临时中文词典已删除，资源、生成、检查、翻译审校流程已经进入日常开发和发布。

## 审查结论的验证范围

审查基线来自源码、构建脚本和测试代码；技术方案核对了 Apple 与 SwiftGen 官方文档。实施时在 Linux 上使用可用的 Swift 6.0.3 工具链，完成真实 Foundation、生成接口、模型和错误边界等验证。上面的首发清单保留为完整 macOS 发布验收合同，不能把已通过的便携测试当成全部发布门禁已通过。执行结果以 [实施记录](localization-implementation.md) 为准。
