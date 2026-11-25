# Proxyman 对齐实现与验收（2026-11-25）

基线：`main@d752a49`。输入为用户提供的《ProxyMirror 与 Proxyman 功能及 UI 差距评审（2026-11-24）》和《Proxyman 对齐实施规格（2026-11-25）》。本文记录本次工作区实现；不是发布或原生 UI 验收通过的声明。工作区原有的 gzip/Tars 修改已保留。

## 已接入的功能

| 范围 | 现在的行为 | 主要落点 |
| --- | --- | --- |
| 规则窗口 | Map Local、Map Remote、Block、Allow、SSL 为独立窗口，可和主窗口同时操作；列表改动即存，单条编辑可取消 | `RuleListWindow.swift`、`AppState.openTool`、`ProxyMirrorApp.swift` |
| 列表交互 | 两层文件夹、搜索、仅启用项筛选、双击编辑、复制、删除、文件夹归属、拖拽排序；SSL 有包含/排除两页 | `RuleListWindow.swift` |
| 规则导出 | 单条/选中/当前工具原生 JSON 备份；原有 Charles 预览确认流程保留 | `RuleListWindow.swift`、`RuleBackupView.swift` |
| 阻断动作 | 403（旧数据默认）、503、429、断开；HTTP/1、HTTP/2、CONNECT 同源策略 | `RuleBlockAction.swift`、`TunnelRulePolicy.swift`、`ProxyEngine.swift` |
| 脚本 | 搜索、编辑器下方 Console、持久化的首个匹配/全部匹配开关 | `ScriptingWindow.swift`、`ScriptingRuntimeSettings.swift` |
| 主界面 | 高级过滤内联、状态码胶囊、16 个可点击工具状态胶囊；新增工具栏动作；修正 Summary/Automation 默认尺寸 | `MainWindow.swift`、`TrafficFilterEditor.swift` |
| 流量表 | 原生多列及表头，支持排序、调宽、拖拽换序与持久化；新增 Scheme、Content-Type | `TrafficTable.swift`、`TrafficListView.swift` |
| 快捷键 | 新增重放、高亮、删除、停靠、标签导航、工具入口；可选择 Proxyman 兼容键位，编辑控件和 sheet 不触发流量删除/重放 | `ProxyMirrorApp.swift`、`AppSettings.swift` |
| Setup | macOS、iOS、模拟器、Android、Java/框架、Helper 分步面板，刷新 CA/监听/设备状态，显示 IP/端口，提供二维码和 AirDrop | `SetupGuideWindow.swift`、`CertificateMenu.swift` |
| CA 下载 | 设备经代理访问 `GET http://proxy.mirror/ssl` 可下载公共 CA DER；不包含私钥 | `ProxyEngine.swift` |
| Android 模拟器 | 多设备探测、接管前持久化 journal、设置代理、安装 CA、恢复；跳过 API≥34/Play 镜像并说明原因 | `AndroidEmulatorSetup.swift`、`DeviceAutomation.swift` |
| 证书管理 | Root/Server/Client 三页，导入、预览、删除，公共证书导出；自动配置支持 Terminal/iTerm/Ghostty/自定义终端、Chrome/Firefox/Electron | `CertificateManagerView.swift`、`CertificateImporter.swift`、`AutomationDashboardView.swift` |
| 正文 | 统一工具菜单；保存完整捕获或解码缓冲区，外部应用打开、Finder；不受文本/Hex 分页预览限制 | `DetailView.swift`、`BodyExportService.swift` |
| 格式与选区 | XML/HTML 词法美化及高亮；混合内容和 pre/textarea/script/style 保留；非法输入回退原文；JSON/XML、Base64、JWT、时间戳、键值选区转换只展示结果 | `MarkupFormatter.swift`、`SelectionTransform.swift`、`CodeDocument.swift` |
| 表单 | multipart 与 urlencoded 表格、部分捕获状态、文件部分保存；捕获数据保持只读 | `FormBody.swift`、`FormBodyView.swift` |
| HTML Preview | 惰性 WebKit，非持久存储，禁 JavaScript、外部资源与后续导航；截图模式不启动 WebKit | `IsolatedHTMLPreview.swift` |
| Summary | 客户端/Bundle ID/地址/时间/大小/协议；上下游 TLS、ALPN；上游叶证书 DER、subject、issuer、SAN、有效期、公钥、签名算法、SHA-256 和 Preview | `TLSConnectionMetadata.swift`、`TransactionSummaryView.swift` |
| OpenAPI | JSON 3.0.3；数字/UUID/hex 路径归并、query、JSON schema required/nullable/enum、security、servers | `OpenAPIExporter.swift`、`JSONSchemaInferencer.swift`、`APIExportService.swift` |
| Postman | v2.1 集合，按 host/一级路径分组、base URL 变量、共同认证；支持多选和 Saved 文件夹 | `PostmanCollectionExporter.swift`、`TrafficListView.swift` |
| CLI/MCP 导出 | `export openapi` / `export postman`；MCP `export_flows` 支持对应 format，并沿用脱敏 | `LocalControl.swift`、`AutomationControl.swift`、`MCPProtocol.swift` |
| MCP 工作台 | WebSocket 会话/消息读取和分页；持久 Compose 草稿 CRUD、异步发送/结果查询；证书状态、平台指南、内置文档搜索 | `AutomationWorkbench.swift` |
| 迁移体验 | 打开/拖入 Proxyman 私有会话格式时，给出 HAR 转换、CLI 命令复制和官方文档入口；保留真实可用的 Charles 转换 | `SessionImportGuide.swift`、`SessionImportCompatibility.swift` |
| 发布流水线 | 数字版本 tag 触发签名、公证、staple、DMG、签名 appcast；密钥只来自 GitHub release environment | `.github/workflows/release.yml`、`configure_release.py` |
| 语言 | 新增 es-419、ja、pt-BR 各 119 条初版菜单/常用动作/设置翻译；资源查找、打包、偏好和备份支持五种语言，未译条目走英文 | `AppLanguage.swift`、各 `.lproj`、本地化检查脚本 |
| 文档 | 修正 README 三处断链和已经删除的 `PM_SNAPSHOT` 说明 | `README.md` |

## 验证证据与边界

本次在 Linux aarch64 使用 Swift 6.0.3。SwiftPM 验证使用隔离副本，避免 Linux 的精简目标图改写桌面依赖锁文件。

- 全量 Foundation XCTest：107 项通过（包括原有 gzip/Tars、正文解析、导出、规则策略、Android journal 和 TLS 持久化兼容检查）。
- 锁定 NIOSSL/X509 版本真实编译并进行内存 TLS client/server 握手，证书验证保持启用；双方 TLS 版本、叶证书 DER 和摘要匹配。
- OpenAPI 五条样本通过 `openapi-spec-validator`；导出规则另有 Foundation 与 CoreChecks 回归。
- 生成代码检查通过 Python/Node/Swift/Go/Postman 验证；Node HTTP、Node Fetch、Go 完成实际回环 HTTP 请求。PHP Guzzle 缺本地 PHP 工具链，未执行。
- 本地化使用固定 SwiftGen 6.6.3 重新生成并校验（中英文各 2,523 条）；五语言 SwiftPM 处理资源检查共 125 项，另有设置持久化/搜索与打包完整性检查。
- 新增原生 CoreChecks 覆盖规则路由、原生多列、阻断三类传输、Summary/会话和导出。Linux 无法执行 macOS AppKit/SwiftUI 测试。
- MCP 工作台的 38 项便携检查编译执行生产协议、处理器、请求解析和脱敏外层，覆盖草稿持久化、分页预算、发送/取消/晚回调和结果保留上限。
- 发布元数据和签名身份检查 6 项通过；appcast/DMG 的 12 项 CryptoKit 签名/篡改测试已接入 macOS CI，在 Linux 未运行。

可重复命令（前提是 PATH 中有 Swift，`SWIFTGEN_BIN` 指向 6.6.3）：

```sh
python3 Scripts/generate_localizations.py --check
python3 Scripts/test_localization_runtime.py
python3 Scripts/test_processed_localization.py
python3 Scripts/test_localization_packaging.py
python3 Scripts/test_preferences_models.py
python3 Scripts/test_settings_search.py
python3 Scripts/test_release_configuration.py
python3 Scripts/test_tls_metadata.py
python3 Scripts/test_request_code_models.py
python3 Scripts/test_automation_workbench.py
```

`swift test -j 2` 应在 macOS 原目录运行，或在 Linux 的隔离源码副本运行。

## macOS 验收

```sh
Scripts/make_app.sh debug
swift build -j 2 --product ProxyMirrorSelfTest
.build/debug/ProxyMirrorSelfTest --core-unit
python3 Scripts/test_preferences_ui.py --app build_app/ProxyMirror.app --appearance both
python3 Scripts/test_appcast_verification.py
```

还需逐项实测：

1. 同时打开 Map Local/Remote，继续操作主窗口；新增/编辑/搜索/拖拽/启停/重新打开规则，检查即时生效、排序和持久化。
2. 流量原生表头拖拽/调宽/排序、隐藏再恢复列；数万行滚动与内存没有在本环境测量。
3. 在主表、正文、搜索框、规则窗口、Compose 和 sheet 间切换焦点；验证快捷键及 Console 无重复 key-equivalent 警告。
4. iOS 真机配置 Wi-Fi 代理，扫码/下载 CA、AirDrop、启用信任后抓 HTTPS；检查 Summary 叶证书与源站一致。
5. API33/API34 两台 Android 模拟器：仅接管受支持设备；中途失败和重启应用后可从 journal 恢复；恢复原有代理并只移除本次安装的 CA。
6. 用有脚本、iframe、图片、CSS import、meta refresh 的 HTML 测试 Preview，确认没有外部网络请求、脚本执行或持久 cookie。
7. 从主菜单/多选/Saved 文件夹/CLI/MCP 导出，导入 Swagger/Postman，核对脱敏、路径和正文。
8. 用签名旧版与私有 appcast 做成功升级、篡改拒绝和重启验证。

## 明确未完成或依赖外部材料的项目

- **Proxyman 私有会话二进制读取**：按实施规格先提供转换指引；没有虚构 `.proxymanlog(v2)` / `.proxymansession(v2)` 解码器。
- **From Proxyman 规则解析**：入口和说明已提供；需要真实 `.config`/规则 JSON 样例及版本信息后实现可取消的映射预览，当前不能直接导入。
- **Android API≥34、Play 镜像、VPN companion/Magisk 自动接管**：未实现，界面明确跳过；不自动修改不支持的设备。
- **TLS 加密套件、完整证书链**：当前仅采集公开 API 可见的叶证书；cipher suite 显示占位，未维护 NIOSSL fork。
- **OpenAPI YAML、Monaco/npm 安装器、多请求 Timeline、远程设备别名**：本次未实现；OpenAPI 输出为 JSON，脚本编辑器继续使用原生文本组件。
- **multipart 编辑**：检视捕获数据与保存分段已完成，不在捕获正文上提供改写/New 操作。
- **额外三语言**：为初版翻译，尚非全量人工翻译或截图验收。
- **发布与自动升级运行验证**：流水线已加入，未配置/生成开发者证书和 Sparkle 私钥，未触发发布；普通构建继续使用现有手动更新方式。
- **macOS 完整构建、原生 UI、真机和有签名网络扩展验收**：本机没有对应运行环境，均未声称通过。

格式参考：[Proxyman Import/Export](https://proxyman.com/docs/basic-features/import-export)、[规则备份说明](https://proxyman.com/docs/basic-features/import-export-settings)。发布参数以 [Sparkle 2.10.1 的 generate_appcast 源码](https://github.com/sparkle-project/Sparkle/blob/2.10.1/generate_appcast/main.swift) 为准。
