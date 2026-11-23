# 本地化访问器生成

翻译的唯一维护源是 `Sources/ProxyMirrorCore/Resources` 下的原生字符串表。使用固定的 SwiftGen 6.6.3（上游 tag 对应提交 `f7c23b63053e5a8aab4a4dbb633b24920bbb9436`）：

```sh
Scripts/generate_localization.sh
Scripts/generate_localization.sh --check
python3 Scripts/check_localization.py
```

可以通过 `SWIFTGEN_BIN` 指定固定版本的可执行文件。普通 App 构建直接使用已经提交的生成代码，无需安装生成器。

`localization-swift5.stencil` 把 SwiftGen 解析出的表、稳定 key 和参数类型转换为 `Strings.Table.member`。查询与格式化全部委托给本次启动冻结的 `LocalizationContext`。表名构成 Swift 命名空间；key 限制为 lower_snake_case，生成的成员为 lowerCamelCase。

`EnglishFallbacks.swift` 由资源检查器从同一套英文表自动生成。它提供资源损坏或单项缺译时的可读英文兜底。SwiftGen 对 stringsdict 条目的 translation 是格式描述，不能作为用户文案；因此所有复数条目同时保留 strings 中的可读英文 fallback，两者由检查器验证签名一致。

脚本先将英文 strings 规范化成等价的临时 XML plist，再交给 SwiftGen 官方字符串解析器。这是构建输入转换，不是第二套翻译来源；它也避免了 Linux Foundation 不支持 OpenStep PropertyListDecoder 的限制。模板不依赖转换时消失的文件注释；译者上下文仍保存在原生资源中。最终 App 携带原生源资源，临时 XML 输入不会发布。

资源中的字面百分号统一写成 `%%`，避免生成器把英文中的 `% Loss` 等误认成格式参数。无参数展示仅反转义 `%%`；带参数展示才使用 Foundation 格式化。

完整检查包括资源同构、占位符与复数规则、生成指纹、类型化成员引用、遗留中文 key 调用、两类延迟错误工厂，以及 UI 文案分类审计。语法与静态审计不能代替 macOS 上的原生复数、签名产物和界面验收。
