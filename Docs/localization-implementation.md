# ProxyMirror 双语本地化实施记录

实施日期：2026-11-23。开发范围为简体中文和英文；当前源码改造已完成，完整 macOS 发布验收待执行。

## 已落地的行为

- 自有菜单、设置、主窗口、来源侧栏、流量列表、详情检查器、工具窗口、帮助、证书指南和操作反馈使用原生语言资源。资源共有 2,164 个 key、14 张表、25 个复数 key。
- 设置提供跟随系统、简体中文、English。启动时冻结语言，更改选择只保存下次启动偏好，并显示重启后生效提示。未通过根视图身份重建切语言。
- 系统偏好按完整列表匹配；en 地区变体和简中变体可匹配。没有繁体译本，繁体候选会继续尝试后续语言，最终兜底英文。
- 旧中文词典和主 App 下的中文全文 key 表已删除。业务使用 SwiftGen 生成的类型化接口，原生资源是唯一维护源。
- 计数使用 stringsdict；查询与格式化集中处理，英文兜底采用实际命中的语言规则。静态和动态百分号分别验证。
- 设置与命令搜索使用稳定身份，并支持两种语言的标题和常用别名。用户命名、脚本、网络原文和可复制命令保持原始内容。

源文件位于 `Sources/ProxyMirrorCore/Localization/`、`Sources/ProxyMirrorCore/Resources/` 及各 UI 目录。生成约定、固定上游提交和百分号规则见 [生成流程](../Scripts/Templates/README.md)。

## 存储和机器接口

`System/LocalizationStorage.swift` 的存储版本为 2。新版第一次正常启动会先重置明确列出的旧应用数据和偏好，再创建设置、规则及 Saved 单例；重置完成后记录版本，后续启动或修改语言不会重复清空。

清理范围包括旧设置、规则、Saved、来源文件夹、应用自有缓存和备份等。CA、钥匙串、系统代理恢复文件和用户外部文件不属于通用清理名单。测试使用临时目录与独立偏好域；开发过程中未对个人实例执行清理。

外观、过滤字段、比较操作、AND/OR、HeaderOp、自定义列等使用稳定英文 ID，显示独立本地化。规则备份、专有会话、Saved 和来源文件夹格式升级为 2，旧专有格式明确拒绝；HAR、Charles 等外部格式按原合同处理。

错误使用 `OperationIssue` 保存稳定诊断和延迟界面渲染，模型和系统共用 `LocalizedErrorPresentation`。CLI、日志读取稳定诊断；GUI 才生成译文。共享校验提供 `validationIssue`、`validationError` 和 `localizedValidationError`。系统代理 helper 保持 XPC String 接口，以版本化 JSON 传递稳定错误码，不读取 GUI 语言。

CLI/MCP 的字段、命令、退出码和既有目标别名不随 GUI 语言改变。专有会话版本升级相关夹具已同步；这与网络协议或通用导出字段改名无关。

## 构建和发布检查

`Package.swift` 声明默认英文和 Core 原生资源。发布 App 从自身 `Contents/Resources/ProxyMirror_ProxyMirrorCore.bundle` 查找资源；缺失时不会借用构建目录或测试环境覆盖。只有非 App 的开发和测试入口允许惰性使用 SwiftPM 资源。

`Scripts/make_app.sh` 在构建前执行完整本地化检查，使用 SwiftPM 实际输出目录复制 Core bundle，再复制主 App 和可选透明扩展各自的 InfoPlist.strings，最后签名。主 App 和扩展均声明 en、zh-Hans。

新增的只读 `--check-localization` 入口在 GUI 和存储重置之前分流，可验证移动后的 App 实际资源路径及 0、1、2、101、1000 的复数结果。它不会启动监听、打开窗口或重置用户数据。

产物检查逐语言比较完整文件、key 和值，能够拒绝两边同时遗漏整表、陈旧翻译、错误元数据和资源缺失。直接界面字面量的 64 处保留项逐点记录于 [文案例外清单](localization-ui-exceptions.json)，仅包括品牌、协议术语、原始数据、数值或空标签；新增未分类项会使检查失败。这是保守静态扫描，不能取代界面验收。

检查器支持按需导出完整审校清单，包含两语言正文、参数签名、复数规则、类型化源码引用位置，以及人工审校和截图待验状态。清单是从资源派生的快照，不作为第二套翻译维护源，正常检查不会生成它。

## 当前环境的验证结果

使用 Linux 上的 Swift 6.0.3 实际编译运行；下表不包含未执行的 macOS UI 测试。

| 检查 | 已验证结果 |
| --- | --- |
| 原生资源与生成一致性 | 2,164 key、14 表、25 复数 key；无缺失、参数签名或生成指纹错误 |
| 真实 SwiftGen 6.6.3 | 实际生成后再次生成，输出字节一致 |
| 资源检查器负例 | 15 项通过 |
| 打包门禁负例 | 12 项通过，含整表同时遗漏、元数据语言错配、资源缺失和 UTF-16/二进制读取 |
| Foundation 运行时 | 英文 34、简中 34 项通过，使用实际资源和生成接口 |
| 设置搜索 | 英文 58、简中 58 项通过 |
| 工具模型和文案 | 12 项通过；640 处访问器参数静态核对通过 |
| 显示格式 | 24 项通过，含地区格式和缓存区分 |
| 存储与模型 | 偏好 35、Saved 27、汇总/文件夹 28、重置 15、模型 ID/错误/校验 15、自动化合同 46 项通过 |
| 系统错误、指南和 helper 传输 | 英文 81、简中 81 项通过，使用真实生成接口和生产错误模块 |
| 外部代理校验 | 英文 16、简中 16 项通过，编译实际校验、主机和 PAC URL 逻辑 |
| 更新、网络与证书格式 | 更新 32、网络访问 47、OpenSSL 转换 4 项通过；留存模型检查通过 |
| 工程静态检查 | SwiftPM manifest 可解析；258 个 Swift 文件语法、Python 编译、shell 语法和差异空白检查通过 |

在 Linux 上构建生成器时，仅在临时工具目录排除了不使用的 AppKit 解析器和打开文档命令；官方 Strings 解析器、模板引擎和输出模板未修改。规范生成脚本仍固定原版 SwiftGen 6.6.3，并将原生字符串表转成等价的临时 XML 输入。生成器不进入 App 运行依赖，普通构建使用已生成的源码。

关键命令：

```sh
python3 Scripts/check_localization.py
python3 Scripts/check_localization.py --inventory build_app/localization-inventory.json
python3 Scripts/test_localization_resources.py
python3 Scripts/test_localization_packaging.py
Scripts/generate_localization.sh --check

# 这些脚本接受 --swiftc，便于明确指定已安装的工具链。
python3 Scripts/test_localization_runtime.py --swiftc /path/to/swiftc
python3 Scripts/test_localization_storage.py --swiftc /path/to/swiftc
python3 Scripts/test_settings_search.py --swiftc /path/to/swiftc
python3 Scripts/test_tools_localization.py --swiftc /path/to/swiftc
python3 Scripts/test_external_proxy_localization.py --swiftc /path/to/swiftc
python3 Scripts/test_localized_errors.py --swiftc /path/to/swiftc
```

## 待在 macOS 执行的发布门禁

- [ ] `swift test` 完整模块类型检查与 Native CoreChecks；真实 Foundation 的全部复数断言。
- [ ] debug、release、透明扩展及实际启用的 Sparkle 构建，验证资源路径、架构与签名。
- [ ] 移动到干净目录运行完整产物诊断；缺资源时明确失败，禁止读取原 App 或构建目录。
- [ ] 两语言 CLI/MCP 回环集成，以及系统单 App 语言与 App 内显式选择的组合验证。
- [ ] 全部窗口、菜单、错误、帮助、Tooltip、VoiceOver、最小尺寸和长文案人工验收。
- [ ] 系统面板、授权和第三方更新 UI 的语言归属检查。

```sh
swift test
Scripts/make_app.sh debug
python3 Scripts/test_app_bundle.py --app build_app/ProxyMirror.app
python3 Scripts/test_localization_bundle.py --app build_app/ProxyMirror.app --runtime
python3 Scripts/test_preferences_ui.py --app build_app/ProxyMirror.app --language both --appearance both

for language in en zh-Hans; do
  PM_SETTINGS_LANGUAGE="$language" python3 Scripts/test_cli.py --app build_app/ProxyMirror.app
  PM_SETTINGS_LANGUAGE="$language" python3 Scripts/test_mcp.py --app build_app/ProxyMirror.app
done
```

截图和 CLI/MCP 测试使用复制的 App、独立 bundle ID、偏好域与 PM_SUPPORT_DIR。系统拥有的按钮及授权对话框遵循 macOS 单 App 语言机制，不把 SwiftUI locale 注入当作这些部分全部变更的保证。
