# 真机反馈：dock本地精修

授权原文「批准，先优化 dock」，messageID unavailable。基线fc3fe1e4818dba7143148a4e781e73c804215d84，父7d55；仅8路径本地范围，不提交/推送/Actions/构建/安装/网络。用户对体量、样式和动画稍卡反馈成立；不追溯安装来源、不用离线binary差异质疑用户；性能根因尚未知。

## 本次实现
- A不再把背景画在maxWidth340外壳上。每个ViewThatFits候选的actual内容自己提供4pt内距/单层26圆角表面，正常横向双动作intrinsic-size；外围全宽仅无paint居中锚定。按钮label不再maxWidth infinity，独立min44×metrics高度，不硬编码240等设计宽度。AX/窄屏沿用垂直ScrollView、有界高度； fallback可占可用宽避免强缩/截断。
- C右侧无paint锚定；正常横向候选以leading Spacer把内容型三动作表面推到稳定右边，展开托盘24圆角、4pt内距，收起仍secondary。collapsed为单28圆角软底，沿原F1合同在buttonStyle后方，不在label里盖住pressed反馈。禁用alpha0.4、44触达/原guard/AX/focus保持。
- B仍贴边两端工具，中央原Spacer(min24)是真空，没有章节/百分比/占位动作；单层16圆角表面，无阴影底形。三套dock全部取消额外“shadow形状+shadow”绘制，保持必要底色，不做零表面/内部常驻描边。
- ReaderToolAppearance.fill改为固定opacity1的ReaderTheme局部纸/浅/深软色（239/236/226、241/244/238、45/53/47），不靠0.97透字，不加Material/blur/drawingGroup/compositingGroup。reduceTransparency原输入保留兼容；现始终opaque。此fill也供既有ReaderScreen/header使用，因此header仅共享底色变得不透明，源码/布局/标题/退出/frames完全不改；面板surface/card与正文主题偏好独立保持。
- 工具显隐原0.16s easeOut、±6pt与child transaction隔离没有已确认范围内缺陷，**ReaderToolVisibility.swift原字节保持**，未延长时长冒充性能改善。快速目标改变可立即反转，门控不等待动画完成。
- C采用已有trayExpanded驱动的**新分支100ms opacity淡入、离场identity即时移除**。两个branch内容入口transaction.animation=nil阻断布局/子内容隐式动画，外层仅局部transition动画，锚定frame在动画修饰器之后。无frame/scale/matchedGeometry morph、无newState/Task/Timer/延迟/完成回调。每个分支显式按当前trayExpanded+visible+canInteract关闭离场hit/AX；原state与父lastPanelControl立即更新，不等呈现完成。原onChange(layout)复位/隐藏或panel保持展开/route销毁语义不改。

## 真实范围与检查入口
允许4Swift+3checker+本文；实际ReaderToolVisibility未改，其余7路径变化。未改共享ReaderCompactButtonStyle或任何ReaderScreen/viewport/model/controller/domain/test/workflow；不删除不存在的内部stroke，不重新设计书架/设置。

三个既有获批checker追加显式 **`--device-feedback`** 入口验证真实fc3预编辑基线与本批合同。原默认CLI、历史local/releasephase函数与旧SHA/hash比较原样保留。实跑旧dock默认因旧“只显隐动画”合同失败，旧cohesion默认因旧paint账本失败；旧motion默认在其不含本次dock/ToolAppearance的检查范围内通过，不把它当新C合同验证；失败原文另记。新入口不调用旧整套再换绿，仍检查业务动作、独立44/paint/geometry、F1层序、B中部、C父焦点、RM/animation隔离并拒绝真实preedit dock/paint与motion；source拒绝与freeze拒绝分开。

```powershell
$env:GIT_OPTIONAL_LOCKS='0'
$env:PYTHONDONTWRITEBYTECODE='1'
$env:TMP=$env:PI_SCRATCH_DIR
$env:TEMP=$env:PI_SCRATCH_DIR
python -B scripts/check_reader_dock_schemes.py --device-feedback
python -B scripts/check_ui_motion_polish.py --device-feedback
python -B scripts/check_ui_control_cohesion.py --device-feedback
git diff --check
```

本批证据 `artifacts/reader-dock-device-feedback-local-20261031T105402093527Z/`：17个精确paint/局部transition片段固定新旧范围/hash/唯一锚点，再逆转逐字比较全部其余源码；不屏蔽整个文件或所有frame/bg。额外直接比较动作closure/AX/disabled/guard/state/focus/lifecycle行、原metrics，并对范围外tracked字节完整hash保护。新freeze明确exact8允许路径、HEAD/index/staged、私文件仅hash、Skillslock/AGENTS/选定最新交付IPA/旧F1与本次发布证据/pyc等有界样本；不递归海量artifacts，组别重叠不相加。

保留正常入口兼容性结果：另外3个UI checker如旧paint精确账本失配，不修改范围外脚本；旧失败不算本批通过。原entry/launch/Task3/loader/UI preflight+selfcheck/inventory139declared138selected与git diff本地运行输出逐项保存，不运行native tests或网络。

## 不可证明事项
没有Windows Swift/Xcode或真机动画测量，本批native编译/视觉/命中/VO/FPS均0。省去额外shadow shape、减少半透明混合与内容宽度测量失配是明确源码简化，不是已证实卡顿根因或FPS收益；C采用呈现淡入而非连续形变，实际SwiftUI中断/AX/长标签/短横屏/极限字号仍需后续明确原生授权。修后只安排一次独立有界复核，不发布新IPA。

## 新批：精确8文件发布与单次设备构建

以上是已完成的本地批历史，原授权/冻结不变。本批新批准问题原文：「是否批准上述精确 8 文件发布与单次设备构建？3 个 Swift 候选固定，仅适配 3 检查脚本、说明和 workflow；普通 commit/push/ios-build dispatch 各一次，失败即停。成功后独立验包交付；不跑完整回归、不改书架设置。」回答原文：「批准8文件发布与单次设备构建」。消息ID unavailable。新额度commit/push/dispatch各1，不能复用fc3旧批额度。

公开路径仅上述3个固定Swift、3个checker、本文和`.github/workflows/ios-build.yml`；ReaderToolVisibility不改不提交。发布父固定为完整fc3fe1e4818dba7143148a4e781e73c804215d84；三个Swift候选SHA-256依次为`7f88084e0471181630b2cfaf2ac360b5f9cfdccf5da187929b5d68f631e123d9`（dock）、`98582f56f432346a152067507eb5fc84cf0b107b9936fb42c9237079d0babfab`（appearance）、`f2b33dfda693e39313d8746431b822258193f54cac3d677757251e0cff56be4a`（motion）。不改书架/设置、业务/测试/资源或工具链。

三个checker新增显式`--device-release-ci`：复用当前19 dock/8 motion纯源码合同及11/13负例，真实旧源码来自固定fc3 Git blob，干净checkout无需ignored preedit/账本/receipt。cohesion合并27合同/24负例；D1六行有界源码规格不是运行测试。原`--device-feedback`仍绑定旧本地冻结；旧默认dock“existing-visibility-only-animation-and-reduce-motion-isolation”和cohesion“Non-paint delta: App/Reading/ReaderToolAppearance.swift”失败保留，不修改旧哈希换绿。

本地cohesion另用`--dock-release-receipt <新receipt> --dock-receipt-sha256 <完整SHA256> --dock-release-stage precommit|staged|committed`；committed还必须`--source-sha <真实新SHA>`。新receipt单独固定final8、范围外selected保护、初始index及父；precommit拒绝index/staged漂移，staged验证exact8及逐blob，committed验证新SHA/唯一父/exact8/clean。三个阶段均保留原17片段逆转与业务/focus/AX比较，不豁免HEAD/index。新证据在唯一ignored `artifacts/reader-dock-device-buildonly-<UTC>/`，最终结果不再次推送。

现有ios-build门禁核对main/manual/attempt1/actual SHA/唯一父/exact8/regular files/固定3，然后运行自包含源码正反例。原生成/依赖/Release arm64设备编译、资源/loader/unsigned打包/upload保持；TESTS NOT RUN、tests_run=false、native executions0、空selection/execution与未真机验收必须披露。仅workflow397959305一次dispatch；意图先独占保存，EOF/timeout也耗额度，不能重发。任何实际构建/打包失败停止，不补丁/重推/rerun；绑定唯一新SHA run后交独立只读采集与验包，不把queued当通过，不宣称视觉/触摸/FPS/性能或完整回归通过。