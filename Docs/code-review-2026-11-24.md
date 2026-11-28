# ProxyMirror 全项目代码审查

审查日期：2026-11-24。基线：`1e7d8b3b2785906ffe556c6e71a6816819158bf8`，审查开始时工作区干净。审查由主审与五个子 agent 分模块完成；后续按用户授权修复，并增加独立交叉复审。

基线共记录 **15 项：4 项 P1、10 项 P2、1 项 P3**，现均已落实代码修复和对应回归。当前验证使用 Linux Swift 6.0.3 编译可移植生产实现，macOS 整包与系统行为验收尚未执行。下文先列修复结果，再保留原始审查依据。

## 修复结果

| 编号 | 实现 | 验证 |
| --- | --- | --- |
| R01 | [实际 socket connect 地址拦截](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Proxy/ProxySelfConnectionGuard.swift:11)，覆盖解析结果、回环、LAN 和 IPv4 映射地址；H1、H2 和外部代理共用 | 实际 NIO EmbeddedChannel 与本地 TCP DNS 连接回归通过 |
| R02 | [统一 framing 校验](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorFoundation/HTTP/HTTPFraming.swift)，拒绝 TE 加 CL 和冲突长度，归一化重复长度、TE 列表及字段语法；入口、转发和响应复用 | 生产解析器与 wire 数据回归通过；真实代理 TCP 套件已补，待 Mac 运行 |
| R03 | [先递归脱敏再覆盖 name 和 value](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Export/ExportRedaction.swift:91) | 嵌套、兄弟字段、Base64 正文和复制链回归通过 |
| R04 | [按 MIME 语法处理 multipart](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Export/ExportRedaction.swift:251)，覆盖 token、quoted-string、大小写、折行、前导文本；同时合并 SSE 事件的 data 字段后脱敏 | 生产 Swift 隐私检查与独立复审通过，包括 MIME 中含 SSE 和多行 JSON 事件 |
| R05 | absolute target 重建 Host，路由阶段再按最终目标重建；原始 HTTP target 与 Compose 应用 URL 分开校验 | 冲突 Host、IPv6、端口、origin-form 和 URL / wire 区分回归通过 |
| R06 | [按上传和下载进度计算超时](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorFoundation/HTTP/HTTPTransferTimeoutPolicy.swift)，上传后重新计时，SSE 响应头后停用普通正文空闲超时 | 生产时钟策略检查通过；真实 40 秒上传及 SSE 静默回归已补，待 Mac 运行 |
| R07 | [正则匹配预算与中止](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorFoundation/Matching/BoundedTrafficRegex.swift:7)，默认 8ms / 128 次进度回调，支持取消及超限隔离；正负规则共用 | 实际 ICU 回调中止约 0.004 秒；取消、工作预算、隔离及正常匹配通过 |
| R08 | [保留待提交状态](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorFoundation/Persistence/PendingSave.swift:4)，[退出前及异步退出完成前刷新](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/DesktopApplication/ProxyMirrorApp.swift:467)，失败反馈并取消退出 | 13 条真实文件和定时器检查通过；RulesStore 重开集成回归已补 |
| R09 | [修正 drop 布尔语义](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Interception/ScriptingService.swift:284)，保留独立 false 和显式 action 的语义 | 11 条真实 Swift 解码与判定检查通过 |
| R10 | [共享根 CA 校验](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/System/RootCAValidation.swift:5)，两个导入入口都在替换前验证有效期、密钥、CA 约束及 keyCertSign | 锁定 X509 / Crypto 下 9 条生产验证检查通过；保留原 CA 文件和缓存的集成回归已补 |
| R11 | [设备命令有界执行](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorFoundation/System/DeviceCommandRunner.swift:10)，独立进程组、私有输出文件、默认 30 秒、取消及 TERM 到 KILL 清理 | 16 条真实子进程检查通过，含双输出、后代清理和回收 |
| R12 | [HEAD 使用正确 cURL 模式](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorFoundation/HTTP/HTTPRequest.swift)，非空实体按已有 Compose 策略省略并给出注释，过滤冲突 CL | 空 / 非空 HEAD 与原始头偏好均经实际生成命令和本地 HTTP 验证 |
| R13 | [显式逐跳重定向](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorFoundation/HTTP/HTTPRequestTransport.swift)，正确转换方法和实体，跨源剥离凭证，保留整体期限和十跳上限 | 48 条真实 HTTP / cURL 检查通过，含 35 种重定向组合、挂起中间正文和取消 |
| R14 | [MessagePack 非 JSON 类型显式表示](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorFoundation/Inspection/MessagePackBody.swift:159)，非字符串键使用 `_map`，NaN / Infinity 使用 `_float`，最终校验 JSON | 与 R07 合计 37 条生产检查通过；原始字节继续保留 |
| R15 | [最低工具链统一为 Swift 5.10](/home/say/work/github/ProxyMirror/Package.swift:1)，同步 README 与 Sparkle 说明，BridgeKit 独立保持 5.9 | 普通应用、Sparkle 应用和 BridgeKit 三种 manifest 解析通过 |

初轮专项检查共 **259 项通过**：HTTP 解析与策略 67、实际 NIO 连接 14、MCP 隐私 44、Compose / cURL 48、待保存状态 13、WebSocket 帧判定 11、根 CA 校验 9、设备命令 16、正则与 MessagePack 37。初轮帧判定脚本提取平台无关方法，Compose 脚本曾使用有限的平台替身；后续结构修复已让 Compose 直接构建生产模块和正式 fixture，相关文件位置同步到上表。最新验证与 R16 至 R29 修复见[补充审查记录](architecture-performance-localization-review-2026-11-24.md)。

另有 276 个 Swift 文件语法检查、本地化 2173 keys / 14 张表校验、19 个既有可移植套件通过；代码变更后对受影响的五个既有套件再次验证通过。代码生成检查中有 12 项语言语法检查因缺相应工具而跳过。

原生验收入口为 `swift build --skip-update -j 2`、`.build/debug/ProxyMirrorSelfTest --core-unit`、`python3 Scripts/test_http_transport.py` 和项目既有 HTTP / HTTP2 / UI 套件。新 transport 套件采用临时支持目录，并行验证 40 秒固定长度和 chunked 上传，以及 35 秒静默 SSE；本轮未在 Linux 执行该 macOS 套件。

## 原始审查依据

以下问题描述、行号及审查阶段的验证状态对应上述基线。当前实现和本轮结果以修复表为准。

P1 表示应优先修复的可用性或安全边界缺陷；P2 表示有明确触发条件的功能、持久化或性能缺陷；P3 表示较低优先级的工程合同问题。优先级反映影响与修复顺序，不代表本轮已经证明完整攻击利用链。

## 问题清单

| 编号 | 优先级 | 问题 | 主要影响 |
| --- | --- | --- | --- |
| R01 | P1 | 直接连接未阻止访问代理自身 | 单请求递归创建连接与事务 |
| R02 | P1 | HTTP 正文边界存在歧义 | 代理与上游可能对请求边界产生不同判断 |
| R03 | P1 | MCP JSON 脱敏提前返回 | 同对象其他密码和 token 泄露 |
| R04 | P1 | MCP multipart 脱敏依赖特定文本格式 | 合法表单格式中的密码泄露 |
| R05 | P2 | absolute URL 与 Host 未统一 | 域名规则和实际虚拟主机不一致 |
| R06 | P2 | 上传期间错误应用响应读超时 | 正常慢速上传超过约 30 秒失败 |
| R07 | P2 | 主线程执行无预算正则匹配 | 极短输入即可长时间冻结界面 |
| R08 | P2 | 退出前未刷新规则保存定时器 | 快速正常退出丢失最后修改 |
| R09 | P2 | WebSocket drop 字段布尔值反转 | 条件丢帧脚本行为相反 |
| R10 | P2 | 根证书旧导入入口缺少校验 | 无效 CA 替换正常 CA 后解密失败 |
| R11 | P2 | 设备命令无超时和取消 | ADB 掉线后操作可能永久挂起 |
| R12 | P2 | HEAD 生成的 cURL 缺少无正文模式 | 复制的命令报错或持续等待 |
| R13 | P2 | Compose 重定向固定原始方法 | POST 经 303 后仍发 POST |
| R14 | P2 | MessagePack 转换产生非法 JSON | JSON 树和查询不能使用 |
| R15 | P3 | 工具链说明低于依赖要求 | Swift 5.9 环境无法解析依赖 |

## 优先修复的问题

### R01 直接连接未阻止访问代理自身

定位：[HTTP2UpstreamPool.swift 第 57 行](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Proxy/HTTP2UpstreamPool.swift:57)。`HTTPOrigin.connect` 的直接连接分支没有使用传入的 `listenerPort`。普通 HTTP 转发、CONNECT 和 Map Remote 会经过这一分支。

在默认端口监听时，发送 `GET http://127.0.0.1:9090/ HTTP/1.1`，并设置 `Host: 127.0.0.1:9090`。代码路径为 `handleRequestHead → openUpstream → HTTPOrigin.connect → 当前监听入口`，下一层再次执行相同转发。连接与事务会递归增长，直到超时或耗尽资源。SOCKS5 与外部代理路径已有部分自连接保护，普通 HTTP 直接连接缺少对应检查。

应统一判断目标是否属于当前实例的监听地址与端口，并覆盖 DNS 解析、DNS 映射、回环及 LAN 地址。验收时在隔离实例中覆盖这些地址，断言请求及时失败，连接数和事务数没有连续增长。本项依据完整源码调用链确认，尚未在 macOS 运行递归连接复现。

### R02 HTTP 正文边界存在歧义

定位：[ProxyEngine.swift 第 805 行](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Proxy/ProxyEngine.swift:805)，以及 [HTTPMessage.swift 第 296 行](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorFoundation/HTTP/HTTPMessage.swift:296)。正文判断只读取首个 `Transfer-Encoding` 或 `Content-Length`，并使用 `contains("chunked")` 判断编码；转发时保留全部原始 CL 与 TE 字段。

冲突的重复 CL 没有被拒绝；TE 与 CL 同时存在时仍转发 CL；多个 TE 没有合并解析，也没有检查 `chunked` 是否为最后一种编码。代理和上游因此可能对同一字节流划出不同请求边界。[RFC 9112 第 6.3 节](https://www.rfc-editor.org/rfc/rfc9112.html#section-6.3) 对这些情况有明确的拒绝、移除字段及关闭连接要求。

应在路由、规则执行和上游拨号前完成统一 framing 校验，转发时只使用归一化结果。验收需加入原始 TCP 用例，覆盖重复冲突 CL、逗号 CL、TE 加 CL、分行 TE、`chunked,gzip` 和非法长度，并检查连接复用及后续请求。已确认源码接受并转发歧义字段；本轮没有证明完整的跨服务请求走私利用链。

### R03 MCP JSON 脱敏提前返回

定位：[ExportRedaction.swift 第 98 行](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Export/ExportRedaction.swift:98)。对象包含敏感的 `name` 和 `value` 时，`sanitize` 仅替换 `value`，立即返回整个对象副本，跳过其余字段。

例如响应正文为：

```json
{"name":"token","value":"x","password":"real-secret","nested":{"access_token":"real-secret2"}}
```

`value` 会被隐藏，`password` 和嵌套 `access_token` 仍保留原文。`get_flow`、`export_flows` 及请求代码生成通过 `redactedCopy → jsonData → sanitizedBase64 → text → sanitize` 进入这一分支。外层再次脱敏仍会遇到相同的提前返回，不能补救。

应先递归处理对象所有字段，再覆盖敏感 `name/value` 的 `value`。验收应同时覆盖普通 JSON、Base64 正文、嵌套对象及 MCP 生成代码，确保原始 secret 不出现在任何返回载体中。这是可按具体输入逐分支确认的源码缺陷，尚未执行真实 MCP 会话复现。

### R04 MCP multipart 脱敏依赖特定文本格式

定位：[ExportRedaction.swift 第 142 行](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Export/ExportRedaction.swift:142)。入口大小写敏感地检测 `Content-Disposition: form-data`，内部正则只识别 `name="password"`，不识别合法的 token 参数 `name=password`。

下面的正文使用 CRLF 分行时，敏感值会原样返回：

```text
--b
Content-Disposition: form-data; name=password

real-secret
--b--
```

小写 `content-disposition` 也会绕过专用处理。[RFC 2183](https://www.rfc-editor.org/rfc/rfc2183.html) 的参数语法允许 token 值。该缺陷会影响默认开启脱敏的 MCP 正文输出。

应按 MIME 参数语法处理字段名、大小写、空白和 quoted-string，并为无法可靠解析的敏感 part 采用保守隐藏。验收至少覆盖带引号、不带引号、混合大小写及额外参数，并检查 `get_flow`、HAR 和代码生成链。当前结论来自具体输入及源码分支，尚未在 Swift 原生执行。

## 功能与可靠性问题

### R05 absolute URL 与 Host 未统一

定位：[ProxyEngine.swift 第 870 行](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Proxy/ProxyEngine.swift:870)。目标地址及事务 URL 来自 absolute-form 请求行，`effectiveHeaders` 默认保留客户端原始 Host；只有 Map Remote 分支重写它。

请求行指向 `http://allowed.test/x`、Host 却为 `other.test` 时，会连接 `allowed.test` 的地址，再由共享 IP 的服务端选择 `other.test` 虚拟主机。展示 URL、域名规则与实际访问对象发生分离。[RFC 9112 第 3.2.2 节](https://www.rfc-editor.org/rfc/rfc9112.html#section-3.2.2) 要求代理根据 absolute target 重建 Host。

应统一从最终目标生成 Host。验收使用同地址的两个虚拟主机，覆盖冲突 Host、非默认端口、IPv6、origin-form 及 Map Remote。本项为源码调用链确认。

### R06 上传期间错误应用响应读超时

定位：[ProxyEngine.swift 第 1606 行](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Proxy/ProxyEngine.swift:1606)，计时器安装于同文件第 1427 行。上游建立连接后开始固定 30 秒读空闲计时，超时回调没有判断固定长度或 chunked 请求正文是否仍在上传。

客户端持续缓慢上传，而源站等待完整正文后再响应时，即使上传正常，也可能在约 30 秒收到 504。该策略还会影响长时间没有新事件的 HTTP/1 SSE。

应区分上传进度、等待首个响应及流式响应空闲策略。验收让客户端持续 40 秒以上发送固定长度和 chunked 正文，源站读完后成功响应；同时保留上传完成后源站不响应的超时检查。本项为状态机确认，未执行 macOS 长上传复现。

### R07 主线程执行无预算正则匹配

定位：[TrafficConditions.swift 第 171 行](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Model/TrafficConditions.swift:171)。`TrafficStore` 是 `@MainActor`，显示列表经过 `displayedRows → visible → isVisible → matchesConditions`，同步调用 `NSRegularExpression.firstMatch`。保存的着色规则也会执行同类匹配。

合法表达式 `(a+)+$` 匹配连续 `a` 后跟 `!` 时产生大量回溯。本机 ICU 74 夹具中，17 字符约 0.006 秒，21 字符约 0.080 秒，25 字符约 1.565 秒，29 字符超过 3 秒后被父进程终止。表达式长度和正文大小上限无法约束这种复杂度；主线程阻塞期间无法及时清空筛选或发布抓包更新。这是 Linux ICU 量化复现，不是 macOS UI 性能实测。

应提供匹配预算与可中止路径，再将批量筛选移至可取消的不可变快照任务。Apple 的 [NSRegularExpression 文档](https://developer.apple.com/documentation/foundation/nsregularexpression) 说明了回溯性能边界；[reportProgress](https://developer.apple.com/documentation/foundation/nsregularexpression/matchingoptions/reportprogress) 可配合枚举接口处理长匹配中止。仅把任务搬到后台不能终止失控匹配。验收需覆盖回溯输入、取消及重新启动后加载已保存规则。

### R08 退出前未刷新规则保存定时器

定位：[RulesStore.swift 第 405 行](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Model/RulesStore.swift:405)，以及 [ProxyMirrorApp.swift 第 454 行](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/DesktopApplication/ProxyMirrorApp.swift:454)。No Caching 菜单直接赋值后，由 `didSet → scheduleSave` 安排 500ms 定时保存。退出流程等待 Saved 请求写入与网络恢复，但没有刷新待保存的 RulesStore。

停止监听、关闭退出确认，切换 No Caching 后在 500ms 内退出；没有网络状态需要恢复时会直接 `.terminateNow`，最后修改可能丢失。通过 `install()` 立即提交的路径不属于这一问题。

应在正常退出前刷新待保存规则，失败时反馈并阻止退出。验收应覆盖快速退出后重启、写入失败和立即提交路径。本项已确认缺少退出 flush，macOS 时序复现待执行。

### R09 WebSocket drop 字段布尔值反转

定位：[ScriptingService.swift 第 299 行](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Interception/ScriptingService.swift:299)。`interpretFrameValue` 对 `{drop:false}` 返回 `.drop`，而 `{drop:true}` 落到无动作，最终放行。

使用项目实际 worker JavaScript 在 Node VM 运行两种返回值，均原样保留对应布尔字段；反转发生于 Swift 解释层。应匹配 `.bool(true)`，并补充 true、false、缺省、单独返回 false 以及显式 `action` 优先级的回归。现有单独返回 false 的丢帧语义应继续保留。

### R10 根证书旧导入入口缺少校验

定位：[CertificateAuthority.swift 第 132 行](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Proxy/MITM/CertificateAuthority.swift:132)。菜单“导入自定义根证书 PEM 与私钥”经过 `CertInstaller.importRootCA → CertificateAuthority.importRootCA`，仅检查密钥匹配和 CA 基本约束，随后覆盖当前 CA。

过期、尚未生效，或声明 `CA=true` 但 `keyCertSign=false` 的证书，都可能替换正常 CA，使后续 HTTPS 解密失败。`loadOrCreateCA` 对缓存直接返回，磁盘加载也没有这些检查。[CertificateFormats.validate](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/System/CertificateFormats.swift:113) 已实现相应校验，旧入口没有复用。

本轮用内存证书夹具确认过期和禁止签发的 P-256 CA 均满足旧入口现有 guard，未操作真实 CA 或钥匙串。应统一所有导入入口，在替换前验证，并断言导入失败后原 CA 文件和缓存保持有效。

### R11 设备命令无超时和取消

定位：[DeviceAutomation.swift 第 63 行](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/System/DeviceAutomation.swift:63)。`run` 阻塞读完 stdout 后再读取 stderr，没有超时和取消。Android 模拟器安装在 `adb root` 后执行无期限 `wait-for-device`。

模拟器此时退出或无法重新连接时，操作可能永久不返回，界面没有最终反馈；大量 stderr 还可能造成管道互锁。应为该执行器增加截止时间、取消和并发输出读取，可复用项目已有模拟器命令执行机制。验收使用永不退出及写满 stderr 的命令替身，检查失败反馈、子进程退出和再次操作。本项依据确定的阻塞路径，未操作真实设备。

### R12 HEAD 生成的 cURL 缺少无正文模式

定位：[ExportService.swift 第 163 行](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Export/ExportService.swift:163)。HEAD 请求生成 `curl URL -X HEAD`，没有使用 `--head`。`-X` 只改变方法字符串，不改变 cURL 接收正文的行为，见 [cURL 官方文档](https://curl.se/docs/manpage.html#-X)。

本机 HTTP 夹具返回状态 200、`Content-Length: 15`、关闭连接且没有正文：`-X HEAD` 得到 exit 18 和“15 bytes remaining”；使用 `--head` 得到 exit 0。保持连接的服务端还可能使错误命令持续等待。

应对 HEAD 生成 `--head/-I`。验收覆盖 UI、CLI 及 MCP 共用的代码生成路径，并执行真实 HEAD 请求，不能只检查生成文本非空或语法正确。

### R13 Compose 重定向固定原始方法

定位：[ComposeService.swift 第 304 行](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Export/ComposeService.swift:304)。所有请求固定配置 `request = 原方法`，启用跟随重定向时再配置 `location`。cURL 将自定义方法用于后续跳转。

本机夹具中，POST 收到 303 后，当前组合继续发送 POST，正文却被丢弃，最终得到 405；不强制 `-X POST` 时，后续 GET 成功得到 200。该行为影响常见的提交后跳转流程。[RFC 9110 第 15.4.4 节](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.4.4) 描述了 303 的检索请求语义。

应区分常规 GET、POST、HEAD 和自定义方法，明确重定向中的方法与正文转换。验收覆盖 301、302、303、307、308，检查每跳方法和正文，而不仅检查最终状态。

### R14 MessagePack 转换产生非法 JSON

定位：[MessagePackBody.swift 第 158 行](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorFoundation/Inspection/MessagePackBody.swift:158)。`readMap` 直接把任意类型的键编码到 JSON 对象键位置。合法 MessagePack `81 01 a1 78` 表示数值键 1 对应字符串 x，会生成非法 JSON `{1:"x"}`；NaN 或 Infinity 也会经 `formatDouble` 生成非法 JSON 数字。

转换后没有校验输出，`inspect` 仍返回 `decoded: true` 和 `application/json`，随后 JSON 树和 JSONPath/jq 查询失败。[MessagePack 规范](https://github.com/msgpack/msgpack/blob/master/spec.md) 允许这些输入。

应明确非字符串键及非有限浮点数的表示策略；无法转换时保留原始预览并说明原因，只有输出合法后才能声明 JSON。验收补充数值、数组等键和 NaN/Infinity。本项为输入逐分支推导，未执行 Swift 原生解码。

## 工程问题与后续安排

### R15 工具链说明低于依赖要求

[Package.swift 第 1 行](/home/say/work/github/ProxyMirror/Package.swift:1) 声明 tools 5.9，第 27 行精确依赖 `swift-nio-http2 1.38.0`，该版本的[官方 manifest](https://raw.githubusercontent.com/apple/swift-nio-http2/1.38.0/Package.swift) 要求 tools 5.10。[Sparkle 说明](/home/say/work/github/ProxyMirror/ThirdParty/Sparkle.md:3) 仍描述项目为 Swift tools 5.9。Swift 5.9 环境会在解析依赖时失败，即使移除锁文件也无法绕开精确版本要求。

根 manifest 的 5.9 本身合法；问题是对开发环境的说明不准确。应统一真实最低 Swift/CLT 版本，并在该最低版本执行一次依赖解析与构建。

### 修复顺序与维护建议

1. 先修 R01 至 R04，补齐自连接、原始 HTTP 字节流和 MCP 脱敏边界回归。
2. 再修 R05、R06、R08、R09、R10、R12、R13，保证请求语义、正常退出和证书替换行为。
3. 随后处理正则预算、设备进程生命周期、MessagePack 表示和工具链说明。

较长期的维护工作应围绕上述具体边界展开：`ProxyEngine.swift` 当前约 2368 行，可先提取统一 framing 校验与连接策略，避免继续在状态机内增加分支；Core 同时依赖代理和 UI，适合逐步把协议、脱敏和格式转换放入可独立编译测试的模块；正常退出应统一等待规则、Saved 和网络状态的提交与恢复。

测试门槛需要同时保留完整 macOS 构建、SelfTest、HTTP/HTTP2 回环与原生设置窗口检查。当前跨平台夹具已有价值，但本轮发现集中在异常输入、不同入口的一致性、退出和长连接生命周期，后续测试应围绕这些场景补充。

## 本轮验证与覆盖边界

| 已运行检查 | 结果 | 实际证明的范围 |
| --- | --- | --- |
| `python3 Scripts/check_localization.py` | 2173 keys 与 14 张表通过 | 本地化源资源及生成一致性静态检查 |
| `python3 Scripts/test_localization_resources.py` | 15 项通过 | Python 资源检查器及非法资源负例 |
| `python3 Scripts/test_localization_packaging.py` | 19 项通过 | 临时伪应用资源与打包检查器 |
| `python3 Scripts/test_preferences_layout.py` | 10 项通过 | 合成 layout 数据的几何判断 |
| `python3 Scripts/test_updates.py` | 7 项通过 | Python 更新配置及临时 plist 写入 |
| `python3 Scripts/test_app_signature.py` | 3 项通过与 1 项跳过 | mock Security 调用；原生签名用例跳过 |
| `python3 Scripts/test_socks5_parser.py` | 通过 | 实际 C 解析器、分片边界及 5000 个随机输入 |
| `python3 Scripts/test_zstd_decoder.py` | 通过 | 实际 C 解码器、截断、损坏、拼接及窗口上限 |
| `node Scripts/test_scripting_runtime.js` | 23 项通过 | worker 使用的 JavaScript 运行时 |
| `node Scripts/test_script_network_runtime.js` | 通过 | JavaScript 网络 API 与本地 HTTP 夹具 |
| cURL 本地 HTTP 夹具 | 复现 R12 与 R13 | cURL 方法和重定向行为 |
| ICU 回溯夹具 | 复现长时间匹配 | R07 的算法风险，未测 macOS UI |

Python unittest 合计 54 项通过、1 项跳过，另有本地化静态检查通过。测试命令均以仓库根目录为工作目录。

当前主机是 Linux，PATH 中没有 Swift 编译器。未执行完整 macOS 编译、SelfTest、真实 MCP 会话、原生窗口验收、系统代理与钥匙串操作、签名扩展激活或 Sparkle 安装。具体问题中已区分运行夹具结果与源码结论。

审查覆盖代理 HTTP/1 与 HTTP/2、CONNECT、SOCKS5、WebSocket、SSE、限速与捕获，外部代理和透明接入，CA 与系统代理 helper，脚本 worker 与网络桥，CLI/MCP、导入导出及脱敏，规则和 Saved 持久化，AppState/TrafficStore、正文检查与 UI 性能，以及构建、签名、更新和本地化。

核对锁定的 swift-nio-ssl 后，已排除“`serverHostname: nil` 跳过 IP SAN 校验”的疑点：该版本会以 socket peer 校验 IP SAN，项目也拒绝经外部代理执行 TLS IP 目标验证。未复现的连接取消竞态及纯风格建议没有计入 15 项问题。
