# 书签 MVP：本地实现与验证边界

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
