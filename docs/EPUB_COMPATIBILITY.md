# EPUB 兼容修复与定向验证

目标版本：0.2.2 / build 4；iOS 16.6，固定 Xcode16.4/16F6、Swift6.1.2（语言6、完整并发）、XcodeGen2.46.0。GRDB7.0.0、ZIPFoundation0.9.19不变。

## 产品边界

- 删除精确白名单的 HTML、XHTML1.0/1.1、NCX2005标准DOCTYPE声明，再交严格XMLParser解析；不解析/下载DTD，不扩展实体。内部子集、未知/重复/错位声明、XXE继续拒绝。
- SVG只支持一个本地栅格image组成的静态包装，严格验证命名空间和属性并转换为div/img，不把SVG交给WebKit。复杂图形、脚本、事件、动画、外链继续拒绝。
- WebP只接受有界静态单帧：RIFF/WEBP结构、精确大小、块边界、VP8X画布、单图像块、ImageIO解码一致性；上限16MiB/单边16384/40M像素。正文图片损坏致命，独立可选封面无效则回退且不发布非法资源。
- 先前拒绝的图片页生成“图片页”及稳定yj-t0文本锚点；既有有效文本页的输出、节点顺序和定位单位不变。不修改parserVersion、数据库、TXT、书签或会话epoch。
- 本批只兼容PNG/JPEG互相误标：完整数据在16MiB/单边16384/40M像素内，通过ImageIO真实类型、单帧、完整状态与实际解码后，才记录真实MIME。原始字节/路径/摘要不变，持久化与重开资源响应使用确认后的MIME。不按扩展名猜测，不将损坏、SVG或WebP错标纳入纠正。
- 仍不支持通用SVG、固定版式、DRM、音视频、网络书源、EPUB书签/标注。

## 影响范围与用例

上一批新增8个Domain兼容用例与1个WebKit Host用例；本批扩充既有Package正反例与Host图片页用例，身份与数量不变。覆盖双向MIME纠正、持久化/重开、正文封面、资源篡改、伪造/截断/多帧/超限拒绝，以及WebKit真实加载与位置恢复。原有断言保留；所有公开夹具是合成材料，不包含用户原书、书名或内容。

`validation_scope=epub-compat-33` 使用独立互斥作业：

| Suite | 执行数 | 依据 |
|---|---:|---|
| EPUBPackageTests | 8 | XML/目录/正文资源/封面解析 |
| EPUBLibraryTests | 8 | 导入发布、持久化、清理、隔离 |
| EPUBProgressTests | 4 | 新图片页锚点与旧UTF16/版本/会话保存规则 |
| EPUBCompatibilityTests | 8 | 声明、SVG、WebP、图片页正反例与重开/篡改 |
| EPUBReaderHostTests | 5 | WebKit资源、安全、排版、封面和图片页实际加载/恢复 |
| 合计 | 33 | Domain28 + Host5 |

完整测试清单214只用于身份防漂移，并不意味着本轮执行214。TXTCore/Block/测量、TXT UI/书签、Canvas、未改动ZIP解包和EPUB UI不重复运行；本次资源/恢复行为由同源Host覆盖。历史run41843348986的205通过、run41952767268的设备打包，以及0.2.1/build3的run41966767798（33通过及设备IPA成功）仅作历史参考，均不能替代本批MIME修复的原生执行。

## 验证与交付门

1. 固定基线e9615ca、批准10路径白名单、project.yml仅版本两行变化、干净已提交工作树；冻结本轮来源SHA/run/attempt/文件摘要。范围为3个EPUB生产文件（Compatibility/ContentPolicy/PackageParser）、Package及Host测试、project.yml、定向runner及其selfcheck、validate_task3与本文；不修改工作流、计数清单或其他产品模块。
2. 本地离线自检验证选择/来源/计数/失败分支。它不是Swift执行证明。
3. 固定工具链、真实依赖与已安装arm64模拟器；Domain28与Host5各执行一次，保存日志、真实退出码、选择/执行/计数回执和xcresult。Host总预算480秒、单例180秒不变。
4. 逐项原始开始/结束事件必须完整且全部passed；失败、跳过、重复、未知、漏项、未完成、超时和来源不符均拒绝。保存并重算定向总门，不能借旧205复用门绕过产品变更。
5. 模拟器链接通过后实际构建设备arm64 Release；保留设备链接/系统Swift SDK证明/依赖/许可/资源/签名状态与IPA全文件字节比较。
6. App与manifest版本必须均为0.2.2/build4。交付报告分开列本轮原生结果、历史参考、失败和修复记录。故障后先保存证据、评估实际影响，再在获准范围内修复重推和重编译，不默认全量重测。

原生通过与IPA成功仍不是用户原书真机验收。使用既有安装方式覆盖安装，不卸载/清库；在iPhone13/iOS16.6.1验证导入、图片页、正文、目录与退出重开，保留原书、进度和书签。
