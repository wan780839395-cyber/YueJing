# 书签：添加时命名与操作栏调整

## 当前批次：基于 c7aec22，本地9文件

用户批准“本地调整与检查”，仅改书签添加命名、操作栏及相关回归/检查/本文。不提交、推送、云测试或打包，不改数据库迁移、跳转/进度/目录/导入/工具栏及其生命周期。

- 添加按钮先打开“添加书签”名称编辑框；保存才创建，取消不产生记录，保存后列表直接显示用户名称。空白沿用默认章节名；名称仍使用既有80个完整字素/控制字符规则。
- `OpenedReader.addBookmark`/`LibraryStore.addBookmark`增加默认空字符串的name参数，旧调用兼容。名称校验后随书签在同一insert事务中保存，不使用“先添加再rename”。重复精确位置返回原记录，不顺带覆盖旧名称。
- 添加/重命名共用编辑框并携带面板ID；旧面板回调不能作用于新面板。添加仍要求原位置捕获有效，取消/关闭不写库。原有严格锚点及跳转/进度保护逻辑保持。
- 重命名/删除统一为图标+文字的轻量操作栏，统一圆角、内边距与至少44pt点击高度；普通字号横排，辅助大字号纵排；删除保留危险色和二次确认，按钮不触发书签跳转。
- 仅扩展既有测试，保留166选中/167声明身份和原断言。覆盖直接命名、空名、非法名不创建、取消、重复不改名、单事务/回滚、进度独立及大字号操作。书签UI测试适配新增编辑步骤，并依据已收集AX采用唯一列表identifier（不限定Table）和具名Alert内唯一名称框/保存文字定位；不改其他UI用例。

验证口径：本地文本合同、负向夹具、Python SQLite模型、清单/AST及diff检查不代表Swift/UIKit运行。Windows无Xcode，本批原生编译、测试与真机执行0。结果存ignored `artifacts/bookmark-add-name-ui-local-c7aec22-01`。此前诊断IPA不包含本轮新增调整，历史161通过/2UI失败/3未执行不作为本批通过证据。

---

## 历史批次：基于 47e9c1f，本地15文件范围

用户已批准“本地修复与检查”。本批不提交、不推送、不触发 Actions、不编译或交付新 IPA；不改工作流、测试计数、依赖、route/Picker、原生 scene 权限或 dock 动画。

### 排查结论

1. **不存在同章节唯一限制或最小距离阈值**：去重键始终是 book/version/unit/rawByteOffset。旧添加快照会被每次 visibleChanged（包括等值回调）及重排撤销，打开面板后也没有在进入书签页时刷新；这些路径可导致添加不可用，但尚无真机事件记录证明用户“需滚很远”的唯一原因。不能把本轮修复写成已真机复现或验收。
2. **重命名此前未实现**：只有章节名快照，无独立名称字段、事务或编辑入口。
3. **跳转存在确定的状态耦合缺陷**：使用面板打开/添加时的旧 generation、positionRevision 和 window 校验；失效时尚未读取书签就抛 invalidAnchor，随后误报文字版本或位置不匹配。

### 本轮修复

- 显式添加捕获先完成待处理行布局；打开面板前捕获，在进入书签分区时按仍有效的 owner 重新捕获稳定位置。重复等值位置回调不再撤销捕获；仍禁止滚动中、重排中或未应用导航时添加。不同可见行可分别保存，同一精确位置继续去重，不以章节/滚动距离去重。
- 跳转在点击时建立独立的新快照，严格定位与排版 await 前后、安装窗口前继续校验 lifecycle/owner/controller/binding/generation/revision/window。旧准备结果不能跨重排复用；添加快照过期不再永久封锁新跳转。状态变化有单独提示，不冒充文字版本损坏。
- 仅追加 v5-bookmark-names 的 nullable customName；原 v1–v4 不变，旧书签继续显示章节名。名称去首尾空白，最多80个 Swift Character，禁止内部换行/控制字符，支持 emoji ZWJ，留空恢复默认。更新只修改同书籍同 ID 的 customName，不改锚点、创建时间、进度或设置。
- 列表加入可访问的重命名入口和编辑框，显示自定义名；改名不使正在进行的严格锚点复核失效，但删除/位置变化仍拒绝。
- 位置失效仅取消添加操作，不误取消读列表、改名或跳转；面板关闭/owner 失效仍撤销请求。失败定位不安装窗口、不写进度；成功后仍由原 windowApplied → visibleChanged 和退出保存链保存。

### 回归与验证边界

保留原测试代码/断言及 **166选中 / 167声明** 身份，扩展既有14 Domain、4 Host、2 UI 用例：同章相距3字节的记录、Host相邻可见行、UI固定80pt短拖动添加第二条；改名持久化/清空/80字素/非法输入/跨书/取消/回滚；旧快照失效后新跳转、重排后新请求、失败不改窗口与原进度。

离线检查命令仍见下方。本轮证据保存在 ignored `artifacts/bookmark-position-rename-local-47e9c1f-01`。检查器包含文本合同及负向夹具、提取生产SQL的Python SQLite检查；v5 ALTER 为明确标注的SQL模型，不是GRDB执行。**Windows没有Swift/Xcode，本轮原生测试、编译、真机执行均为0；UI流程已编写，不能据此宣称同章添加、重命名或跳转已在手机正常运行。** 新源码原生验证及IPA需另行批准。

历史 full166 的 Host 日志解析失败、UI11/Canvas3未执行事实保留；后来诊断IPA仅成功构建、当次测试0，不构成本轮修复验收。当前预算沿用 Host480s/UI1200s/case180s，本批不改预算。

---

## 历史记录：最初书签 MVP（以下为当时状态，非当前验证结果）

## 当前状态与优先级

用户已确认“先实现上述书签 MVP，dock 动画继续暂缓”，并批准 19 路径本地实现与检查。本批基于 `6ef51f098dbe4da9bcc3831c24804011f5d1c668`，保持未提交；不推送、不运行云端、不生成 IPA。dock 收回动画仍为 P3，不在本批修改范围。

**已写入本地代码和测试；尚未经过 Swift/Xcode 编译或原生测试，不是正式发布或真机验收。** 旧 6ef IPA 不包含书签，原 146 项历史通过不能作为本功能通过证据。

## 已实现

- 目录面板增加“目录 / 书签”分区，默认目录，不增 dock 按钮；无章节书籍也可使用书签。
- 当前书添加、列表、跳转、确认单条删除；精确位置去重，不做 toggle 删除。
- 新近创建优先、相同时间按 ID 稳定排序；每页最多 32 条，删除末页后夹到有效页。不累积全部书签或正文。
- 仅显示可选章节快照（最多 80 个完整字素）、创建时间和序号。不含摘录、改名、批注或同步。
- 错误和空列表区分，支持显式重试；不因失败清库或删除原书。版本/范围不兼容的记录保留、禁用跳转，仍可确认删除；映射损坏在严格定位时拒绝，不回退开头。
- 44pt 操作目标、辅助字号纵向分区/分页、VoiceOver 标签、关闭焦点和结果播报；实际可达性及焦点效果待原生/真机检查。

## 数据与生命周期边界

`LibrarySchema` 仅追加 `v4-bookmarks`。原 v1/v2/v3 不重写；独立 `bookmarks` 表用 `(bookID, versionID, unit, rawByteOffset)` 唯一键和按书籍/时间/ID的索引。

`ReadingBookmark` 保存不可变 UUID、book/version、`raw-byte-v1`、原始偏移、创建时间及可选章节名。`ReadingBookmarkPage.pageSize = 32`。`BookmarkRequest` 仅用 NSLock 保护取消标记，不在锁内 I/O 或 await。

`OpenedReader` 新增 `bookmarkPage`、`bookmark(at:)`、`addBookmark`、`deleteBookmark`、`bookmarkAnchor`。保存/定位校验 BOM、EOF、raw↔UTF16 精确往返和完整字素起点；不使用页码、百分比或模糊章节匹配，恢复 `lineFraction = 0`。合法正文 raw 0 允许，空文档和虚拟 EOF 不允许。

所有数据库准入核对当前 book/version/activeSession/closedSessions 与取消请求。重复位置返回原 ID 和时间；UUID 冲突于其他位置则报错。删除同时约束 ID 和 bookID，但允许删除旧版本记录。添加/删除不写 progress、preferences、activeSession 或 derivedArtifacts。

取消只保证撤销**尚未准入**的事务；已准入事务以真实 commit/rollback 为准，不在成功写入后再抛取消来谎报未保存。晚回结果只更新仍匹配的面板、owner 和 operation ID。

UI 在目录按钮动作中、sheet 出现前捕获真正首个可见行，不使用数据库旧位置或默认 0 兜底。拖动/惯性、重排、待应用导航、挂起、退出保存失败等状态不能添加。面板关闭/换书/挂起取消请求；重排与位置变化撤销捕获和准备目标。窗口、controller、scene binding、lifecycle、generation、position revision 均需匹配。

跳转分两阶段：严格解析并准备窗口期间不改当前窗口/进度；安装只接受当前准备结果。进度继续由原 `ReadingNavigationGate`、`windowApplied → visibleChanged` 和原退出保存链处理。原 route、`.id(route.id)`、Picker、导入、目录子树和 dock 动画保持。

## 测试清单：声明，不是执行结果

新增 **20 项**：

- [领域测试](../Tests/ReaderDomainTests/ReadingBookmarkTests.swift)：14 项，依次覆盖迁移/回滚、并发去重、UUID/DB约束、分页、跨书隔离、五编码/字素/BOM/CRLF、空书/EOF/损坏、旧版本、新Store/重复导入/缓存重建、原状态独立、取消、过期会话、提交后取消与标题上限、SQL/查询/可选目录失败。
- [Host 测试](../Tests/YueJingHostTests/ReaderBookmarkTests.swift)：4 项，覆盖实际可见捕获与进度独立、排队取消/旧面板、准备与实际应用、重排/owner替换/挂起。
- [UI 测试](../Tests/YueJingUITests/ReadingFlowUITests.swift)：追加 2 项，普通字号保存/去重/跨书隔离/进程重启/跳转；辅助字号关闭/跳转/删除取消及确认。

原 146 项身份和原测试内容保留；原 UI 9 项、100 个断言位置及辅助函数不改。严格清单现为：Core25 + Domain107 + Block6 + measurement1 + Host13 + UI11 + Canvas3 = **166 选中 / 167 声明**，另 1 项独立性能基线仍排除。Host480s/UI900s/单case180s/打开20s/dock与退出各10s预算不变。

以下 D1–D14、H1–H4、U1–U2 对应上述文件中的声明顺序。**所有原生测试均未执行**；“部分”表示尚未为设计的每一种组合编写新测试。

| 设计场景 | 已编写覆盖 | 尚需验证/补足 |
|---|---|---|
| BM-01 旧库升级/失败回滚 | D1 | 原生 GRDB 升级 |
| BM-02 初开未滚动添加 | H1、U1 | 真机首次可见捕获 |
| BM-03 不稳定状态 | H2、H4；沿用原惯性/退出测试 | 新书签与真实拖动、待应用导航、退出失败组合仍需覆盖 |
| BM-04 去重/并发/重试 | D2、D3、D14、H1、U1 | 原生执行 |
| BM-05 两书隔离 | D5、U1 | 真机跨书 |
| BM-06 大量分页/同时间/末页删除 | D4 | UI 多页操作尚需验证 |
| BM-07 准备/应用与旧窗口 | H3、H4；原导航门测试 | 原生竞争时序 |
| BM-08 排版变化后定位 | H4 部分（重排撤销），原排版测试保留 | 书签在新字号/行距/主题下的正向跳转与真机验证 |
| BM-09 编码/字素边界 | D6 | 原生 Foundation/映射 |
| BM-10 版本/同名/源变化 | D7、D8；原完整源校验不变 | UI 失配提示与源变化组合 |
| BM-11 缓存/重复导入 | D9 | 原生持久化与重建 |
| BM-12 进程重启 | U1；D9 只测进程内新Store | 真进程和真机执行 |
| BM-13 删除取消/确认/故障 | D3、D5、D8、D10、D14、U2 | 原生执行 |
| BM-14 查询与可选章节失败 | D14 | UI 失败注入/重试尚需验证 |
| BM-15 面板/owner/后台/取消 | D11–D13、H2、H4 | 正在await时的真实切后台/窗口重建组合 |
| BM-16 与进度/退出并发及故障 | D10–D14、H1、H3 部分 | 书签与自动保存/最终保存的并发压力组合 |
| BM-17 无障碍/Reduce Motion | U2；原辅助字号用例保留 | VoiceOver焦点/播报、Reduce Motion、真机布局 |
| BM-18 空书/末尾/坏记录 | D7、U2（短书） | 长书真实末屏首行捕获 |

## 本地检查

从仓库根运行（已有 Python，无需安装）：

```text
python -B scripts/check_bookmarks_local.py
python -B scripts/task3_test_inventory.py --self-check
python -B scripts/run_reading_ui_tests.py --preflight --self-check
git diff --check
```

第一轮 `VERIFY-1` 上述四组命令退出均为 0。书签检查器包含 11 个文件的文本合同、5 个破坏合同的负向夹具、7 组 Python SQLite 检查；SQLite 直接提取实际 v4、分页/COUNT/删除 SQL，但最小父表和夹页算术是合成辅助，**不证明 GRDB 迁移、Swift 类型、并发或 UIKit 正确性**。检查器也解析 scripts 下 Python AST。

本批结果保存在 ignored `artifacts/bookmark-mvp-local-6ef51f0-01`，包含原始 preimage、命令输出及最终保护核验。原生执行 0、编译 0、IPA 0；不能将 166 个声明写成 166 项通过。

## 范围与下一步

本批恰为批准的 19 路径（9 原有 + 10 新增），涉及上述 13 个产品 Swift 文件、3 个测试文件、测试清单、检查器及本文。不改工作流、依赖、工程配置、原目录组件、ReaderViewport、ReadingNavigationGate、ReaderFloatingToolsView、ReaderMotion、LibraryService 或用户数据。

下一优先事项是**另行批准的新源码原生验证**：核对完整 166 项清单与工作流关联/预算后，执行固定工具链原生测试及设备目标编译；成功后才考虑新 IPA 和同包真机检查。现有 `full146-package-66d1291-exact3` 专为旧父版本同源续包设计，不能用于书签新源码。历史固定计数/源身份门禁不能绕过，工作流适配不在本批范围。

当前 Windows 无 Swift/Xcode，无法完成这些验证；未获得提交、推送、云执行和新 IPA 授权。后续功能优先级未再扩展：EPUB、封面、漫画、AI 未在本批实现；dock 动画继续暂缓。
