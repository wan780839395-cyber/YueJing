# 三套阅读 dock · 本地源码批次

## 授权与文件范围
用户在已列明五路径及 B 中央留空后选择：**「批准5路径实现，B中央留空」**。原始消息 ID API 未暴露，记录 `unavailable`；本批为同会话可信转交，不另造授权或重复确认。

仅修改 `App/ContentView.swift`、`App/Reading/ReaderScreen.swift`、`App/Reading/ReaderFloatingToolsView.swift`，新增 `scripts/check_reader_dock_schemes.py` 和本说明。基于当前未提交工作树，不 reset 至 HEAD `d084dfec49b0c033e4eebf84535959c513676a9a`。不改旧 checker/原生测试/工作流/project/版本图标，不提交、推送、构建或生成 IPA。

## 已接线的表现层
- **只读注入**：唯一 `fullScreenCover` 构造点把现有恢复后的 `layout` 传给 ReaderScreen，再传给 dock；沿用 `LibraryLayout` 的 a/direct、b/tabs、c/sidebar、默认 B 与未知值 fallback。没有新持久化键、owner、服务、Task 或业务状态。Reader identity 仍是 `.id(route.id)`，不是 layout。
- **A 悬浮双按钮胶囊**：目录/排版两原按钮，轻表面与非命中背景描边；仍在原底部覆盖层中，不挪退出 header。
- **B 贴边轻栏**：目录/排版分居两端，中央是纯 Spacer，**没有章节号、进度或额外业务查询**。仅去掉原 dock 的外侧16pt/底8pt设计留白，使其贴当前安全区域边缘；不越过 safe area、不出现管理 Tab，也不改变 viewport。
- **C 边缘胶囊/托盘**：默认右下「阅读工具」；按下展开原目录、排版和明确「收起」按钮；收起后回胶囊。横向放不下时回退垂直可滚动工具托盘，宽最多340pt，竖向工具内容高度最多220pt；短高度环境最多88pt，再加外层4pt设计内距。实际几何/命中尚未渲染验证。
- 原目录/排版 action、禁用谓词、`reader.tools.directory`/`reader.tools.settings`、焦点键、字体与最小44pt缩放高度实现整段不变。新增 C toggle 用 `reader.tools.expand`/`reader.tools.collapse`，有文字、44pt与busy guard；展开优先聚焦可用目录/排版，无可用工具时聚焦收起；手动收起焦点回展开。
- A/B/C 都保留原 `visible && state.canInteract` hit gate、隐藏 AX、panel 互斥与 ReaderToolVisibility/Reduce Motion。没有新动画；C 展开收起即时发生，只有原工具显隐做已有局部动画。描边全部在背景且不命中，不添加前景装饰覆盖正文/退出。

## C 的局部状态语义
唯一新增 `@State private var trayExpanded = false`，仅为 UI：初入新 route 默认收起，手动展开/收起；**滚动隐藏、点击显隐、打开/关闭目录或排版 sheet 均保留展开值**。这样 panel 关闭后原 `lastPanelControl` 的目录/排版按钮仍存在，而不是把焦点还给已删除节点。工具隐藏时整个 dock 不可命中且 AX hidden，不是仍可操作的隐形托盘。

布局输入改变时只把局部托盘复位；若焦点处在新增 toggle 上则转到新布局的展开按钮或原 back。route 销毁时该局部状态一同丢弃，不写书籍、进度、设置或 UserDefaults，不加队列、计时器、onDisappear 推断或显隐状态机。

管理布局在 reader 期间已由原 root guard 禁止用户选择。本批采用 scope 所定的**当前恢复值只读传入**，不宣称对外部 UserDefaults/多窗口写入具有 session 冻结保证；外部值变更可更新表现并重置 C，但不改变 route/model。若要求外部写入也严格冻结需另批核定，不暗加 session snapshot。

## 阅读合同保护
- ContentView 除 reader 构造新增一个参数，其余完整文本与实际 pre-edit 相同：唯一模型/服务/start owner、管理根/busy守卫、Picker/编码/导入/反馈/fullScreenCover/route生命周期不改。
- ReaderScreen 首次只新增 `let layout`、dock 参数、dock 外边距分支；D1修复另增加精确的父恢复目标回调。逆转这些必要UI传参后完整文本与原373路径 pre-edit 相同。原 header 位置、44×44退出按钮、`reader.exit`/动作/hit/AX、stroke background before fill、viewport/onAnchor/onExtend/onWidth/scroll工具事件、panel/task/场景/内存/保存失败处理及全部 DEBUG 桥接不改。
- exit 仍为 beginExit → model.close / leaveKeepingSavedPosition → finishExit → 成功后 onExit；无新保存路径。原 ReadingToolsPresentation/ReaderToolVisibility/Motion、ViewModel/RouteOwner/Viewport/PanelHost/Settings/Directory 与 Core/Domain/数据均不改。
- dock 使用原 ReaderToolAppearance，即 ReaderTheme；不接 AppAppearance，不强制 App colorScheme，不写阅读偏好。安全区沿用已有 GeometryReader 覆盖层，不加 safeAreaInset、正文 wrapper 动画或正文新手势。

## 自检与证据
- **初次自检（不等于验收通过）**：21项源码合同、18个内存负对照通过，但后续独立核验发现D1；初次报告/日志与独立报告原样保留，不能将21＋18当作D1已覆盖。检查均为文本/词法/负对照，不是Swift运行。
- 可复现入口：`python -B scripts/check_reader_dock_schemes.py --baseline <本批prebaseline.json> --snapshot-root <本批snapshots>`。完整 ContentView/ReaderScreen 的精确反向还原及原工具按钮尾段比较通过，不用 HEAD 或旧批次快照替代本批状态。
- `check_library_navigation_schemes.py` 无 baseline 源模式：27合同＋13负对照＋9门规格表；旧 navigation/panel：107合同＋35合成；旧 motion 真实函数 import runner：136合同＋16负对照，均通过。没有虚构 `--source-only`，不适用旧214-path保护及额外hash负对照。
- Task3：13顶层＋40日志parser＋12 App parser；entry：57源码＋64合成；launch：120合成；device-entry：31离线检查；`git diff --check` 均 exit0、stderr空。Task3 内嵌 launch120 和单独 launch120 是同一组，不重复算独特case。原native声明139/选择138、Host480/UI900/case180/open20/sharedExit10保持，但不是本次原生执行数。
- 旧导航 `--baseline` 冻结整个历史 cover 区段，必然不适用于新增只读参数；旧 App visual whole-ContentView checker 也不是本批结构通过门。两者及旧快照/历史报告原样保护，不重写 baseline 或弱化断言消差；本批独立冻结与参数精确归一化负责保护。
- 修改前冻结 **373 个唯一路径**；只有3个授权既有生产路径变化，其余 **370/370** bytes/hash 一致。重叠分组不累加：156 tracked、17原untracked、48 Skills+lock、13原型、3指定IPA、128前批本地证据、6原有脚本pycache；scope原163路径采样作为重叠子集。前批全部未提交成果和私文件（仅hash）保留；HEAD/index字节不变，staged0，原pycache无增删。
- 新独立 ignored `artifacts/reader-dock-schemes-local-<UTC>` 保存 AUTHORIZATION、MODEL_ALLOCATION、prebaseline、三份完整snapshots、相对本批快照的五路径完整diff、stdout/stderr/exit、hash/verification与实施报告；scratch同名目录保留执行脚本。没有修改旧结果目录。

## 未验证与停止点
Windows 无 Swift/Xcode/iOS runtime。**Swift编译0、原生测试0、UI触控0、重启0、真机0、FPS0**；未证明三布局的窄屏/大字/横屏/安全区/读到末尾/VoiceOver焦点/Reduce Motion、目录排版往返、快速退出与保存失败的真实行为。源级检查没有发现必须扩大白名单的阻断，不能据此宣布原生验收。

完成本批自检即停；不自行递归委派或安排独立核验，由协调端另外执行已批准的一次独立核验。原型、历史134pass/1fail/3unexecuted、旧d084 build-only tests0或本地合成结果均不替代新 dock 原生证据。

## D1 定点修复（同一已批准批次，待关闭复核）
- 独立 `INDEPENDENT_VERIFICATION-20261031T021602678973Z.md/.json` 确认：目录/排版面板返回后手动收合C，只改当前焦点，父 `lastPanelControl` 仍是已移除的directory/settings；hide/show时请求旧节点。此为确定的源码过期目标，不宣称VoiceOver设备现象已复现。独立必要6命令均exit0也未排除此缺陷。
- 最小表现层修复：ReaderScreen给dock一个 `rememberFocus` 回调，直接更新原 `lastPanelControl`；dock的 `restoreFocus(to:)` 同步该记忆与当前焦点。手动收合记 `dock.expand`；再次展开时同步现存可用工具目标，防止记忆停留在已移除的expand；原layout复位时同步expand/back。未增加重复状态、Task、timer或业务操作。**托盘仍展开的panel返回继续保留原directory/settings；隐藏/面板不复位展开**。
- 本次只改ReaderScreen、FloatingTools、本批新checker/本说明4路径，ContentView不改。checker对父回调只作精确新增参数逆转，继续对原pre-edit全文比较；原toolButton尾段、退出/header/save/viewport/task链不变，373冻结/370保护分母及旧快照完全沿用。
- 新checker现为 **25源码合同（新增4）、25负对照（原18＋新增7）**，另列 **6条有界源派生规格**：directory/settings各自覆盖展开panel返回→hide/show、返回后收合→hide/show、收合再展开→hide/show。缺父同步、错映射、缺子同步、错误收合目标、再展开旧目标、破坏panel返回、layout复位旧目标均拒绝；不是Swift状态机或UI测试。
- 修改checker后先在未修复生产源码上实际检出 `D1-parent-restore-memory-callback-wired`（exit1，预期已知失败）；修复后新checker、motion源码子集、navigation/panel与diff-check相关复测通过，不重跑无关9入口，不把重复执行计新case。补充增量diff/hash/原始日志追加在同批 `D1_REPAIR-<UTC>`，原91项实施/独立证据只hash核对、未覆盖。
- **当前状态：原实施者已修复并相关自检通过，D1仍待协调端定点关闭复核；不是独立核验通过。** 原生编译/测试/触控/VoiceOver/真机执行仍0；无提交/push/构建/新委派或泛审。
