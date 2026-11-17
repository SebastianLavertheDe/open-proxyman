# UI-SPEC — Proxyman 实测样式/布局/交互规范（证据提取自 Proxyman 26.10 包内容）

> 证据来源：NibArchive 解析（MainMenu.nib / StatusBarView.nib / ContentView.nib）、
> Assets.car（assetutil 全量色值）、ProxymanCore 二进制符号、strings 文案。
> 本规范只记录事实参数，实现全部原创。

## 1. 颜色（Assets.car 实测，Light / Dark）

| Token | Light | Dark | 用途 |
|---|---|---|---|
| status_code_200 | #34C759 | #5AB45B | 2xx 状态圆点/文字 |
| status_redirect | #FFCC00 | #FFB400 | 3xx（黄色！） |
| raw-content-http-color | #4CD137 | — | HTTP 动词（GET 绿） |
| method-box-background | #E6E5E6 | #3A3B3E | 方法徽章背景 |
| method-box-title | #737373 | #D9D9D9 | 方法徽章文字 |
| raw-content-key-color = treeview-key-color | #1565C0 | #86BFA3 | JSON key |
| raw-content-value-color = treeview-string-color | #C13D2A | #FF8170 | JSON 字符串 |
| treeview-number-color | #AA78D0 | #A89CF7 | JSON 数字 |
| treeview-bool-color | #FE9926 | #F174A8 | JSON bool/null |
| raw-content-fullurl-color | #990055 | #A89CF7 | Raw 视图完整 URL |
| flow-content-background-color | #ECECEC | #2E2F31 | 详情内容区背景 |
| flow-content-top-bar-background | #F7F5F7 | #202122 | 详情顶栏背景 |
| pretty-text-view-background-color | #FFFFFF | #292A2F | Pretty 正文背景 |
| guideline-background-color | #F4F5F5 | #3B3B3B | 分组背景 |
| status-inline-button-color | #666666 | #C4C6C9 | 底部状态栏文字 |

方法色（GET=绿见上；其余按系统色板惯例）：POST #007AFF、PUT #FF9500、DELETE #FF3B30、PATCH #AF52DE。

## 2. 字体

- 列表/状态栏单元格：系统字体 **11pt**（nib NSFont NSSize=11.0 实测）
- Raw/Pretty 正文：等宽 11pt
- 侧栏：系统 12-13pt；详情键值 12pt

## 3. 菜单结构（MainMenu.nib 实测，仅列可实现/已实现项）

- **File**: New Session ⌘T / Open… ⌘O / Save Session… / Close ⌘W
- **Edit**: Undo ⌘Z … Copy ⌘C / **Copy as cURL ⇧⌘C** / Paste ⌘V / Delete ⌫ / Select All ⌘A / Find ⌘F
- **View**: Filter Domain or App ⇧⌘F / Filter Current View ⌘F / **Auto Select the Latest Request ⇧⌘L** /
  Toggle Source List Panel / Toggle Split View / Toggle Dock to Bottom / Detach Content Windows
- **Flow**（流量右键同名交互）: Repeat / Edit and Repeat… / Enable SSL Proxying for This Domain /
  Save Requests / Export ▸ (HAR / CSV) / **Add Comment… ⌘L** / **Highlight ▸ (Red ⌘1, Yellow ⌘2, Green ⌘3,
  Blue ⌘4, Purple ⌘5, Gray ⌘6, Strikethrough ⌘/, Reset ⌘0)** / Clear Session ⇧⌥⌘K / Delete / Delete All
- **Tools**: **Toggle Recording ⌘R** / SSL Proxying List… ⇧⌘P / Compose Request… ⇧⌘C / Map Local… ⌥⌘L /
  Map Remote… ⌥⌘R / Network Conditions… ⌥⌘J / Proxy Settings ▸ Override macOS Proxy ⌥⌘O
- Preferences… ⌘,

## 4. 列表（列名来自 ProxymanCore 符号：Result/Method/Scheme/Size/Time/Duration/comment…）

列序：Method | Result | URL | Scheme | Size | Time | Content Type | Start Time
- 方法徽章：小底色块（method-box-background）+ 11pt 半粗
- Result：状态圆点 + 数字；未完成=spinner；失败=红叉
- 隧道行：🔒 + domain（未解密时）；已解密不显示隧道行
- 行高亮：Highlight 六色 → 行背景 tint；Strikethrough → URL 删除线
- Comment：黄色 note 图标

## 5. 详情

- 顶栏（flow-content-top-bar 背景）：‹ › 导航 + 居中 Overview|Request|Response 分段 + 右侧 Repeat/更多
- 内容区（flow-content-background）：Overview 键值表 / Request-Response 左栏(Headers|Body|Query|Raw) + Pretty|Raw 切换 + 复制
- Pretty JSON 背景 pretty-text-view-background，高亮色见 §1

## 6. 底部状态栏（StatusBarView.nib: NSStackView + 11pt）

左：⏺ Recording/Stopped + "N Requests"；右：Proxy 地址 127.0.0.1:9090 + 自动滚动钮

## 7. 交互

- 双击行 → 独立窗口（SeparateWindowController 对应实现）
- 右键行 → Flow 菜单同款动作
- ↑↓ 选中导航；⌘K 清空？→ 实测 **⌘K = New Domain or App**，Clear Session = ⇧⌥⌘K（遵循实测）
- ⌘F 过滤当前视图；⌘R Toggle Recording；⌘L Add Comment；⇧⌘L 自动选中最新；⌘1-6 高亮
