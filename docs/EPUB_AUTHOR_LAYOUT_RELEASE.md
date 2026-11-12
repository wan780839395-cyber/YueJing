# EPUB 原始排版与恢复：0.2.16 / build 18

## 本批范围

基线：`cb749e62b4b468d7077cceaaba7bcd626294a269`。保留本批之前未提交的边界位置恢复、目录定位/筛选候选，再接入默认「原始排版」及可持久化的「阅读器排版」切换。当前授权包括本批定向云验证、终态后的统一修复与影响复验、严格 IPA；不是沿用旧批次单次失败即停许可。

本文件描述实现合同和验证计划，不是原生通过报告。最终源码字节及用例身份由 `scripts/epub_author_layout_scope.json` 冻结；原始日志、失败、xcresult 和交付报告只存 ignored artifacts。

## 行为及安全边界

- 缺省、空或未知偏好回退原始排版。阅读器排版使用原有字号、行距、主题；原始排版禁用不适用的字号预设控制，夜间可读性覆盖继续保留。
- CSS 经分词、解析、属性/选择器白名单净化；合并 manifest 本地外链 CSS、style 块和内联样式，不提供网络或任意文件访问。原 CSS 不进入可服务资源集。
- 每章作用域隔离，原 ID 映射保持 ID 选择器优先级；内联规则优先于保留的普通作者规则。`!important` 不保留；不承诺像素级复刻原书。复杂选择器、媒体查询、动画、定位、变量和未知函数等不在支持范围。
- 仅允许 manifest 绑定、未混淆 TTF/OTF，经 SFNT 结构校验和服务时完整 SHA 校验；单字体 8 MiB、全书字体 32 MiB，仍共享原总解包预算。CSS 单外链 1 MiB、内联 512 KiB、单章净化结果 2 MiB。DRM、固定版式、WOFF 等仍不支持。
- 字体 URL 绑定当前 session/epoch；原始模式等待所有实际 FontFace 变体就绪，取消、失败及晚回受原生命周期门控，不延长 12/15 秒就绪预算。
- 切换前实时采样文字节点/UTF-16/viewportOffset，重排复用恢复事务，不以页码替代稳定坐标。
- 独立 `authorStyleRevision=1`，不改变 parserVersion、文字节点或坐标单位。旧书从校验后的原包重建，证明文字摘要、目录和既有非 XHTML 资源不变、XHTML 路径/MIME 保留后 CAS 发布；失败不覆盖旧存储、原书或进度。未知非空 revision 拒绝。

## 最小充分验证选择

最终逐项身份以 scope JSON 为准，不以原生日志反推测试许可。

| 范围 | 选择依据 |
|---|---|
| AuthorStyles / AuthorStyleMigration | 新 CSS、字体、安全预算、迁移及失败保全 |
| EPUBPackage / Compatibility | 净化输出变化、文字坐标、旧格式及静态图片兼容 |
| EPUBReady / ContentPool | 派生版本、发布 CAS、租约、校验与损坏恢复 |
| EPUBLibrary（除封面缩略图和 v6 数据库迁移） | 打开、复用、取消、导入失败、会话、原书完整性及 TXT 隔离 |
| EPUBProgress | 文字坐标、权限、重排、viewportOffset 兼容 |
| EPUBReaderHost（除封面缩略图） | 真实 WebKit、权限、重排、恢复、打开呈现、暖复用和模式切换 |
| EPUBContentsNavigation | 目录原候选的六项原生断言 |
| EPUBFontLoadingHost | 自制可解码字体的真实加载与字形度量，非 SFNT 结构替身 |
| EPUBFlow UI 三项 | 目录、默认模式/偏好重启、退出/进程重启恢复、设置及 TXT 隔离 |

不执行无改动的 TXT 解码/分页/性能全量测试，也不重复无改动的 ZIP 解包器独立测试。相关包级安全边界仍由上述 EPUB 解析/资源测试覆盖；未选测试只标为未执行，不宣称本批全量回归。

本地选定：测试身份清单和解析器自检、新云门正反向自检、边界恢复静检、目录静检、横排 JS 合成测试、连续/作者排版真实 Chromium DOM 测试、必要 Python/JS 语法和 whitespace 检查。自制字体生成器只做确定性资产校验，不替代 WebKit 解码。

## 执行与交付门

- 完成实现后冻结，冻结后的任何失败先记录，继续独立步骤；整批终态后统一修复，再按实际影响选择复验，禁止削弱断言或增大超时。
- 使用既有 Task3 `epub-author-layout` 范围；固定 macOS 15、Xcode 16.4/16F6、Swift 6.1.2、XcodeGen 2.46.0、GRDB 7、ZIPFoundation 0.9.19、iOS 16.6 最低目标。
- 原生按文件分组，UI 按单项；每调用 480 秒、每用例 180 秒、模拟器 boot 120 秒、job 60 分钟。失败保留原日志和 xcresult，继续其他独立组；共享编译先决条件失败可将依赖组标为阻塞。
- 新源码白名单、真实提交 SHA、dispatch 原始输入、逐项开始/完成事件、参数展开和 xcresult 均重新绑定；不复用旧 opening-followup 资格链。
- 设备 Release 可独立编译；原生门不通过则不打包。通过后才验证设备依赖、WebKit 链接、arm64/iPhoneOS/iOS16.6/unsigned、版本、同 SHA 及 IPA 每个有效载荷字节。
- Windows 静检、Chromium DOM 与可控字体 doubles 均不能替代 Swift 编译或 WebKit；严格 unsigned IPA 也不代表真机已安装验收。

## 保护范围

不发布或读取三个用户私有文件内容，不修改原书、进度、协作文档或历史证据。使用逐路径暂存，不广泛 `git add`，不 reset/stash 覆盖，不 force。`AGENTS.md` 和 `docs/CURRENT_STATUS.md` 的用户改动不纳入本批提交。
