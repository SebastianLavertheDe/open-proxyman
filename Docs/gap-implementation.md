# 功能差距开发验收记录

日期：2026-11-23。对应《ProxyMirror 与 Proxyman 功能与 UI 差距评审》。本记录区分源码实现、当前环境执行的检查和 macOS 待验收项目。

## 已实现的模块

| 评审项目 | 实现与入口 |
| --- | --- |
| MCP / CLI / PATH | HTTP MCP 与 stdio，14 个工具；流量查询、完整详情、增量导出、规则七动作、文件夹、工具开关、代码生成、代理配置；帮助菜单安装 CLI 和复制 MCP 配置 |
| Scripting | 独立 worker，CommonJS、本地 Addons、真实 Lodash / Moment / js-beautify、crypto 摘要、环境变量、跨调用 sharedState 与重置、异步 Hook、请求 Mock API；分级 Console、跟随和过滤、⌘B / ⌘S |
| Diff | 独立窗口、100 条对比池、左右指定、7 个维度、统一 / 并排、JSON / Header 排序、词级差异、FileMerge / Kaleidoscope |
| Filters | 19 个字段、17 个比较符、嵌套 AND / OR、数值区间、通配 / 正反前后缀、命名预设和自动着色；手动高亮优先 |
| Network Conditions | 多条主机匹配规则、排序、12 种预设、延迟 / 抖动 / 上传下载限速 / 断连等，兼容原单条配置 |
| Protobuf | 全局描述符列表、RPC 自动解析、按 URL / 路径映射请求与响应类型、Single / Delimited、Binary / Base64、Converter、Console；描述符字节随备份迁移 |
| Compose | GET Query / JSON / Form / Multipart / QUERY / WebSocket 六种模板、超时、重定向、cURL 导入、20 条历史；WebSocket 实际握手并可发送、接收消息 |
| Copy as Code | 21 种目标，涵盖 cURL / HTTPie / Python / JS / Swift / Go / Node / Kotlin / Java / Dart / PHP / Rust / Objective-C / jQuery / Postman / HAR 等 |
| 规则文件夹与工具开关 | 通用嵌套文件夹、规则归属、祖先文件夹开关；基础规则、脚本、断点、DNS、弱网、反向代理、Protobuf 接入执行路径 |
| 导出共享 | HAR / CSV / 原生会话；Gist 公私发布、Keychain Token、预览和强制敏感头脱敏，管理请求禁用自身代理 |
| 断点 / 详情 | 可持久化请求与响应模板，保留当前连接和报文 framing；详情前后历史导航；独立汇总窗口；JS 自定义预览器管理与纯文本结果 |
| 显示设置 | 宽窗口图标分页、保留搜索；工具栏可定制、菜单栏图标、驻留内存 / 捕获速率、URL 截断、换行 / 空白字符 / 分页缩略导航、隐藏 Apple 流量 |
| 请求与导出偏好 | 敏感头脱敏、复制命令追加代理、重发禁用缓存、可选诊断头 |
| 代理接入 | HTTP / SOCKS5 共用端口；多 IP / CIDR 访问控制；系统旁路列表使用原授权 helper，保存恢复 journal 并保留第三方后续修改；外部代理旁路列表和 PAC 实际验证 |
| Automation | Terminal / iTerm2 / Ghostty / 其他终端 / Chrome / Firefox / Electron，独立浏览器 Profile、代理与 CA 环境变量、启动失败反馈 |
| 内容编码 | 保留 gzip / deflate / br，新增静态链接且有输出 / window 限制的 zstd 解码器 |
| RFC 8441 | HTTP/2 SETTINGS 协商、逐流 extended CONNECT、WebSocket 握手与 DATA 桥接、同连接普通 HTTP 流、取消及背压；复用帧分析和脚本 |
| 证书 | PEM / DER / P12 导入向导、按用途校验、mTLS P12、DER / 加密私钥 PEM / P12 导出；Apple 模拟器证书安装器、自选 Preview 设备集、各框架指南 |
| 诊断运维 | 复制调试信息、私有轮转诊断日志、数据 / 备份文件夹、规则与设置备份、停止代理后恢复默认配置 |
| 软件更新 | 可选 Sparkle 2.10.1，签名 feed / archive 验证、检查更新与自动检查偏好、变更日志入口；未配置的开发构建明确使用手动 Releases 页面 |

代理规则、文件夹、网络及 Protobuf 配置统一通过 `rules.json` 的私有原子文件提交；导入先验证，失败不发布新运行时快照。断点模板、自定义预览器和脚本运行时配置分别持久化。旧字段可继续解码。单份规则备份最多 16 MiB，Protobuf 描述符合计最多 8 MiB。私钥和 Gist Token 不纳入普通规则备份；外部代理认证配置会随对应配置备份，备份文件仅当前用户可读写。

## 能力边界与外部配套

- Gist 使用用户提供的 GitHub Token。未创建 OAuth 应用，未实现 OAuth 浏览器授权回调；开发中没有创建真实 Gist。
- `.chls` / `.chlz` 原生会话通过本机已安装 Charles 的官方 `convert` 命令转换。XML / JSON 仍直接读取，不依赖 Charles。未实现专有二进制解码器，也未宣称支持 Proxyman Log。
- Addons 支持受控本地 CommonJS / JSON，未内置 npm 安装器，也未向脚本开放 Node 网络 / 文件系统。内置库和许可见 `ThirdParty/ScriptingLibraries.md`。
- Compose WebSocket 用于握手和首条消息调试；完整持续会话和帧分析沿用抓包 WebSocket 详情。
- 正文缩略导航基于已有分页，未引入完整 IDE 编辑器的字符级 Minimap。
- RFC 8441 下游使用 HTTP/2 extended CONNECT，上游转换为 HTTP/1.1 WebSocket；没有宣称源站侧也使用 HTTP/2 WebSocket。异步帧脚本排空后结束输出，取消会丢弃迟到结果。
- watchOS / tvOS / visionOS / SwiftUI Preview 提供实际 simctl 安装器及指南。标准设备集可直接列出；Preview 的自定义设备集目录需由用户选择，未猜测各 Xcode 版本隐藏路径。安装器不启动或删除设备。
- Android VPN companion app 未实现。原评审中的“VPN 免 root 安装系统 CA”需要更正：VPN 转发与系统信任库写入是不同能力，Android 官方 `installCaCert` 安装的是用户 CA。现有用户 CA / adb root / Magisk 与调试应用方案继续可用。[Android CA 安装 API](https://developer.android.com/reference/android/app/admin/DevicePolicyManager#installCaCert(android.content.ComponentName,%20byte[]))、[Proxyman Android 证书指南](https://proxyman.com/docs/debug-devices/android-device)。
- Sparkle 的发布 feed、公钥、Developer ID、公证及签名更新包由分发环境提供；当前仓库没有发布服务。普通开发构建保留手动更新入口。详见 `ThirdParty/Sparkle.md`。
- 保留中文及开源定位；未加入商业授权、Setapp、App Store 分发或遥测上报。

## 当前执行过的验证

当前开发主机为 Linux aarch64，没有 Swift / Xcode / AppKit。以下通过不能替代 macOS 编译或界面验收。

```sh
node Scripts/test_scripting_runtime.js
python3 Scripts/test_socks5_parser.py
python3 Scripts/test_zstd_decoder.py
python3 Scripts/test_updates.py
python3 Scripts/test_certificate_formats.py
git diff --check
```

脚本测试直接运行 worker 使用的 JavaScript；SOCKS5 / zstd 测试编译并调用实际使用的 C 实现。Swift 使用语法树扫描和真实依赖源码 API 核对，未运行 Swift 类型检查。

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
```

另外运行 `Scripts/test_network_access.sh` 验证原生 IP / CIDR 模型；启动测试实例运行 `Scripts/test_socks5.py`。使用其 CLI 导出指定完整请求的代码，运行 `Scripts/test_request_code.py` 检查多语言语法。HTTP/2 测试包含 RFC 8441 多流、跨窗口帧、正常关闭和取消。Gist、系统代理 helper、证书安装与信任、模拟器、外部 Diff、GUI 交互、签名自动更新需在对应 macOS 环境实测。已有 CA 精确匹配 / 重置、配置恢复及运行中连接清理的回归继续保留。

协议与接口依据：[MCP Streamable HTTP](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)、[GitHub Gists API](https://docs.github.com/en/rest/gists/gists#create-a-gist)、[Charles 转换命令](https://www.charlesproxy.com/documentation/tools/command-line-tools/)、[Sparkle 官方文档](https://sparkle-project.org/documentation/)。
