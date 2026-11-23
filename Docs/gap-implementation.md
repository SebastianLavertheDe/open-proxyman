# 功能差距开发验收记录

日期：2026-11-23。对应《ProxyMirror 与 Proxyman 功能与 UI 差距评审》。本记录区分源码实现、当前环境执行的检查和 macOS 待验收项目。

## 已实现的模块

| 评审项目 | 实现与入口 |
| --- | --- |
| MCP / CLI / PATH | HTTP MCP 与 stdio；流量查询、完整详情、增量 flows、完整原生 logs 与域名分组、规则 rename / duplicate、文件夹、工具开关、代码生成、代理配置；帮助菜单安装 CLI 和复制 MCP 配置 |
| Scripting | 独立 worker，CommonJS、本地 Addons、真实 Lodash / Moment / js-beautify、crypto 摘要、环境变量、跨调用 sharedState 与重置、异步 Hook、Mock API、fetch / @proxymirror/http / Axios HTTP 子集；网络等待与 CPU 限制独立；窗口内 MCP 生成脚本任务入口 |
| Diff | 独立窗口、100 条对比池、左右指定、7 个维度、统一 / 并排、JSON / Header 排序、词级差异、FileMerge / Kaleidoscope |
| Filters | 19 个字段、17 个比较符、嵌套 AND / OR、数值区间、通配 / 正反前后缀、命名预设和自动着色；手动高亮优先 |
| Network Conditions | 多条主机匹配规则、排序、12 种预设、延迟 / 抖动 / 上传下载限速 / 断连等，兼容原单条配置 |
| Protobuf | 全局描述符列表、RPC 自动解析、按 URL / 路径映射请求与响应类型、Single / Delimited、Binary / Base64、Converter、Console；描述符字节随备份迁移 |
| Compose | GET Query / JSON / Form / Multipart / QUERY / WebSocket 六种模板、超时、重定向、cURL 导入、20 条历史；WebSocket 实际握手并可发送、接收消息 |
| Copy as Code | 21 种目标，涵盖 cURL / HTTPie / Python / JS / Swift / Go / Node / Kotlin / Java / Dart / PHP / Rust / Objective-C / jQuery / Postman / HAR 等 |
| 规则文件夹与工具开关 | 通用嵌套文件夹、规则归属、祖先文件夹开关；基础规则、脚本、断点、DNS、弱网、反向代理、Protobuf 接入执行路径 |
| 导出共享 | HAR / CSV / 原生会话；Gist 公私发布、Keychain Token、预览和强制敏感头脱敏，管理请求禁用自身代理 |
| 断点 / 详情 | 可持久化请求与响应模板，保留当前连接和报文 framing；详情前后历史导航；独立汇总窗口；JS 自定义预览器管理与纯文本结果 |
| 显示设置 | 等宽字体、真实 Tab 布局、12 / 24 小时制、完整日期、可关闭斑马纹、默认复制格式；宽窗口图标分页、工具栏可定制、菜单栏图标、资源用量、URL 截断、换行 / 空白字符 / 分页缩略导航、隐藏 Apple 流量 |
| 请求与导出偏好 | 敏感头脱敏、复制命令追加代理、重发禁用缓存、可选诊断头 |
| 代理接入 | HTTP / SOCKS5 共用端口；多 IP / CIDR 访问控制；系统旁路列表使用原授权 helper，保存恢复 journal；External Proxy 支持全部 / bypass / inclusive 三种路由、主机与 URL 通配，并接入 HTTP/1、HTTP/2 和 PAC |
| Automation | Terminal / iTerm2 / Ghostty / 其他终端 / Chrome / Firefox / Electron，独立浏览器 Profile、代理与 CA 环境变量、启动失败反馈 |
| 内容编码 | 保留 gzip / deflate / br，新增静态链接且有输出 / window 限制的 zstd 解码器 |
| RFC 8441 | HTTP/2 SETTINGS 协商、逐流 extended CONNECT、WebSocket 握手与 DATA 桥接、同连接普通 HTTP 流、取消及背压；复用帧分析和脚本 |
| 证书 | PEM / DER / P12 导入向导、按用途校验、mTLS P12、DER / 加密私钥 PEM / P12 导出；Apple 模拟器证书安装器、自选 Preview 设备集、各框架指南 |
| 诊断运维 | 六项故障排查子菜单直达主题；真实系统内存压力与模拟警告共用缓存清理，保留捕获数据及文件；复制调试信息、诊断日志、数据 / 备份文件夹及恢复默认配置 |
| 软件更新 | 可选 Sparkle 2.10.1 验证签名更新；普通构建也可检查公开 Releases 元数据并提示新版本，由用户打开下载页，提供启动通知与变更日志入口 |

代理规则、文件夹、网络及 Protobuf 配置统一通过 `rules.json` 的私有原子文件提交；导入先验证，失败不发布新运行时快照。断点模板、自定义预览器和脚本运行时配置分别持久化。旧字段可继续解码。单份规则备份最多 16 MiB，Protobuf 描述符合计最多 8 MiB。私钥和 Gist Token 不纳入普通规则备份；外部代理认证配置会随对应配置备份，备份文件仅当前用户可读写。

## 本轮剩余 11 组缺口

- Inclusive 列表：配置、校验、UI、CLI / MCP 与逐请求路由；旧外部代理配置默认延续 bypass 行为。
- 脚本网络 API：真实 URLSession HTTP(S)，GET / POST、请求头与正文、Response、取消、重定向和限额；CPU 与网络等待分别计时。
- 五组显示偏好：字体、Tab、时间、斑马纹、复制格式均持久化，并随规则设置备份恢复。
- Simulate Memory Warning：与系统 warning / critical 共用可重建缓存清理链路；提供次数、来源与清理反馈。
- Scripting 的 MCP 提示：窗口内可复制任务模板、stdio 配置并打开 HTTP 连接配置。
- Flow Summary：互斥状态分桶、具体状态码、毫秒耗时分布、均值与 P50 / P95 / P99；统计当前筛选或其中所选请求。
- Saved：独立请求快照文件夹支持嵌套、新建、改名、移动、复制与删除；旧 `Saved.proxymirror` 保留并迁移至 `Saved.folders.json`。
- CLI：`export logs` 独立导出完整原生会话及域名分组，可回导；`rename` 不更改匹配条件，`duplicate` 重建身份并保留文件夹。
- 过滤面板：⌘N、⇧⌘N、⌘↑ / ⌘↓、⌘B 及现有搜索、取消快捷键具备可见操作与作用域。
- 编辑器内移到文件夹：DNS、断点与反向代理支持选择、新建、取消归属；规则与归属一并保存，取消不发布草稿。
- Troubleshooting：六项子菜单分别打开对应指南；已打开的指南也会切换到所选主题。

## 能力边界与外部配套

- Gist 使用用户提供的 GitHub Token。未创建 OAuth 应用，未实现 OAuth 浏览器授权回调；开发中没有创建真实 Gist。
- `.chls` / `.chlz` 原生会话通过本机已安装 Charles 的官方 `convert` 命令转换。XML / JSON 仍直接读取，不依赖 Charles。未实现专有二进制解码器，也未宣称支持 Proxyman Log。
- Addons 支持受控本地 CommonJS / JSON，未内置 npm 安装器或 Node 文件系统。网络通过限定的 HTTP(S) API 访问，不是完整 Node 运行时；Axios 仅提供文档列出的 HTTP 子集。内置库和许可见 `ThirdParty/ScriptingLibraries.md`。
- Inclusive 的 URL 路径匹配用于可读取 HTTP 请求的连接；不解密的 CONNECT 隧道只能按目标主机或根 URL 选择上游。
- Compose WebSocket 用于握手和首条消息调试；完整持续会话和帧分析沿用抓包 WebSocket 详情。
- 正文与 Raw 使用有界的原生连续文档和真实字符 Minimap；点击、拖动、键盘定位与正文视窗同步。预览仍保留原有大小上限，不额外加载未捕获字节。
- RFC 8441 下游使用 HTTP/2 extended CONNECT，上游转换为 HTTP/1.1 WebSocket；没有宣称源站侧也使用 HTTP/2 WebSocket。异步帧脚本排空后结束输出，取消会丢弃迟到结果。
- watchOS / tvOS / visionOS / SwiftUI Preview 提供实际 simctl 安装器及指南。标准设备集可直接列出；Preview 的自定义设备集目录需由用户选择，未猜测各 Xcode 版本隐藏路径。安装器不启动或删除设备。
- Android VPN companion app 未实现。原评审中的“VPN 免 root 安装系统 CA”需要更正：VPN 转发与系统信任库写入是不同能力，Android 官方 `installCaCert` 安装的是用户 CA。现有用户 CA / adb root / Magisk 与调试应用方案继续可用。[Android CA 安装 API](https://developer.android.com/reference/android/app/admin/DevicePolicyManager#installCaCert(android.content.ComponentName,%20byte[]))、[Proxyman Android 证书指南](https://proxyman.com/docs/debug-devices/android-device)。
- Sparkle 的发布 feed、公钥、Developer ID、公证及签名更新包由分发环境提供；当前仓库没有发布服务。普通构建从 GitHub 的公开版本接口检查新版本，不自动下载或安装。详见 `ThirdParty/Sparkle.md` 及 [GitHub Releases API](https://docs.github.com/en/rest/releases/releases#get-the-latest-release)。
- 保留中文及开源定位；未加入商业授权、Setapp、App Store 分发或遥测上报。

## 当前执行过的验证

当前开发主机为 Linux aarch64，已使用临时 Swift 6.0.3 工具链；没有 Xcode / AppKit。以下通过不能替代 macOS 完整编译或界面验收。

```sh
node Scripts/test_scripting_runtime.js
node Scripts/test_script_network_runtime.js
python3 Scripts/test_script_network.py --swift "$(command -v swiftc)"
python3 Scripts/test_summary_models.py
python3 Scripts/test_saved_models.py
python3 Scripts/test_request_code_models.py
Scripts/test_automation_contracts.sh
Scripts/test_network_access.sh
python3 Scripts/test_socks5_parser.py
python3 Scripts/test_zstd_decoder.py
python3 Scripts/test_updates.py
python3 Scripts/test_certificate_formats.py
git diff --check
```

脚本测试直接运行 worker 使用的 JavaScript，并访问真实本地 HTTP 夹具；原生网络测试编译实际 `ScriptNetworkBridge.swift`，34 条断言覆盖请求、取消、超时、重定向、正文上限和并发限制。统计 / 文件夹草稿 28 项、Saved 档案 26 项、路由 / 规则复制 46 项、IP / CIDR 47 项原生模型检查通过；平台与存储边界使用最小测试桩，不替换被测算法。18 个代码生成目标的两个夹具完成 24 项语法检查，12 项因对应语言工具缺失跳过；Node / Go 生成代码另外通过真实本地 HTTP 校验。SOCKS5 / zstd 使用实际 C 实现。全部 Swift 源码通过 Swift 编译器的语法解析；只对上述可移植代码进行了编译和执行，未进行完整 macOS 类型检查。

## 偏好设置对齐

设置改为 970×750 原生窗口、220 点分类侧栏与 52 点标题导航，深色配色按参考图的 ICC 转为 sRGB 后取样。常规、外观、MCP、工具、网络扩展、高级页面连接实际状态；隐私、GitHub、Workspace 和产品页提供本项目已有操作。额外 SSL、LAN、mTLS、旁路、外部代理和捕获上限保留在可搜索的高级设置中。

- 请求/响应上下或左右布局；字号、比例/等宽字体、Tab、字符缩略图、末行外滚动、含时区日期、主题、四款自有图标和独立外观重置。
- 独立启动录制、退出确认、语言切换、真实 CA 指纹与信任检测。待应用端口不进入运行地址或生成命令。
- MCP 运行中启停与 Claude Code / Codex / Manual 配置；默认专属脱敏覆盖流量、常见凭证、URL、正文和规则，内部记录不变。代码生成副本修正脱敏后的长度与编码。
- 原始请求头偏好恢复内容相关头，始终过滤代理凭据及连接专用头；HTTP/1、HTTP/2 的规则诊断头策略一致。
- 自动清理默认阈值 3072 MiB、周期 5 分钟，只处理较早已完成的实时请求；每轮有界，Saved、导入会话和处理中请求保留。实时速率使用单调计数，旧记录淘汰不抵消流量。
- 模拟器来源使用结构字段识别并随会话保存；关闭应用时可选恢复旧代理。开启网络扩展先恢复系统代理，保持两种模式互斥。

可在当前 Linux 环境执行的本轮回归：

```sh
python3 Scripts/test_preferences_models.py
python3 Scripts/test_display_models.py
python3 Scripts/test_system_retention_models.py
python3 Scripts/test_mcp_privacy.py
python3 Scripts/test_mcp_copy_commands.py
python3 Scripts/test_diagnostic_headers.py
python3 Scripts/test_release_updates.py
python3 Scripts/generate_localizations.py --check
```

这些脚本编译可移植生产代码，平台依赖处使用有限替身；不能替代 macOS 的完整类型检查。原生界面可在 Mac 构建后通过 `Scripts/test_preferences_ui.py --app build_app/ProxyMirror.app --appearance both` 输出真实 PNG 再与参考图比较。当前 Linux 未执行 GUI、真实扩展激活或最终像素验收。

## macOS 验收

```zsh
swift build --skip-update -j 2
.build/debug/ProxyMirrorSelfTest --core-unit
python3 Scripts/test_loopback.py --full
python3 Scripts/test_loopback.py --concurrency
python3 Scripts/test_http2.py
PM_APP_PATH="$PWD/.build/test-app/ProxyMirror.app" Scripts/make_app.sh debug
python3 Scripts/test_app_bundle.py --app .build/test-app/ProxyMirror.app
python3 Scripts/test_cli.py --app .build/test-app/ProxyMirror.app
python3 Scripts/test_mcp.py --app .build/test-app/ProxyMirror.app
python3 Scripts/test_script_network.py --worker .build/debug/ProxyMirrorScriptWorker
```

启动测试实例运行 `Scripts/test_socks5.py`。使用其 CLI 导出指定完整请求的代码，运行 `Scripts/test_request_code.py` 检查多语言语法。HTTP/2 测试包含 RFC 8441 多流、跨窗口帧、正常关闭和取消。CLI / MCP 回归新增 Inclusive 同主机不同路径的真实上游路由、全部工具改名与复制、文件夹继承和超过 100 条的原生日志导出。Gist、系统代理 helper、证书安装与信任、模拟器、外部 Diff、GUI 交互、签名自动更新需在对应 macOS 环境实测。已有 CA 精确匹配 / 重置、配置恢复及运行中连接清理的回归继续保留。

协议与接口依据：[MCP Streamable HTTP](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)、[GitHub Gists API](https://docs.github.com/en/rest/gists/gists#create-a-gist)、[Charles 转换命令](https://www.charlesproxy.com/documentation/tools/command-line-tools/)、[Sparkle 官方文档](https://sparkle-project.org/documentation/)。
