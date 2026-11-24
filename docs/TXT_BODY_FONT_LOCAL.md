# TXT 正文字体与共用书页预览（本地候选）

基线：0.2.31 build 33，产品 `d5ad348`、冻结 `31e70e3`。未升版，不改变 CI、打包或发布资格。

- 设置页的「书页预览」是固定的非私人样文。所选字体来自字体库的校验字节，不向系统注册字体。字体没有覆盖的字符仍由平台补字；预览不是书页截图。EPUB 原始排版保留作者版式，示意页不声称复刻作者 CSS 或嵌入字体。
- TXT 和 EPUB 共享同一导入、删除和容量规则，各书单独选择。TXT 默认仍是原有的 PingFang；选择代号和字体字节都不写入进度数据库。删除库副本会让匹配的书回退，重新导入相同文件不会复活旧选择。
- TXT 窗口生成时以所选字体计算 CoreText 断行和行高，把同一张字体快照交给画布。书签跳转、搜索命中和返回也经过该接口。换字只重排，沿用书籍/版本、原始字节位置与行内比例，在新行中定位对应 UTF-16 字符，不保存新页码或拿新行首替代旧位置。

## 验收范围

本机已核对原创 TTF 的 Host 夹具与确定性生成器字节一致；FreeType 在 20 单位字号量得 `A` 进宽 50、墨迹包围盒 `(2, 0, 48, 14)`。这是夹具证据，不是 SwiftUI/CoreText 的运行结果。

新增 `TXTBodyFontHostTests` 三项，供有 Apple 工具链时定向执行：

| 用例 | 判据 |
|---|---|
| `sharedPageSpecimenRendersTheSelectedFaceAtDraftSize` | 用 SwiftUI 渲染样张文字；宽字形 `AAAA` 在 20/24 号下宽约 200/240，还原后回到默认宽度。 |
| `bodyCanvasPaintsTheWideAAndRestoresItsDefaultInk` | 在同一画布和同一单字行上比较实际墨迹边缘，宽字形与默认有差别，还原与原值相同。 |
| `reflowAndReopenKeepScrolledTextWithSelectedAndRestoredFont` | 带 BOM、多字节前缀、非零滚动位置的合成 TXT：断行发生变化，目标字仍可见；带自定义字体及还原后分别用新服务、模型和字体库实例重开，比较完整锚点和 UTF-16 位置。 |

Windows 本地没有 Xcode，未编译 iOS App、未执行上述 Host 用例，也未做系统 Files 点选、VoiceOver 或真机验收。本轮不推送、不触发 Actions、不生成 IPA。
