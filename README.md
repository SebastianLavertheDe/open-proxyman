# ProxyMirror

仿 Proxyman 的 macOS 原生 HTTP/HTTPS 抓包调试工具。

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)

## 功能

- HTTP/1.x 和 HTTP/2 抓包，支持 HTTPS ALPN、HTTP/2 流级取消和 trailers、按域 SSL 解密及 WebSocket（含 RFC 8441 extended CONNECT）。
- gRPC、gRPC-Web 二进制和 Base64 文本检查，可查看 Protobuf 消息、状态与 trailers，并导入 FileDescriptorSet。
- Map Local、Map Remote、Block/Allow、No Caching、断点、脚本、DNS 映射和按主机模拟延迟、限速、抖动、断连和正文分块暂停。
- 反向代理、HTTP CONNECT、HTTPS CONNECT、SOCKS5 和 PAC 路由、上游 CA、mTLS 客户端身份与 TLS 密钥日志。
- 流量表格、自定义列、组合筛选、标签和分屏。详情提供 Query、Cookie、原文、耗时、JSONPath、jq 和二进制查看。
- Compose 支持 JSON、Form、Multipart、QUERY、WebSocket、超时和重定向；23 种 Copy as Code，常规重发经过本机代理。
- 独立 Diff 对比池、请求/响应/头/正文比较、JSON 排序、外部 Diff；19 字段高级过滤、嵌套 AND/OR、着色预设及详情历史导航。
- 保存流量、版本化会话、HAR / CSV、Gist 脱敏发布、Charles 会话及规则导入、含 Protobuf 描述符的规则与设置备份。
- 内置 HTTP / stdio MCP、完整 CLI、嵌套规则文件夹和工具总开关；Automation Dashboard 可启动带代理的终端、浏览器与 Electron。
- CommonJS Addons、Lodash / Moment、环境变量、sharedState、Mock API、分级 Console；脚本继续在有超时限制的独立进程内执行。
- HTTP 与 SOCKS5 共用监听端口，支持 zstd 解码、12 种多规则弱网预设、全局 Protobuf Schema 映射。
- 局域网按多 IP / CIDR 白名单接入，默认只监听回环地址；macOS 系统代理旁路列表随接管恢复。
- External Proxy 支持全部、排除列表和 Inclusive 包含列表；可按主机或 HTTP(S) URL 通配选择上游路由。
- Saved 请求支持嵌套文件夹、移动和复制，旧 Saved 托盘自动迁移；流量汇总提供状态分桶、耗时直方图与 P50 / P95 / P99。
- 偏好设置采用分类侧栏，支持搜索及前进后退；请求/响应可上下或左右排列。字号、等宽字体、Tab、字符 Minimap、末行外滚动、含时区的日期和主题均可设置。应用统一使用原有蓝底宇航员图标。
- MCP 可运行中启停，提供 Claude Code / Codex / Manual 的 HTTP 与 stdio 配置；默认脱敏 AI 返回数据。复制可保留原始内容头，规则处理消息可附带诊断头。
- 支持独立启动录制、退出确认、中英界面及日/西/葡三语言初版翻译、更新通知，以及按内存阈值和间隔清理较早已完成请求；帮助菜单保留故障排查和模拟内存警告。
- 脚本支持 `fetch`、`@proxymirror/http` 及 Axios 的 HTTP 子集，可等待 HTTP(S)、取消请求并设置超时；脚本窗口可复制 MCP 生成脚本任务。

常用快捷键为 ⌘F 过滤当前流量、⇧⌘F 查找来源、⌥⌘N 构建请求、⌘K 编辑请求、⇧⌘R 编辑并重发，以及 ⇧⌘C 复制 cURL。

开启「设置 → 工具 → Proxyman 兼容快捷键」后，当前视图过滤改为 ⇧⌘F、来源过滤改为 ⌥⌘F、正文查找为 ⌘F、Compose 为 ⌥⌘C、No Caching 为 ⌥⌘N、SSL 列表为 ⌥⌘P、编辑并重发为 ⌥⌘↩。正文获得焦点时 ⌘+ / ⌘− / ⌘0 缩放或重置字号；清除高亮为 ⇧⌘0。

规则窗口支持 ⌘N 新建、⌘↩ 编辑、⌘⌫ 删除、⌘D 复制、空格启停、⌘F 搜索。规则列表修改立即生效，单条编辑仍可取消。流量表支持原生表头排序、调宽和拖拽换序。

高级过滤面板内，⌘N 新增条件，⇧⌘N 新增子组，⌘↑ / ⌘↓ 导航，⌘B 切换预设着色；列表 ⌘C 使用所选默认复制格式。

## 界面语言

支持简体中文和英文，在设置中选择跟随系统、简体中文或 English，修改后下次启动生效。菜单、工具、帮助和自有错误反馈使用原生语言资源；用户名称、网络正文和脚本保持原文。

本版本首次正常启动会一次性清空旧版本的应用设置、规则、Saved 等本地数据，并改用稳定英文存储 ID；旧专有会话及规则备份不提供兼容读取。CA、钥匙串和系统代理恢复记录不在这次通用重置范围。

开发和验证方式见 [本地化实施记录](Docs/localization-implementation.md)。

## 构建 / 运行

主应用需要 macOS 13 或更新版本，以及提供 Swift 5.10 或更新版本的 Command Line Tools / Xcode。可用 `swift --version` 检查当前工具链；项目及当前锁定的核心依赖均以 Swift tools 5.10 为最低要求。独立的 ProxyMirrorBridgeKit 保持 Swift tools 5.9 的最低要求。打包和本地化校验还需要 SwiftGen **6.6.3**，可通过 `SWIFTGEN_BIN=/absolute/path/to/swiftgen` 指定；缺失或版本不符会阻止打包。

```zsh
swift build --skip-update -j 2
.build/debug/ProxyMirrorSelfTest
python3 Scripts/test_loopback.py --full
python3 Scripts/test_http2.py  # Go 1.19+ 构建本机测试服务，可用 PM_FIXTURE_GO 指定 Go

Scripts/make_app.sh debug
open build_app/ProxyMirror.app
```

从工具栏启动监听或录制。手动代理默认指向 `127.0.0.1:9090`。需要解密 HTTPS 时，可从「证书」菜单安装并信任本机 CA。

抓包列表默认保留当前选中项和滚动位置。需要跟随新请求时，点击列表下方的「自动选择」。

开始监听后，ProxyMirror 默认自动接管 macOS 系统代理。首次接管时，ProxyMirror 会通过 macOS 授权界面申请安装后台服务。同一份签名构建再次启动时会复用授权，重新签名的构建需要重新批准。可在「设置 → General」关闭「监听启动后自动接管系统代理」，也可在顶部状态弹窗里切换本次的录制、macOS 代理和网络扩展。

每次接管都会保存当时的 HTTP / HTTPS 代理设置。退出应用、停止监听或点击「恢复系统代理」时自动还原；App 意外退出时，后台服务也会根据连接断开尝试还原。恢复会保留接管期间由其他应用改写的代理项。恢复系统代理后，可在「设置 → General」中点「移除系统代理授权」卸载后台服务。

### macOS 透明抓包

带网络扩展的签名版本可从「工具 → 启动透明抓包」或「偏好设置 → 网络扩展」接入未设置 HTTP 代理的 Mac 应用。首次启动需按 macOS 提示批准网络扩展。当前覆盖 IPv4 / IPv6 的 TCP 80（HTTP）和 443（HTTPS）；HTTPS 沿用现有 CA 和按域、按应用 SSL 规则。UDP / QUIC / HTTP/3、其他端口和回环连接继续直连。开启透明抓包会先恢复系统代理；切回系统代理前需停止透明抓包。

默认 ad hoc 构建不附带扩展。准备匹配的 Developer ID Application 签名身份，以及主应用 `com.sebastianLavertheDe.proxymirror` 和系统扩展 `com.sebastianLavertheDe.proxymirror.transparent-proxy` 各自的 Network Extension 配置文件后构建：

```zsh
PM_DEVELOPER_ID='<Developer ID Application 的 SHA-1 或完整名称>' \
PM_APP_PROVISION_PROFILE='/path/to/app.provisionprofile' \
PM_EXTENSION_PROVISION_PROFILE='/path/to/extension.provisionprofile' \
PM_APP_PATH='build_app/transparent/ProxyMirror.app' \
  Scripts/make_app.sh release --transparent
python3 Scripts/test_app_bundle.py --app build_app/transparent/ProxyMirror.app --expect-transparent
```

正式分发或在保留 macOS 默认安全设置的测试机上激活扩展时，请先将签名应用提交 Apple 公证。若已在本机钥匙串配置 `notarytool` 凭据，可执行：

```zsh
ditto -c -k --keepParent build_app/transparent/ProxyMirror.app build_app/transparent/ProxyMirror-notary.zip
xcrun notarytool submit build_app/transparent/ProxyMirror-notary.zip --keychain-profile '<钥匙串中的公证凭据名称>' --wait
# 公证结果为 Accepted 时执行以下两条。
xcrun stapler staple build_app/transparent/ProxyMirror.app
xcrun stapler validate build_app/transparent/ProxyMirror.app
```

将公证后的应用放到测试 Mac 的「应用程序」目录再启动。使用自己的测试应用和非回环 HTTP / HTTPS 服务，确认未设置显式代理，再分别验证抓包、停止后直连、退出后直连。强制退出时，扩展在宿主握手失败后将新连接转向原始目标；已接管的连接需要客户端重连，ProxyMirror 下次启动时清理残留配置。真实激活、网络切换、休眠和 VPN 并存仍需在签名环境验收。 [Apple 系统扩展要求](https://developer.apple.com/documentation/systemextensions) · [Apple 公证流程](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)

### 按应用配置 SSL

打开「工具 → 按应用配置 SSL」，选择本机 `.app` 或填写 Bundle ID，为它选择「解密」或「透传」。也可以从已识别来源的 HTTPS 流量右键进入编辑器。保存后规则用于新建的 CONNECT 连接，正在复用连接的客户端需要重新连接。

全局 SSL 开关和排除主机优先。接下来使用启用的应用规则，未匹配应用、无法归因的进程和局域网设备沿用现有域名规则。应用归因使用本机回环 TCP 连接的进程和 Bundle ID，包内的网络辅助进程归到所属应用。透传时只记录 CONNECT，客户端直接验证服务端证书。

### HTTP/2 与 gRPC

在设置的 SSL 页可切换新建 HTTPS 连接的 HTTP/2 协商。HTTP/2 客户端转发到已配置的 HTTP 目标时可选用 h2c。流量详情的连接日志显示上游协议、ALPN 与流 ID。

选中 gRPC 流量后，从请求或响应的 gRPC 页检查消息。使用 `protoc --descriptor_set_out=echo.pb --include_imports echo.proto` 生成描述符，在该页导入 `echo.pb`。

### 设备与运行时接入

- 真机与 Mac 位于同一测试网络时，在 General 设置启用局域网代理，选择本机 IPv4、填写设备 IPv4 并应用。设备 Wi-Fi 代理填 Mac 的 IP 与监听端口。iOS 安装导出的 CA 后，在「设置 → 通用 → 关于本机 → 证书信任设置」打开对该 CA 的完全信任。联调结束后恢复设备原代理设置。 [Apple 证书信任说明](https://support.apple.com/en-us/102390)
- iOS 模拟器可从 Mac 的系统代理开始验证，并在模拟器中安装测试 CA。Android Emulator 的应用流量走 Android System Proxy 时，可使用 `10.0.2.2` 访问 Mac 回环监听。使用自己的 Android 调试构建时，在应用的调试网络安全配置中信任测试 CA。 [Android Emulator 代理](https://developer.android.com/studio/run/emulator-networking-proxy) · [Android Emulator 地址](https://developer.android.com/studio/run/emulator-networking-address)
- 终端可用 `curl --proxy http://127.0.0.1:9090 --cacert ./proxymirror-ca.pem <测试URL>` 验证。支持环境代理的 Node.js 版本可为单次进程设置 `NODE_USE_ENV_PROXY=1`、`HTTP_PROXY`、`HTTPS_PROXY` 和 `NODE_EXTRA_CA_CERTS`。 [Node.js 代理与 CA](https://nodejs.org/api/cli.html#node_use_env_proxy1)

- 「证书 → 在 iOS 上安装证书 → 一键配置 iOS 模拟器」通过 simctl 给已启动的模拟器安装 CA，然后使用已有的 macOS 授权流程接管系统代理。Android 用户证书可通过同一菜单的 adb 入口复制到设备，再在设备「设置」中确认安装。
- Android 13 或更早的可写测试镜像可用 `Scripts/install_certificate_android_emulator.sh <ca.pem> [serial]`。已配置 Magisk 且从系统目录读取 CA 的测试镜像可用 `Scripts/make_android_ca_magisk_module.sh <ca.pem> <module.zip>` 生成离线模块。 [Android 可写系统镜像](https://developer.android.com/studio/run/emulator-commandline) · [Magisk 模块格式](https://topjohnwu.github.io/Magisk/guides.html)
- 自研 iOS 调试应用可使用 [ProxyMirrorBridgeKit](./ProxyMirrorBridgeKit/README.md)，配对后直接把记录发送到 Mac。

### Charles 迁移

从「文件 → 导入 Charles 会话」选择 Charles 导出的 XML 或 JSON Session。原生 `.chls` / `.chlz` 可调用本机 Charles 的 `convert` 命令转为 HAR；未安装 Charles 时先导出 XML / JSON / HAR。打开「工具 → 从 Charles 导入规则」可预览兼容的规则和跳过项，再确认应用。 [Charles 转换命令](https://www.charlesproxy.com/documentation/tools/command-line-tools/)

### 来源文件夹与设置搜索

在侧栏「来源文件夹」旁点击加号，选择已捕获的应用或域名。右键应用、域名或文件夹可以调整归属和名称。文件夹匹配任意已选来源，可和当前视图的其他筛选条件组合。每个标签和分屏各自选择来源，文件夹名称和成员会在重启后恢复。

在设置窗口搜索 `HTTP/2`、`TLS MITM`、`正文 截断` 等关键词，选择结果可跳转并标出对应控件。回车打开第一个结果。

## 本机命令行

启动 ProxyMirror 后，从终端调用应用包内的二进制。状态和查询结果以 JSON 输出，错误写到标准错误。

```zsh
pm=./build_app/ProxyMirror.app/Contents/MacOS/ProxyMirror
"$pm" status
"$pm" traffic --method GET --status 404 --limit 20
"$pm" traffic --url /api/ --limit 50
"$pm" export-har --selected --output ./selected.har
"$pm" export-har --id 8233BD29-7982-4534-9FF3-B70EE20F5AFB --output -
```

`status` 分别报告代理监听、录制和系统代理状态。`traffic` 和 `export-har` 默认查询实时捕获。`--selected` 改为当前视图选中的记录，也可同时使用其他筛选条件。查询按捕获顺序返回最近匹配的记录，默认 100 条，最多 1000 条。

HAR 包含已捕获的请求头、响应头和正文。单次导出的正文上限为 24 MiB，超过时可缩小筛选范围。指定文件路径时，应用以当前用户可读写的权限写入文件。`--output -` 将 HAR 写到标准输出。

`export logs` 导出当前保留的完整原生会话，不采用流量查询默认的 100 条上限。`domains` 按域名分组，导出的日志包也可直接作为会话重新打开；可以用域名和带时区的 ISO 8601 时间拆分。`export flows` 继续提供增量查询和分页。

```zsh
"$pm" export logs all --output ./traffic.proxymirror
"$pm" export logs domains --domains '*.example.com' --output ./domains.proxymirror
"$pm" rules dns rename --id "$rule_id" --name '测试 DNS'
"$pm" rules dns duplicate --id "$rule_id" --name '测试 DNS 副本'
```

### 规则与设置迁移

```zsh
"$pm" rules export --output ./backup.json
"$pm" rules export --tool dns --output ./dns.json
"$pm" rules export --tool sslApplications --output ./ssl-apps.json
"$pm" rules preview --input ./backup.json --mode merge
# 核对预览后，将返回的 previewToken 赋给 preview_token
"$pm" rules apply --input ./backup.json --mode merge --preview-token "$preview_token"
```

规则预览报告新增、覆盖、移除、相同和顺序变化。默认 `merge` 按规则 ID 合并，按应用 SSL 使用 Bundle ID 合并。`replace` 只替换备份中包含的工具。输入文件、导入方式或当前配置变化后需重新预览。支持 ProxyMirror JSON 备份和旧版 `rules.json`，备份涵盖基础规则、DNS、断点规则、延迟模拟与应用常用设置。Map Local 保留文件路径，文件内容需在目标 Mac 准备。应用设置在下次启动时生效，也可前往设置手动应用。

| 退出码 | 含义 |
| --- | --- |
| 0 | 成功 |
| 2 | 命令或筛选参数无效 |
| 3 | 无法连接本机应用 |
| 4 | 通信、导出或应用规则失败 |
| 5 | 当前视图无选中记录，或导出条件无匹配 |
| 6 | 规则预览已失效 |

## 架构

### MCP、规则工具与开发工作台

从「帮助 → 安装 proxymirror-cli 到 PATH」安装 CLI，重新打开终端后可运行：

```zsh
proxymirror-cli proxy-address
proxymirror-cli flow --id <UUID>
proxymirror-cli export flows --format json --after-id <UUID> --limit 100 --output -
proxymirror-cli rules mapLocal list
proxymirror-cli tools disable --tool rewrite
proxymirror-cli code --id <UUID> --language swift
proxymirror-cli mcp config
```

应用启动时在随机回环端口开启 MCP。`mcp config` 输出本次端点及令牌；令牌文件权限为 0600，应用退出后清理。可从「帮助 → 查看 MCP 连接配置」复制 HTTP 配置，或将 AI 客户端配置为启动 `proxymirror-cli mcp stdio`。`--after-id` 每页返回游标之后最早的一批记录，继续用该页最后一条 ID 翻页，避免新增流量超过页大小时遗漏。

「工具」菜单提供 Diff、Protobuf、规则文件夹、自定义预览器、汇总和 Automation 独立窗口；脚本窗口支持 ⌘B 格式化、⌘S 保存启用。自定义预览器接收 `preview(input)`，在独立 worker 内返回文本或 JSON。执行结果以纯文本显示。

规则、文件夹、工具总开关和 Protobuf 描述符统一保存到 `rules.json`；单份备份上限 16 MiB。证书菜单提供 PEM / DER / P12 导入向导与加密私钥导出。Gist 发布需填写具备 Gists 写权限的 GitHub Token，可保存到钥匙串；发布前可检查已脱敏的 HAR 预览。

实现范围、验证命令和仍需外部配套的能力见 [差距开发验收记录](Docs/gap-implementation.md)。

```
Sources/
  ProxyMirrorProcessSupport/ # spawn 平台 C 包装，保留子进程 FD 隔离
  ProxyMirrorFoundation/  # 可移植协议、匹配、持久化、检查、导出及进程策略
  ProxyMirrorCore/        # macOS 应用集成
    DesktopApplication/   # 菜单、窗口、CLI/MCP 分派和正式 package 应用入口
    Proxy/                # nio 代理引擎 + HTTP 解析 + MITM 证书 + SNI 嗅探
    Model/                # Transaction / TrafficStore / AppSettings
    UI/                   # 侧栏 / 列表 / 详情 / 设置（SwiftUI）
    Export/               # HAR + cURL + Repeat
    System/               # SystemConfiguration 系统代理 + 证书与信任配置
  ProxyMirror/            # @main 薄入口，调用正式 package API
  ProxyMirrorSelfTest/    # CLT 单测入口、回环、并发及基准
Tests/
  ProxyMirrorFoundationTests/ # 直接导入生产模块的跨平台 XCTest
  ProxyMirrorCoreChecks/      # macOS / Combine / 引擎与 UI 适配检查
Scripts/                  # 测试夹具、打包与构建
```

生产应用通过 package 入口连接 Core，发布打包仅构建应用及实际随包助手，不依赖 `@testable import` 或 `-enable-testing`。HTTP/1 与 HTTP/2 共用请求路由计划；协议处理器保留各自的连接、流控和缓冲状态。已发布流量的元数据修改统一派发到主线程，正文存储继续使用有预算的独立同步机制。

Automation、Repeat、Compose 及代码导出通过运行时 context 使用所选引擎、CA 与配置。JSON/GraphQL 列和过滤采用不可变快照、后台派生缓存和待完成状态；实时捕获时保留已完成的排序批次。Diff 文档和 JSON 高亮在生成阶段限制输出与着色范围，并响应取消。Saved 写入失败保留待存快照，退出会重试，仍失败则提示并取消退出。

正文检查可根据 gzip 特征识别没有声明 `Content-Encoding` 的压缩载荷。Tars/JCE 正文按字段标签编号转换为 JSON，供正文、预览、树和查询共用；没有协议定义时不猜测业务字段名。自动识别未标注的 Tars/JCE 仅用于解压后的通用二进制内容，并要求完整解析多个有序字段。捕获字节、头部和重放内容保持原样；不支持的二进制仍显示 Hex。

截图样本、识别边界及回归入口见 [gzip 与 Tars/JCE 正文显示修复](Docs/body-inspection-gzip-tars-2026-11-24.md)。

## 本机构建注意事项

可使用提供 Swift 5.10 或更新版本的 macOS Command Line Tools，项目通过 SelfTest 可执行文件运行回归。如果本机环境终止并行编译，可改用 `swift build -j 1`。首次拉取依赖后遇到明确的 UTF-8 解码错误时，可检查依赖 checkout 的文件内容。

## 测试

### 可移植模块与持续集成

根包在 Linux 仅启用 `ProxyMirrorFoundation`、进程 C 包装、其测试及运输夹具，macOS 再加入桌面应用和原生集成目标。Foundation 测试直接导入生产模块，覆盖 HTTP、正文检查、CSV 原子写入、进程取消、留存和稳定错误身份；`test_compose_transport.py` 通过正式 SwiftPM 夹具验证真实 cURL、重定向及 trailers 与正文分离。运行时不要让 Linux 的目标图改写桌面依赖锁，可在临时源码副本测试：

```sh
validation_root="$(mktemp -d)"
tar --exclude=Package.resolved -cf - Package.swift Sources Tests | tar -xf - -C "$validation_root"
(
  cd "$validation_root"
  swift test -j 2
)
```

[持续集成配置](.github/workflows/validation.yml) 包含 Linux Foundation 和三条独立 macOS 验证：debug 的真实模块与代理回归、五语言设置窗口及打包检查；不带测试可见性开关的 release 打包；Thread Sanitizer 下的原生核心、并发和 HTTP/1、HTTP/2 回归。新增配置需要在远端实际运行后才能证明这些原生检查通过。

### 偏好设置界面验收

设置窗口按参考布局提供常规、外观、隐私、MCP、GitHub、工具、网络扩展、高级、Workspace 和产品页面。旧 SSL、局域网、mTLS、旁路和外部代理设置位于「高级代理设置…」，也可直接搜索定位。

在 Mac 上构建后可导出真实原生窗口截图。截图模式使用临时数据目录，跳过代理、MCP 和更新服务启动，不修改用户偏好，也不需要屏幕录制权限：

```zsh
Scripts/make_app.sh debug
python3 Scripts/test_preferences_ui.py --app build_app/ProxyMirror.app --appearance both
python3 Scripts/test_preferences_ui.py --app build_app/ProxyMirror.app --pages general appearance tools --language en
```

PNG、窗口尺寸和每页的 `.layout.json` 默认保存在 `build_app/preferences-review/`。截图时会测量实际 header，要求其完整处于窗口未遮挡的 `contentLayoutRect` 和父视图可见范围内；标题栏覆盖、父级裁切或 header 高度被压缩都会让验收失败。PNG 捕获包含系统标题栏，像素与交互仍需对照参考图检查。网络扩展激活另需前述签名构建。

复测设置标题栏裁切可运行 `python3 Scripts/test_preferences_ui.py --app build_app/ProxyMirror.app --pages mcp workspace --language both --appearance dark`。当前的几何判定负例可跨平台运行 `python3 Scripts/test_preferences_layout.py`，它不代替真实 macOS 界面检查。[Apple 内容布局区域说明](https://developer.apple.com/documentation/appkit/nswindow/contentlayoutrect)

### 核心与代理回归

核心单测由 XCTest 和 CLT 自测入口共用。HTTP 回环、CLI 和并发套件使用本地夹具及独立数据目录。打包检查核对签名、架构、脚本 worker 和 CLI 入口。

```zsh
swift build --skip-update -j 2
.build/debug/ProxyMirrorSelfTest --core-unit
python3 Scripts/test_loopback.py --full
python3 Scripts/test_loopback.py --concurrency
python3 Scripts/test_http2.py
python3 Scripts/test_http_transport.py

PM_APP_PATH="$PWD/.build/test-app/ProxyMirror.app" Scripts/make_app.sh debug
python3 Scripts/test_app_bundle.py --app .build/test-app/ProxyMirror.app
python3 Scripts/test_cli.py --app .build/test-app/ProxyMirror.app
```

HTTP/2 可用 `PM_FIXTURE_GO` 指定 Go，也可用 `PM_HTTP2_FIXTURE_BIN` 传入由同一夹具源码构建的可执行文件。在完整 Xcode 环境用 `swift test --filter ProxyMirrorCoreTests --enable-code-coverage` 运行 XCTest 并生成覆盖率。

`test_http_transport.py` 使用独立临时数据目录检查真实代理的自连接拒绝、HTTP 报文边界和 Host，并并行验证 40 秒的固定长度 / chunked 上传及 35 秒静默的 SSE。该套件需要 macOS 构建的 SelfTest，可通过 `--binary` 指定路径，不接管系统代理或操作钥匙串。

以下边界回归使用生产 Swift 实现，可在具备 Swift 5.10 或更新工具链的 Linux 或 macOS 上运行。已迁入 Foundation 的策略通过真实模块测试，平台适配夹具仍用于补充验证；脚本支持 `--swiftc` 指定编译器，根 CA 检查使用 `--swift` 指定 SwiftPM：

```sh
python3 Scripts/test_http_safety.py
python3 Scripts/test_mcp_privacy.py
python3 Scripts/test_compose_transport.py
python3 Scripts/test_pending_saves.py
python3 Scripts/test_script_frame_decisions.py
python3 Scripts/test_device_commands.py
python3 Scripts/test_inspection_safety.py
python3 Scripts/test_root_ca_validation.py
python3 Scripts/test_saved_models.py
python3 Scripts/test_processed_localization.py
python3 Scripts/test_process_support.py
python3 Scripts/test_sse_issues.py
python3 Scripts/test_body_inspection.py
python3 Scripts/test_core_check_runner.py
```

`test_http_safety.py --nio-package .build/checkouts/swift-nio` 还会执行实际 NIO 连接拦截回归。根 CA 检查使用锁文件中的 X509 / Crypto 版本；可用 `--local-dependencies` 指定包含 `swift-certificates`、`swift-crypto` 和 `swift-asn1` 的本地依赖目录。可移植检查不代替 macOS 整包、UI、钥匙串及系统扩展验收。

`test_processed_localization.py` 使用真实 SwiftPM `.process` 资源验证语言目录解析；`test_process_support.py` 检查生产进程执行器的 FD 隔离；`test_sse_issues.py` 验证 SSE 与弱网错误的稳定身份和双语显示，需要 zlib 开发头及链接库。Core XCTest 每组在独立 SelfTest 子进程运行，保留逐 case 进度和超时诊断。

问题及逐项修复记录见 [全项目代码审查](Docs/code-review-2026-11-24.md)、[结构、性能与多语言补充审查](Docs/architecture-performance-localization-review-2026-11-24.md) 和 [R30–R45 深入复审与修复记录](Docs/deep-review-4610101-2026-11-24.md)。

### Thread Sanitizer

```zsh
tsan_scratch="${PM_TSAN_SCRATCH:-.build/tsan}"
swift build --scratch-path "$tsan_scratch" --sanitize=thread --skip-update -j 2
tsan_bin="$(swift build --scratch-path "$tsan_scratch" --sanitize=thread --show-bin-path)"
TSAN_OPTIONS=halt_on_error=1 PM_SELFTEST_BIN="$tsan_bin/ProxyMirrorSelfTest" \
  python3 Scripts/test_loopback.py --concurrency --timeout 180
TSAN_OPTIONS=halt_on_error=1 PM_SELFTEST_BIN="$tsan_bin/ProxyMirrorSelfTest" \
  python3 Scripts/test_loopback.py --timeout 180
```

如果经 Python 启动的 TSan 进程在初始化时退出，可以从 shell 直接运行自带本地源站的并发套件。

```zsh
tsan_support="$(mktemp -d -t proxymirror-tsan)"
TSAN_OPTIONS=halt_on_error=1 PM_SUPPORT_DIR="$tsan_support" "$tsan_bin/ProxyMirrorSelfTest" --concurrency
```

### 性能回归

Release 自测测量实际的流量筛选排序和正文追加。回环压测测量直连、暂停录制和开启录制的 HTTP/1.1 代理链路，核对每条响应及录制计数。用相同机器和负载参数复跑，可通过 `--baseline` 对照上一份回环报告。完整 Xcode 可运行 `swift test -c release --filter ProxyMirrorPerformanceTests`，在 XCTest 中记录耗时和内存基线。

```zsh
swift build -c release --product ProxyMirrorSelfTest -Xswiftc -enable-testing --skip-update -j 2
mkdir -p .build/performance
.build/release/ProxyMirrorSelfTest --benchmark-core > .build/performance/core.json
python3 Scripts/bench_proxy.py --output .build/performance/small-requests.json
```

UI 和 macOS 系统验收步骤见 [交付与验收记录](./Docs/proxyman-alignment-2026-11-25.md)。

## 对齐范围

本次实现、验证结果及外部依赖见 [Proxyman 对齐记录](./Docs/proxyman-alignment-2026-11-25.md)，前一轮能力范围见 [功能实现记录](./Docs/gap-implementation.md)。

## 调试技巧

- 偏好窗口可用 `python3 Scripts/test_preferences_ui.py --app build_app/ProxyMirror.app --appearance both` 离屏验收，内部使用 `PM_SETTINGS_SNAPSHOT`。主窗口目前没有 `PM_SNAPSHOT` 接口。
- 引擎日志（代理启停/上游拨号/根证书数量）输出到 stdout。
