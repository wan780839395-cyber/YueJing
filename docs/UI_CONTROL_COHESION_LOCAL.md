# 三入口与阅读控件边界精修（仅本地）

基线 `fdbdca0938b60cd2a3cc60389e8bffa9e04f3a89`；授权为现有设计精修，不含提交、推送、Actions、构建或网络。原只读规格及 238 路径基线在 `artifacts/ui-inspection-20261031/`，不覆盖。新证据目录为 `IMPLEMENTATION20261031T064231915687Z/`。

## 实施范围

- A 书架：左上“更多”保留原 Menu，改为紧凑图标入口，仍有文字无障碍名；与导入统一 44pt、12pt 连续圆角、语义图标字重及细描边。导入短标题“导入”，完整无障碍名仍为“导入书籍”；轻强调不再叠胶囊。原 action、disabled、反馈及呈现链未改。
- B：原生三个底部分区不变，仅使用同源导入与设置精修。
- C：顶栏菜单与导入统一；侧栏关闭与分区选项增加可见同形边界及当前状态，保留遮罩、选择、忙态及焦点返回。
- B/C 设置：仍是原两个 Menu、原选择回调，无新增确认步骤。每个 label 内有标题、当前值/勾及说明；内部 padding → >=44pt frame → 可见表面/描边 → 同一 12pt contentShape。List 行背景透明、显式 plain button style、外部 6pt 行间隙，不以整行隐形命中区域代替控件。
- 阅读 A/B/C：保留 A 双按钮浮胶囊、B 两侧工具与真实空中部、C 折叠胶囊及展开托盘；统一符号 imageScale、语义字号、图文留白和轻描边。目录/排版与收起使用同源可见 >=44pt 控件，展开胶囊表面和 shape 在 label 内。不修改正文 viewport、退出保存、工具可用条件、隐藏/显示、sheet 或 D1 焦点记忆闭环。
- 阅读设置：主题的背景、选中描边、勾与 contentShape 覆盖含标题的整张卡片；预设也使用相同整卡片形状；装饰不截获事件。保留选中 AX value/trait、即时保存、恢复确认和 Reduce Motion 装饰级动画。

实际修改 8 个既有文件：`App/ContentView.swift`、`App/Library/LibraryExploreSettings.swift`、`App/Library/LibraryNavigationShell.swift`、`App/Reading/ReaderFloatingToolsView.swift`、`App/Reading/ReaderCompactButtonStyle.swift`、`App/Reading/ReaderSettingsView.swift`、以及以下两个条件文件：

- `App/Reading/ReaderSettingAdjustment.swift`：加减符号改为动态语义字体，去掉与共享圆角 style 冲突的内层矩形 shape；步进/滑块提交逻辑未改。
- `App/Reading/ReaderDirectoryFooter.swift`：目录底部两个共享 style 调用移除旧参数及内层矩形 shape，确保组合后同形。分页/当前章 action、禁用条件、ViewThatFits、16pt 加载占位未改。

`ReaderCompactButtonStyle` 不再 inset 可见底形（旧默认 6pt 会把最小 44pt 底形缩至 32pt）；style 在同一边界提供 >=44pt frame、圆角 contentShape、底形与描边。保留接受旧 `surfaceInset: 0` 的初始化签名供未修改的 `ReaderDirectorySheet` 使用，该参数不再缩进任何表面。未新增生产文件；其他视觉 token、ReaderScreen、ReaderViewController、ReaderViewModel、Domain、Tests、旧检查器、工程/依赖/workflow、Skills、私文件均不修改。

## 本地检查方法与边界

```powershell
$env:GIT_OPTIONAL_LOCKS='0'
$env:PYTHONDONTWRITEBYTECODE='1'
$env:TMP=$env:PI_SCRATCH_DIR
$env:TEMP=$env:PI_SCRATCH_DIR
python -B scripts/check_ui_control_cohesion.py
git diff --check
```

新增检查器仅做 source/hash/反例检查，不读三私文件正文。对批准的逐条展示差异固定原始与当前行区间及片段 SHA；先核对 git blob 与实际预编辑 baseline 的 hash，再精确逆转这些片段，与原文件其余全部源码比较。不会忽略整个文件、整个函数或所有 frame/background。内存反例覆盖旧 32pt inset、旧 Menu 行、旧主题色块描边、shape 不一致、外部透明 padding、List auto style、小于44、B 假中部、C 焦点、Reduce Motion 和 action/persistence/busy/commit 漂移。

既有检查均保持原断言：实际 live-source 失败原文、命令、退出码和精确展示片段逆转后的行为比较单独保存于证据目录。历史精确快照或旧实现字面假设失败不改断言换绿；基线本来已失配的旧脚本也不算本批通过。各脚本计数有重叠，不累加成测试总数。原生声明仍为 139、选择 138，预算不扩大。

Windows 本批原生编译/执行/截图/坐标命中/VoiceOver 实测均为 0。源码中同形不等于 UIKit 的触控容差或 AX 框像素完全相等，不能声称真机错位根因已证实或已修复。大字体采用换行、纵排和滚动，不强缩/截断；颜色仍使用独立管理与阅读主题 token，实际对比度与系统 Menu 弹层需原生检验。

待后续明确原生授权后，在真实 iOS 16.6 设备分别检查 A/B/C × 清朗/柔雾/墨夜 × 浅/深色、最大辅助字号、横屏/短高度及 Reduce Motion；对可见控件中心、四边内侧、外侧空白和相邻控件分别点按，核对仅对应动作一次、AX label/value/frame、disabled、菜单弹层及 D1 收起/再展开/面板返回。此清单不是已执行结果。

## 续批：五项旧检查合同协调（仅本地）

用户另行授权“先检查并解决那5项旧检查冲突，再做原生编译验证”。本地执行范围为五个旧 checker 与必要 cohesion 保护适配/说明；本阶段未改 App/Domain/Tests/workflow、未提交/推送/Actions/构建。后续发布和 workflow 门禁修改仍须明确批准。以上原实施批次失败记录及反向投影证据原样保留，不追溯称其原先全绿。

新冻结/证据：`artifacts/ui-inspection-20261031/CHECKER_RECONCILIATION20261031T070145449797Z/`。从续批开始冻结15,624个路径（含所有历史 artifacts、21个IPA、6个pyc、全部原源码与三私文件hash）；八个Swift精修与其余业务文件必须保持续批开始的原字节。仅修改五个旧检查器、已有 cohesion checker、本文共7文件，没有新增生产或测试脚本。

五脚本普通无参数入口直接验证**当前工作树**：navigation 29 source/19反例；dock 26 source/26反例（含D1四合同及另六行源派生规格）；navigation-panel 109 source/7反例/35合成规格；motion 141 source/20反例；foundation 36 source/12反例，均实际 exit 0。计数重叠不相加，更不是139声明/138选择的原生执行。修正的是过时定位/表面写法，不是删除功能、安全断言换绿。

- navigation 约束短可见导入标题、完整AX名与原action、>=44pt同形表面；Menu维持plain与外部透明行。拒绝错AX/action、可见inset32、缩小尺寸及Menu shape/自动行错误。
- dock 从固定旧描边数量改为逐处A/C背景与label内C Capsule的实际形状/顺序，检查共享style>=44；保留B中部真留空、全部D1与原owner/动作。拒绝中央按钮侵入、C焦点失同步、shape不符及inset/尺寸退化。
- navigation-panel 校验当前无inset、44pt、同形stroke/contentShape及仅装饰禁命中，保留排版/目录/保存合同；补有效Swift结构的圆角不符及主题单独变异反例。
- motion 逐张定位整卡圆角，分别限制背景/勾局部动画及ReduceMotion，主题标题在整卡内。**无参数正常CLI现在是v2 live-source职责**；不再自动拾取无关历史scratch的214文件baseline；`--baseline`只显式用于历史motion阶段的严格hash合同，不用本批新freeze冒充旧格式，也未加入不存在的--source-only。
- foundation 改为追踪当前ContentView→LibraryManagementOptions/LibraryShelfContent/NavigationShell及chooseAppearance真实链，保留独立keys/颜色/guard/副作用禁止；旧`--snapshot-root`仅为foundation-v1历史反向快照，不是本批保护。当前保护由新续批freeze提供。

复跑五脚本：`python -B scripts/check_library_navigation_schemes.py`、`check_reader_dock_schemes.py`、`check_navigation_panel_layout.py`、`check_ui_motion_polish.py`、`check_app_visual_foundation.py`（后四同样位于scripts）。续批保护使用：

```powershell
python -B scripts/check_ui_control_cohesion.py --reconciliation-freeze artifacts/ui-inspection-20261031/CHECKER_RECONCILIATION20261031T070145449797Z/start-freeze.json
```

原42 source/19反例/53个精确展示片段规则不变；仅显式接受本续批五checker的旧基线差异，并逐一对续批所有冻结路径重算hash，除7个授权文件外不许变化。无此参数时保留原严格批次保护（会正确拒绝后来五checker变化）。原生编译发布最小门禁计划/完整候选白名单见新证据目录 `NATIVE_COMPILE_SCOPE.md`；该文档仅计划，尚未修改或执行workflow。
