# 三导航方案 · 本地源码批次

## 授权与状态
用户批准原文：「批准本批本地实现」。同会话协调端限定转交；消息 ID 未暴露，记 `unavailable`。基于实际工作树继续，不重置 HEAD `d084dfec49b0c033e4eebf84535959c513676a9a`；仅本地，无提交/push/Actions/构建/安装/新 IPA。

本批实际 10 路径：7 生产源码（ContentView、LibraryPlannedEntriesView、LibraryPlannedFeatureView，以及新增 LibraryLayout、LibraryNavigationShell、LibraryShelfContent、LibraryExploreSettings），新增 checker 与本说明，仅适配旧 `check_navigation_panel_layout.py` 的诊断入口位置断言。获准备用的 `check_ui_motion_polish.py` 无需修改。

## 已实现的原生源码（尚未编译/触摸验收）
- **A 书架直达**：单一真实书录 List、顶部「导入书籍」轻胶囊与「更多」系统 Menu；书录后只有漫画/AI 低频规划入口。无 TabView、无虚构继续阅读卡/作者/进度。书名与实际最近阅读日期完整展示，未制造编号身份或重新排序。
- **B 底部分区**：原生 `TabView(selection:)`，书架/探索/设置三分区；书架不重复底部拓展。探索仅漫画/AI 规划；格式、封面展示说明、外观、布局、诊断、许可在设置。阅读仍由原 `fullScreenCover` 覆盖管理区，不改 dock。
- **C 侧栏工作区**：顶部菜单打开有界、自有侧栏，书架/探索/设置为一级导航，低频诊断/许可同栏可达。无 tabbar、无底部拓展。抽屉内容可滚动，宽度不超过 300pt 且预留 32pt 背景；背景内容禁用 hit testing 与 AX，另有关闭按钮/遮罩/Escape/AX escape 和焦点返回。只有抽屉层有 150ms 位移/透明度轻动效，Reduce Motion 清除该层动画。书库继续复用真实 List，而非把全部书改成双列网格。
- 三方案共同复用真实 `books`（原顺序/稳定书籍 ID）、通知/导入进展/停止与重试 UI。选择控件有完整名称及「当前」/勾，采用语义字体、最小 44pt；窄屏、大字和 VoiceOver 仍待实际验证。
- 唯一真实导入动作仍调用 `model.beginFileSelection()`，文案改为「导入书籍」，说明「当前仅支持 TXT；EPUB 规划中，未接入」。Picker 类型、严格 TXT 准入、安全复制、编码与数据库全部未改。EPUB 是格式说明，封面是书籍显示说明，不列为探索独立业务；漫画/AI 仅静态规划，不联网。
- 四规划统一回调父级唯一 planned destination；`LibraryPlannedNavigation` 原单 active/UUID begin/end 晚回保护未改。详情所有调用显式传入当前 `appearance`，不再独立默认柔雾，不读取 AppStorage/ReaderTheme；不强制全 App colorScheme。
- 诊断从旧工具栏 NavigationLink 迁为父级受控 information destination，数据参数相同；许可按需读取既有 Bundle `GRDB-LICENSE.txt` 全文，不复制/截断/编造，不新增资源或 Task。读取失败明确提示失败，实际资源打包仍待原生验证。

## 状态与生命周期合同
- 独立稳定布局值 `a/b/c`，键 `dev.yuejing.ui.libraryLayout.v1`；默认 B，未知值只读 fallback B，不擅自写回修复。只在用户选择时赋值；临时分区、抽屉、UUID 路由使用根 `@State`，不落 AppStorage。
- 首批外观键 `dev.yuejing.ui.appAppearance.v1`、三名称/默认柔雾/未知值恢复保持；与布局键、ReaderTheme 完全独立。AppVisualStyle、LibraryAppearance、ReaderVisualStyle 和首批旧 checker/doc 本轮字节不变；ContentView 的外观控件迁移到共享管理选项，但写入仍由根守卫函数执行。
- `ContentView` 仍唯一拥有原两个 StateObject、服务工厂及 NavigationStack；shell 只收值、Binding、已构造视图和 action。布局条件仅切换展示树，不用 `.id(layout)`，不在 tab/子页增加 task、业务模型或服务。
- 原六忙碌门保持完整：service、反馈呈现许可、未导入、无编码确认、无反馈消息、无 reader；另加无规划 push、无诊断/许可 push、无 drawer 的管理根门。布局/主题菜单禁用且实际写动作再 guard；tab Binding setter、打开 drawer、drawer 分区/信息 action 也 guard。拒绝忙态请求，不排队、不取消业务、不延迟重试。
- 模型在 Picker dismiss 后保留 FileSelectionSession，因此用原 `canPresentLibraryFeedback` 的 dismissal 合同，而非错误要求 `fileSelection == nil`（会永久锁住导航）。C 中先选设置、drawer 关闭后才能切布局；切换成功只写布局值、回书架、关临时 drawer。
- `init`、工厂、原六门、reader dismissal Binding、planned dismissal Binding 逐段完全相同；根 `library.screen` 后的 probe/fullScreenCover/task/memory-warning/reload/Picker/编码 sheet/反馈 alert 整段文本相同。原 bookID open、停止/重试/notice actions 只迁到父传闭包；规划 begin 外增管理根 guard。不存在宽泛移除 state/任务的比较。

## 离线验证与界限
- 新 checker：27 真实源合同、13 内存变异负对照；另有 9 门否定真值表（仅规格，不是 Swift 状态机执行）。通过本批真实 pre-edit 快照比较与 hash 保护。
- 旧 navigation/panel：107 合同 + 35 合成规格通过。仅把「一个诊断工具栏 NavigationLink」映射为实际管理 action → 父回调 → 受控 destination → 同参 ReaderDiagnosticsView；root-list 断言名称改 root-shell，原 destination 次序约束不变。其余门控、两种规划按钮、两类 AX ID、UUID、阅读布局/原生清单合同不改。
- 旧 motion 文件原样：调用实际 `load_live_sources` / `verify_source_contracts` / `verify_negative_controls(..., None, None)`，136 源合同 + 16 负对照通过。没有伪造 `--source-only` 参数；前批固定 214-path baseline 不适用于本批，未修改它来假通过。
- 首批 `check_app_visual_foundation.py` 原样保留，其函数同时绑定旧 ContentView 菜单位置，故不声称本批直接执行该历史 checker 通过；等价独立键/恢复/选项/写入守卫/显式 appearance/阅读隔离由新 checker 与冻结首批基础文件 hash 覆盖。
- Task3：13 顶层离线门控、40 parser、12 App parser；entry 57 源合同 + 64 合成；launch 120 合成；device-entry 31 离线项全部通过。Task3 嵌入 launch 的 120 项与单独运行是同一组，不重复计独特 case。`git diff --check` 通过。
- 两次检查器开发失败如实保留：初版 Python 多余括号导致 SyntaxError；修正后负对照发现 AX 检查匹配了另一个控件而未识别背景遗漏，已改为精确根背景连接检查。第三次完整运行全部 exit0；不是 Swift 编译失败/修复证据。
- 新冻结分母 232：156 tracked、11 原 untracked（8 成果 + 3 私文件只 hash）、48 Skills+lock、13 原型、3 指定 IPA。预期改变 4 个既有路径，其他 228 路径相同；其中全部 Reader/Core/Domain/原生 Tests、工作流/project、图标/版本、用户私文件、Skills、原型与 IPA 不变；HEAD/index/staged 另核对。完整清单、原始 stdout/stderr/exit、失败记录及结果在本批 ignored artifacts / scratch。
- **原生编译 0、原生测试 0、触摸导航/布局切换/AppStorage 重启/进出阅读/导入竞争/Dynamic Type/VoiceOver/真机均未验证。** iOS16.6 / Swift语言6.0、compiler6.1.2 / Xcode16.4 / GRDB7 不变；默认 B 是源码实现选择，不是原生验收结论。阅读器/dock 与业务完全不在本批修改范围；三阅读 dock 仍须后续另批授权。
