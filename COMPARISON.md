# Proxyman vs ProxyMirror — 样式/布局/交互比对报告

> 比对方法：Proxyman 侧取值来自包内容实测（NibArchive 解析 / assetutil 色板 /
> ProxymanCore 符号 / strings），ProxyMirror 侧取自实现源码与运行时离屏快照。
> 说明：本机终端宿主无屏幕录制权限，无法截取 Proxyman 运行窗口做像素级 diff，
> 因此比对以「包内容提取的事实参数」为基准逐项核对。

## 1. 颜色（实测 vs 实现）

| 项 | Proxyman 实测 | ProxyMirror | 状态 |
|---|---|---|---|
| 2xx 状态 | #34C759 / 暗色 #5AB45B | 同（ProxymanTheme.status2xx） | ✅ |
| 3xx 状态 | #FFCC00 / #FFB400（黄） | 同 | ✅ |
| 4xx / 5xx | 系统橙 / 红 | 同 | ✅ |
| GET 动词 | #4CD137 | 同 | ✅ |
| 方法徽章底 | #E6E5E6 / #3A3B3E | 同（圆角 4pt 块） | ✅ |
| JSON key | #1565C0 / #86BFA3 | 同 | ✅ |
| JSON 字符串 | #C13D2A / #FF8170 | 同 | ✅ |
| JSON 数字 | #AA78D0 / #A89CF7 | 同 | ✅ |
| JSON bool/null | #FE9926 / #F174A8 | 同 | ✅ |
| 详情内容区背景 | #ECECEC / #2E2F31 | 同 | ✅ |
| 详情顶栏背景 | #F7F5F7 / #202122 | 同 | ✅ |
| Pretty 正文背景 | #FFFFFF / #292A2F | 同 | ✅ |
| 状态栏文字 | #666666 / #C4C6C9 | 同 | ✅ |

## 2. 字号/间距

| 项 | Proxyman 实测 | ProxyMirror | 状态 |
|---|---|---|---|
| 列表/状态栏字体 | 系统 11pt（nib NSFont Size=11.0） | 11pt | ✅ |
| Raw/Pretty 正文 | 等宽 11pt | 11pt monospaced | ✅ |
| 行高 | 紧凑行（≈26pt） | 26pt | ✅ |
| 列表列序 | Method/Result/URL/Scheme/Size/Time/Content Type/Start Time | 同 | ✅ |

## 3. 菜单结构与快捷键（MainMenu.nib 实测 vs 实现）

| 菜单 | Proxyman | ProxyMirror | 状态 |
|---|---|---|---|
| File ▸ Open ⌘O / Save Session / Close ⌘W | ✓ | Save Session(=导出 HAR)、Open(HAR) | ✅ |
| Edit ▸ Copy as cURL ⇧⌘C | ✓ | ✅ | ✅ |
| View ▸ Filter ⌘F / ⇧⌘F、Auto Select Latest ⇧⌘L、Show Source List Panel | ✓ | ✅ | ✅ |
| View ▸ Show Command Palette ⌘P / Toggle Split View / Dock to Right | ✓ | 灰态占位 | ✅（灰态） |
| **Flow** ▸ Repeat / Edit and Repeat ⇧⌘R / Enable SSL Proxying / Save Requests ⇧⌘S / Export ▸(HAR/CSV) / Add Comment ⌘L / Highlight ▸(⌘1-6/⌘/⌘0) / Clear Session ⇧⌥⌘K / Delete / Delete All | ✓ | 全部 ✅（Highlight 六色行标记、Strikethrough、Comment 弹窗均为真实功能） | ✅ |
| **Tools** ▸ Toggle Recording ⌘R / SSL Proxying List… ⇧⌘P / Compose Request… ⇧⌘C / Map Local… ⌥⌘L / Map Remote… ⌥⌘R / Block List… ⌥⌘[ / Allow List… ⌥⌘] / No Caching ⌥⌘N / Protobuf / Network Conditions / TLS Key Logging / Customize Columns/Toolbar / Proxy Settings ▸ Override macOS Proxy ⌥⌘O | ✓ | Toggle Recording ✅、SSL Proxying List ✅（真实规则页）、Compose ✅（真实编辑器）、Map Local/Remote ✅（真实规则页+引擎生效）、Block/Allow ✅（引擎生效）、No Caching ✅（引擎剥头）、Proxy Settings ▸ Override ✅；Protobuf/Network Conditions/TLS Key Logging/Customize 系列 = 灰态 | ✅ |
| Preferences… ⌘, | ✓ | ✅（General/SSL/Advanced） | ✅ |

## 4. 交互行为

| 交互 | Proxyman | ProxyMirror | 状态 |
|---|---|---|---|
| 双击请求 → 独立窗口 | ✓ | ✅ | ✅ |
| 右键行 → Flow 同款动作 | ✓ | ✅ | ✅ |
| 行 Highlight 六色 + 删除线 + 注释 | ✓ | ✅（真实存储+渲染） | ✅ |
| Map Local 命中 → 本地文件应答（不连上游） | ✓ | ✅（e2e 实测：返回本地文件内容） | ✅ |
| Block List → 403 | ✓ | ✅（e2e 实测：403 文案） | ✅ |
| SSL Proxying List 非空 → 仅解密命中主机 | ✓ | ✅（引擎接入） | ✅ |
| No Caching → 剥条件请求头/缓存响应头 | ✓ | ✅（引擎接入） | ✅ |
| Compose Request 直连执行 | ✓ | ✅（解析+URLSession 执行+结果入列表） | ✅ |
| ↑↓ 选中 / ⌘F 过滤 / ⌘R 录制 | ✓ | ✅ | ✅ |

## 5. 已知残留差异

- 分割线/边距为 SwiftUI 默认值（±2pt 级别），未逐像素调
- Proxyman 的 Monaco 编辑器、Chart 视图、进程归因气泡（App 端已实现归因引擎）、
  WebSocket 帧树（帧解析已实现，UI 树状视图未做）为独立大件
- 快照注记：离屏 PDF 渲染会把 material 背景画成深色，真实窗口为正确主题色
