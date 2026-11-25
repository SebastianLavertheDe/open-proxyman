# gzip 与 Tars/JCE 正文显示修复

日期：2026-11-24。修复基于 `d752a498af75d5ee4da9801b5f61b6707938c088`。

## 截图能够确认什么

请求和响应均以 `1f 8b 08` 开头，是 gzip 容器。右侧响应的全部 58 字节可从截图还原，实际 gzip 解压及校验通过，输出 38 字节。解压后的字段按 [Tars/JCE 协议](https://tarscloud.github.io/TarsDocs/base/tars-protocol.html) 可完整解析：

| 标签编号 | 编码类型 | 实际内容 |
| --- | --- | --- |
| 0 | int16 | 200 |
| 1 | string | IPv4 地址字符串 |
| 2 | int64 | 1795517728300 |
| 3 | string | success |

这是压缩后的二进制序列化数据。更换 UTF-8/GBK 字符集或仅识别 JSON 都不能使其直接成为正常正文。没有协议定义时，不将上述标签擅自命名为业务字段。

截图没有显示请求/响应头，也不能证明当前 Mac 应用的构建版本。因此，不能仅凭截图断言该记录一定缺少 Content-Encoding。可以独立确认的是：此前代码只按该头进入解压流程，未声明编码的相同 gzip 样本会直接进入 Hex；现有应用载荷转换只支持 MessagePack，没有 Tars/JCE。截图左侧请求仅确认 gzip 特征，尚未取得其原始正文来验证内部字段。

## 实现

- `ContentCoding.inspectionEncodings` 对正文检查增加 gzip 特征识别。显式声明的编码和编码顺序优先，不猜测无头 raw-deflate，也不修改严格 HTTP 解码器的默认行为。
- `HTTPBodyInspection` 统一正文、预览及解码后原文的应用载荷转换。沿用 MessagePack 支持，增加 Tars/JCE，并把成功结果作为 JSON 交给文本、高亮、树和查询。
- Tars/JCE 支持数值、字符串、struct、map、list、字节数组和扩展标签。Map 保留键值对，无法按 UTF-8 解读的字节使用 base64，字段名保留标签编号。
- 无格式标记的自动识别仅针对解压后的通用二进制 MIME；要求完整消费输入、字段有序且不重复、至少三个顶层字段，并包含数字与可读字符串。显式 JSON、文本、图片和 Protobuf 不参与该自动识别。
- gzip 解压继续遵守 32 MiB 上限。Tars/JCE 限制输入 8 MiB、JSON 输出 1 MiB、嵌套 64 层、元素 100000，并检查取消。捕获不完整或截断时不声称完整解码；损坏或不支持的内容保留二进制回退。
- 原始头部和捕获正文不被重写。原文的“捕获字节”可以查看原始 gzip；重放与导出继续使用捕获数据。
- 新增提示采用中英资源和生成访问器，gzip 自动识别与 Tars/JCE 转换在界面中有对应说明。

## 复现与验证

截图响应作为完整 gzip 夹具保留在 `Scripts/test_body_inspection.py`，不需要联网访问截图中的服务：

```sh
python3 Scripts/test_body_inspection.py
```

该脚本使用实际生产 Foundation、ContentCoding 和 zlib；未使用的 macOS Brotli/Zstd 适配会在误调用时立即失败。夹具检查缺失/显式编码、gzip 校验、损坏/截断/输出预算、JCE 标签与值、JSON 保持及真正二进制回退。它不代替原生 SwiftUI/AppKit 运行。

`TarsBodyTests` 直接导入生产 Foundation，覆盖截图响应、格式识别、数值类型、复合集合、非法计数/标签、深度、输出预算、字节预算和取消。`DetailInspectionChecks` 补充实际 BodyContentView 的 JSON/Hex 判定回归。CI 已接入新夹具；本轮远端 CI 和 Mac 原生界面尚未运行。

最终本地验证：

- 当前实际 Foundation/C 模块 **77/77 XCTest 通过**，其中新增 Tars/JCE **9 项**；临时源码快照与工作区一致。
- 截图 gzip/JCE 及输入识别、损坏和回退 **22 项实际检查通过**，使用真实生产模块、ContentCoding 和 zlib。
- 本轮 **8 个 Swift 文件语法检查通过**；真实 SwiftGen 输出与已生成接口一致，中英 **2290 个 key、14 张表**检查通过。Python/shell 语法和 `git diff --check` 通过，Mac 依赖锁未改变。
- SwiftUI/AppKit 类型检查及界面尚未在本机运行；新增原生回归和远端 CI 仍需 Mac 验证。

本机证据保存在 `/tmp/pm-gzip-tars-validation/`。早期在高负载下出现过正则时限、异步 CSV 等待及编译/生成超时，原始失败日志保留；最终完整通过日志为 `foundation-complete.log`、`localization-complete.log`，独立重编完整生产模块的实际解码日志为 `body-inspection-complete.log`。没有修改已有测试或产品的时限来取得最终结果。

Mac 上需要重新构建并启动新应用，源码改动不会自动更新截图中的进程。当前 Linux 环境没有验证或替换该 Mac 进程。
