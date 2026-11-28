# ProxyMirror 结构性能与多语言补充审查

日期：2026-11-24。对象为当前工作区，包含上一轮 R01 至 R15 的未提交修复。本轮发现编号接续为 R16 至 R29，分为 **8 个具体问题和 6 个结构或验证风险**。用户确认后已继续实施本轮修复，代码保留在当前工作区。

优先处理已发布流量对象的线程归属、自有错误的结构化呈现，以及主线程上的大正文转换和导出。模块拆分应围绕这些具体边界渐进推进。

## 修复实施记录

下文“具体问题”和“结构与验证风险”保留审查时的代码快照、行号及性能基线；当前实现以本节为准。R16 至 R29 均已落实代码修复，跨平台集成与回归完成，原生 macOS 验收边界单独记录。

| 编号 | 当前实现 | 验证方式 |
| --- | --- | --- |
| R16 | [MetadataPublication](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorFoundation/Concurrency/MetadataPublication.swift) 统一发布后元数据更新；H1/H2 使用私有路由值状态 | 真模块发布顺序检查；原生 Combine 订阅及实际协议路径回归 |
| R17 | [MessagePackBody](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorFoundation/Inspection/MessagePackBody.swift) 移入 Foundation，转换按身份/revision/MIME 在可取消后台任务执行，输出上限 1 MiB | 实际解码器的转义扩张、输出预算、执行中取消；保留原始字节 |
| R18 | [JSONFieldCache](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorFoundation/Inspection/JSONFieldCache.swift) 同 revision 共享解析；JSON 自定义列及 GraphQL 内置列仅查缓存，排序后台生成键并拒绝过期结果；解析缓存 16 MiB/256 项、UI 值缓存 8 MiB/4096 项 | 实际模块解析次数、revision、预算、清理和主 actor 响应测试；GraphQL 请求格式、取消及原生列表排序回归 |
| R19 | [AtomicCSVWriter](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorFoundation/Export/AtomicCSVWriter.swift) 使用不可变元数据快照、后台 64 KiB 缓冲及 0600 临时文件，取消后保留原目标；UI 提供进度和结果 | 真实文件、Unicode/引号/换行、跨缓冲块、失败清理、取消及原子替换 |
| R20 | [PreviewProcessRunner](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorFoundation/Process/PreviewProcessRunner.swift) 将取消传到进程组，TERM/KILL 后回收，再释放两个执行槽位；等待槽位可取消 | 实际子进程超时、输出洪泛、两运行任务和等待任务取消、最新请求及 waitpid 回收 |
| R21 | 自有失败保留稳定 code、参数及诊断；Transaction 在 GUI 边界翻译，会话/HAR 保留错误身份；外部诊断保留原文 | 真实 Codable 模型、双语渲染、会话/HAR 和机器诊断回归 |
| R22 | AppState 的 GUI 错误通过 LocalizedErrorPresentation；设备超时/取消/输出超限保留类型化身份 | 两种语言实际错误呈现和诊断稳定性 |
| R23 | 详情、汇总和导出显示共用时间/数字格式；协议、代码与机器导出使用稳定格式 | 毫秒、时区、12/24 小时制及不同地区数字测试 |
| R24 | 新增可独立构建的 ProxyMirrorFoundation；生产 App 改为薄入口和 package API，桌面组合实现在 Core/DesktopApplication；发布打包移除测试可见性依赖 | 真 Foundation target；生产源码无 @testable；独立原生 release 构建门禁 |
| R25 | [RequestRoutePlan](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Proxy/RequestRoutePlan.swift) 供 H1/H2 共用规则顺序、Host、Map、NoCache、DNS 和弱网决策 | 同输入路由决策一致性及既有协议回归 |
| R26 | AppState 注入 engine/CA/provider，服务按需构造；被动实例构造不解析或改写共享引擎，正文回调只更新自身工作区，自建运行时按所有权释放 | 原生隔离设置、实际正文回调、共享服务状态与 socket 生命周期回归 |
| R27 | Foundation 测试直接 import 生产模块，Compose 运输和留存策略移除旧源码提取替身；新增 Linux 与 macOS debug/release/TSan CI | Linux 实际模块测试；原生 CI 配置已加入，须远端运行后确认结果 |
| R28 | 默认校验和打包门禁要求 SwiftGen 6.6.3，真实再生并逐字节比较全部生成物 | 保持资源指纹、篡改 cancel 查询 key 的负例必须失败；缺工具/版本不符必须失败 |
| R29 | 复数校验关联外层参数位置、变量计数和完整类型合同 | 拒绝越界/零索引/错类型；接受合法重排、多复数变量及隐式计数位置 |

进程取消的集成验证还发现并修复 Linux 子进程继承其他线程写文件描述符的竞争：预览 runner 在 dup2 标准流后关闭其余描述符；macOS 使用 CLOEXEC_DEFAULT。修复后实际进程取消用例通过。

交叉复核还收口了正文缓存的编码头/完整性/清理 epoch 身份、任务发布前的当前 key 校验、内存压力下的旧排序取消，以及缓存 key 本身的存储计费。

已完成的性能边界验证（Linux Swift 6.0.3 **debug**，实际生产排序模块）：

| 1000 条记录的冷排序输入 | 后台处理及排序 | 主 actor heartbeat |
| --- | ---: | ---: |
| 每份 122821 字节 JSON | 0.212 秒 | 2.53ms |
| 每份 122769 字节 GraphQL JSON | 0.283 秒 | 3.78ms |

这些数据用于验证工作移出主线程，不能与下文优化编译的旧同步基线直接比较，也不是完整 Mac 界面绘制耗时。缓存回归确认同 revision 多列只解析一次，正文 revision 改变才重新解析；取消的旧排序不发布结果。

最终验证使用 Linux Swift 6.0.3，结果如下。各类测试有重叠，不合并成一个断言总数：

- 正式 Foundation SwiftPM target：**41 项 XCTest，0 失败**；通过快照与最终生产模块、测试及 manifest 的文件哈希一致。
- 正式运输 fixture：**48 项实际 HTTP/cURL 回归**；实际 NIO 连接边界 **14 项**；生产 HTTP 解析与策略 **67 项**。
- 既有可移植套件 **19/19 通过**。错误呈现包含 **104 × 2** 条真实中英文断言；设备执行器 **16 项**，待保存状态 **13 项**，检查器 **37 项**，帧决策 **11 项**。代码生成套件中原有的 12 种语言语法检查仍因缺工具跳过。
- 本地化默认严格门禁：**2269 keys / 14 tables**，真实 SwiftGen 6.6.3 再生结果完全相符；检查器负例 **36 项**、打包资源夹具 **19 项**通过，UI 字面量审计通过（64 项分类记录）。
- **313 个当前源码、测试及 manifest** 的 Swift 语法检查通过并核对最终哈希；另补验图标生成 Swift 脚本。新增 CI 的 shell、Python 和 YAML 检查、生产 API 可见性检查及 `git diff --check` 通过。
- Linux 测试在临时包副本中运行，并显式以该副本为工作目录；真实留存 wrapper 再测 **7/7**，原 macOS `Package.resolved` 与 HEAD 逐字节一致。

完整执行索引位于本机 `/tmp/pm-review-validation-r16-29/final-summary.json`，首轮迁移失败日志也保留用于追溯。此目录是本机验证产物；长期复跑入口见 README 和 [持续集成配置](/home/say/work/github/ProxyMirror/.github/workflows/validation.yml)。

当前主机没有 macOS 原生运行环境。完整 App/Core 类型检查、Combine 集成、真实代理 HTTP/1/HTTP/2/SSE、双语窗口、系统代理/钥匙串、打包签名和 TSan 尚未执行；新增 macOS debug/release/TSan CI 配置也尚未远端运行。Linux 测试及语法检查不能代替这些原生验收。

## 具体问题

### R16 已发布流量对象仍存在跨线程修改

优先级 P2。依据为已确认的线程调用路径，尚未用 macOS TSan 证明具体数据竞争或崩溃。

[Transaction.swift](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Model/Transaction.swift:154) 同时作为引擎记录与 ObservableObject。正文、帧使用锁，而状态、头部及其他 `@Published` 元数据没有 actor 隔离。

在 `finishConnect → publish → ClientHello/SNI 决策 → rejectTunnelIfNeeded(published:true)` 路径中，[ProxyEngine.swift](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Proxy/ProxyEngine.swift:1348) 在 NIO 线程直接修改已经交给 UI 的记录。后面的 `onMain` 只包住通知，没有包住这些修改。透明连接在 SNI 决策后按规则拒绝时可进入这一分支。H2 本地响应路径也存在同类元数据写入。

短期应统一已发布元数据的主线程更新。中期应拆分引擎私有状态、可发送的不可变快照和 `@MainActor` 展示模型，保留正文预算及必要锁。验收需要覆盖 SNI 后拒绝、本地响应、录制与 UI 同时读取，并运行 TSan。

### R17 MessagePack 检查在界面求值中重复同步执行

优先级 P2。上一轮解决了输出 JSON 的正确性，这里是执行位置和重复计算问题。

[DetailView.swift](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/UI/Detail/DetailView.swift:230) 的 `inspectedBody` 是无缓存计算属性。`data`、`isJSON`、`messagePackApplied`、树可用性及传给正文视图的 MIME 都会再次触发转换。转换位于 View 求值路径，后续文本高亮的后台任务无法避免此前的同步工作。

优化编译当前生产解码器，Linux Swift 6.0.3 单次转换测量如下：

| MessagePack 字符串输入 | 耗时 |
| --- | ---: |
| 256 KiB 普通字符 | 13.5 ms |
| 1 MiB 普通字符 | 39.5 ms |
| 256 KiB 需要 JSON 转义的控制字符 | 355.4 ms |
| 1 MiB 需要 JSON 转义的控制字符 | 1195.3 ms |

最后一个夹具输出为 6 MiB。现有 8 MiB 输入限制没有约束转换后的输出量，一次界面更新又可能多次求值。

应按 transaction、revision、content-type 和解码输入身份缓存一次结果，在可取消后台任务中统一转换，并为输出设置预算。验收需覆盖切换记录、搜索、正文更新及内存压力后的重建。

### R18 JSON 自定义列的冷排序同步解析全部正文

优先级 P2。

调用链为 `TrafficListView.body → TrafficStore.displayedRows → TrafficColumn.sorted → CustomTrafficColumn.value → jsonValue`。[CustomTrafficColumn.value](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Model/CustomTrafficColumn.swift:43) 明确在 MainActor 上执行，每个未缓存字段通过 [JSONSerialization](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Model/CustomTrafficColumn.swift:85) 解析整份正文。

原样提取生产字段解析方法并以 `-O` 编译，每份 JSON 122825 字节，得到：

| 冷解析记录数 | 仅字段提取耗时 |
| --- | ---: |
| 100 | 20.6 ms |
| 1000 | 196.2 ms |
| 5000 | 1115.2 ms |

这些数据尚未包含排序、解压及绘制。1000 份正文约 117 MiB，可作为当前 256 MiB 实时捕获预算内的代表场景；5000 份约 586 MiB 是算法压力夹具，不能视为默认实时记录能同时保留的完整正文量。

应后台生成不可变排序键，同一 revision 共享一次 JSON 解析结果。字段缓存还只有每条每方向 16 个值的限制，没有总字节预算；它没有接入现有内存压力清理，应一并收口。

### R19 CSV 导出在主线程完整格式化并同步写文件

优先级 P2。

[ExportService.exportCSV](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Export/ExportService.swift:131) 在保存对话框返回后直接调用 `writeCSV`。该方法建立全部行数组，拼接完整文件字符串，再原子写入。

原样提取生产写出方法并以 `-O` 编译，每行 URL 约 1 KiB：

| 记录数 | CSV 大小 | 格式化及写入耗时 |
| --- | ---: | ---: |
| 5000 | 5.45 MB | 267.5 ms |
| 50000 | 54.45 MB | 3838.5 ms |

50000 是设置允许的记录上限。同步路径会阻塞其他 UI 工作，同时保留行数组和完整输出也增加瞬时内存。

应先取得不可变导出快照，再后台分批写入临时文件，完成后原子替换目标，提供取消、完成及失败反馈。

### R20 自定义预览取消未传播到 worker

优先级 P2。

[CustomPreviewerResultView](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/UI/Detail/CustomPreviewers.swift:150) 启动 detached task，等待结果后仅检查外层任务是否取消；取消没有传给 detached task 或它创建的进程。`PreviewerWorker` 又只有两个全局执行槽位。

使用生产 PreviewerWorker 和同目录的模拟 worker 复现：两个预览启动后取消，第三个立即得到 busy；两个旧任务继续约 1.1983 秒后正常返回。槽位释放后，当前预览没有自动重试，快速切换三条记录可使当前记录停留在 busy 提示。

这里测量的是实际进程包装器的取消行为，模拟 worker 的执行时间不代表内置 JavaScript 的运行耗时。现有两秒超时不能替代取消传播。应把取消传到进程并回收后释放槽位，当前请求采用可取消等待或只保留最新预览的队列。

### R21 自有网络错误直接写成界面字符串并持久化

优先级 P2。

[ProxyEngine.swift](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Proxy/ProxyEngine.swift:1637) 使用中文自有错误，经 `finishRequestWithFailure → tx.errorText` 到 [DetailView](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/UI/Detail/DetailView.swift:301) 直接显示，英文界面仍会看到中文。反向情况是 Compose 的英文 `Request timed out` 等错误进入 `tx.errorText`，再由 [ToolWindows](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/UI/Tools/ToolWindows.swift:139) 直接显示。

该字符串还会进入会话与 HAR，重新打开文件后也没有错误身份可供按界面语言重渲染。

应为自有失败保存稳定错误码、参数及技术诊断，GUI 在显示边界生成译文。系统、curl 和用户脚本的原始诊断保留原文，CLI 和导出继续使用稳定诊断，避免把机器接口变成界面文案。

### R22 已有类型化错误的 GUI 路径仍绕过译文

优先级 P2。

[AppState.swift](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/App/AppState.swift:288) 在透明代理启动、停止失败时直接取 `error.localizedDescription`。而该错误类型有意使 `errorDescription` 返回稳定英文诊断，真正译文应通过 `LocalizedErrorPresentation` 获取。

真实生产错误模块的小夹具验证：简中下直接读取诊断是英文，正确渲染得到“此应用包缺少透明代理系统扩展，请使用带扩展的签名版本。”

上一轮新增设备执行器的自有失败也还有相同边界：[DeviceAutomation.swift](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/System/DeviceAutomation.swift:60) 先把已知失败转换成英文字符串再包装，实测显示“命令执行失败：The device command exceeded its time limit.”。

应统一所有 GUI 错误出口，并为设备超时、取消、输出超限保留类型化错误身份，映射到对应的 OperationIssue。此处是已有翻译未被正确使用，不应靠继续补字符串 key 解决。

### R23 抓包时间和数值格式没有统一遵循显示偏好

优先级 P3。

[DetailView.swift](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/UI/Detail/DetailView.swift:530) 直接调用 `Date.formatted()` 展示连接和响应头时间，绕过统一的 PresentationTime。实际 Foundation 夹具中，相差 456ms 的两个时间在默认格式下都只显示到同一分钟，统一格式器则能区分 `.123` 和 `.579` 并显示时区。

同文件的 [connectionDuration](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/UI/Detail/DetailView.swift:551) 等位置还使用没有指定 locale 的 `String(format:)`。在 de_DE 地区夹具下，这与显式地区数字格式不同。

应统一自有时间、时长及展示数值格式器，同时维持协议、代码和 HAR 的稳定机器格式。本项不把正常的系统地区差异或系统拥有的面板语言当成应用缺陷。

## 结构与验证风险

### R24 生产模块边界依赖测试可见性

[Package.swift](/home/say/work/github/ProxyMirror/Package.swift:30) 把代理、模型、系统集成和 SwiftUI UI 放进同一 Core。生产 App 的八个文件使用 `@testable import ProxyMirrorCore`，[打包脚本](/home/say/work/github/ProxyMirror/Scripts/make_app.sh:152) 为此给 release 添加 `-enable-testing`。

现有打包脚本明确处理了这种布局，不能据此断言发布构建失败；问题是生产 API 和模块职责尚未形成清晰边界。应先定义 package 级应用入口与服务接口，替换生产代码对 `@testable` 的依赖，再逐步拆分可移植模型、协议和桌面 UI。

### R25 H1 与 H2 重复实现业务决策

[H1 路由](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Proxy/ProxyEngine.swift:809) 与 [H2 路由](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/Proxy/HTTP2ProxyStream.swift:206) 分别实现 Block/Allow、Map Local、Map Remote、No Caching、DNS、弱网和发布顺序。上一轮 R05 就是 H1 与 H2 的 Host 处理已经分叉。

应提取共同的请求元数据、规则求值和 RoutePlan，保留不同协议的连接与流状态机。以同一组规则输入对 H1/H2 做结果一致性检查，比按文件行数机械拆分类更有价值。

### R26 依赖注入仍被全局单例副作用穿透

[AppState.init](/home/say/work/github/ProxyMirror/Sources/ProxyMirrorCore/App/AppState.swift:89) 即使收到隔离 settings、`launchServices:false`，仍在服务启动 guard 前修改全局引擎的 sink、录制和 TLS 设置，并安装全局证书 provider。现有 SettingsRuntimeChecks 因此必须独占共享引擎、逐项备份恢复状态。

应由应用组合入口提供 engine、规则和证书服务实例，测试和预览使用独立实例。生产默认仍可使用单例，但构造测试状态不应影响另一实例。这是隔离与可维护性风险，未将其等同于已发生的生产用户数据损坏。

### R27 可移植测试存在手工源码提取和替身边界

[Compose 夹具](/home/say/work/github/ProxyMirror/Scripts/test_compose_transport.py:198) 提取生产方法并替换平台相关 Engine、CA、Transaction；[留存模型夹具](/home/say/work/github/ProxyMirror/Scripts/test_system_retention_models.py:12) 按字符括号扫描声明，并替换 Published。

这些测试能验证真实算法及网络行为，但不能证明 Combine、actor、App/Core 访问控制或完整依赖图正确。应把已经可移植的生产逻辑逐步移入可直接依赖的 SwiftPM target，减少源码提取；macOS 仍需完整 debug/release 构建、SelfTest、TSan 和 UI 验收。

### R28 生成访问器校验只检查资源指纹

优先级 P3，为已复现的门禁缺口，不表示当前生成接口已经错误。

[check_localization.py](/home/say/work/github/ProxyMirror/Scripts/check_localization.py:246) 只确认 Strings.swift 包含资源指纹头。仅在临时副本将 `Strings.Common.cancel` 的查询 key 改成 `delete`、保留指纹，完整 checker 仍输出 2173 keys / 14 tables 通过。

此外，直接 UI 字面量审计无法覆盖 `Text(variable)` 的上游错误来源，因此发现不了 R21、R22。应在发布门禁执行真实 SwiftGen 再生比较，并补自有失败到界面呈现的双语测试。

### R29 复数检查器丢失参数位置约束

优先级 P3，为门禁缺口；当前资源没有发现该越界内容。

[check_localization.py](/home/say/work/github/ProxyMirror/Scripts/check_localization.py:102) 对分支调用 `signature(..., allow_sparse=True)`，随后仅比较类型。临时 stringsdict 将 one/other 改为 `%99$ld request(s)` 后，生产 `load_plurals` 仍接受。

应保留参数位置并与外层复数变量及调用参数关联校验，拒绝超出接口可提供参数的分支。仅比较 Int/String 类型不足以证明格式安全。

## 建议顺序与证据边界

1. 先收口 R16 的线程所有权和 R21、R22 的错误身份与显示边界，防止后续代码继续复制错误模式。
2. 处理 R17 至 R20，把正文派生数据、排序键、导出和 worker 生命周期纳入统一的预算、取消和缓存策略。
3. 统一时间数值格式，补齐生成与复数门禁；随后渐进拆分模块、共同规则决策和测试依赖。

性能测量使用 Linux Swift 6.0.3 的优化编译，部分方法从生产代码原样提取；预览取消使用实际进程包装器和模拟 worker。它们证明同步工作量与取消行为，不代表 macOS 上完全相同的耗时。本轮没有运行 Mac UI profiling、完整应用构建或 TSan。

本地化错误与检查器负例使用真实生产模块或检查函数，修改仅限临时夹具。没有把仅支持 en/zh-Hans、切换下次启动生效、旧中文存储不兼容或英文自称中的中文名称计为问题。
