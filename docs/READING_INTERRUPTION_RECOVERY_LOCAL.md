# 阅读切屏交互恢复：本地候选（2026-10-31）

授权原文：**“批准本地9文件修复”**；message ID unavailable。基线 HEAD `fd4b925192cf97f9afca459be703b1ac5510a10f`，唯一父 `fc3fe1e4818dba7143148a4e781e73c804215d84`。本批仅本地源码与离线检查，commit/push/Actions/build/IPA/native executions 均为 **0**。

## 已知事实与限制

用户的“切屏”明确指切到其他 App 后返回，反馈工具无法唤出。四段录屏此前只经浏览器解码抽帧，未能目视；本批不追视频、不安装来源，不声称看过或确认 runtime 根因。源码确认的缺口是 VC 惯性影子状态未接入 scene 生命周期：如果中断打断惯性且没有收到清零 delegate 回调，同 VC 后续新 tap 可能持续得到 `stopMomentum`。缺失回调是候选条件，不是本次设备上已捕获的事实。

## 精确实现范围（6 既有 + 3 新）

- `App/Reading/ReaderScreen.swift`：既有 scene phase 回调中同步通知 viewport，早于工具变更及原保存 Task；将初始 phase 作为 ReaderViewport 输入。没有新 Task、onAppear 重开书或改工具/退出/面板 gate。
- `App/Reading/ReaderViewport.swift`：handle 仅新增局部 active Bool，幂等转发给当前 VC；新 attach 继承当前 phase；原 anchor/restoration 语义保留。detach 仍按身份，撤销离任 VC 回调与输入；迟到旧 detach 不清新 VC。
- `App/Reading/ReaderViewController.swift`：同文件 internal 纯 Swift `ReaderToolTouchContext` 为生产 gesture/delegate 实际使用。失活撤销 touch 与 generation、清 shadow；恢复校准真实 UIKit inertia。每次新 touch 取得最新 intent，保留开始时拖动/惯性锁存；结束仍消费原 `ReadingToolsGesturePolicy`，绝不清 UIKit 真实惯性或调整 offset。一次 stop 后只校准 shadow，下一静止 touch 可 toggle。cancel/reset 仅撤销对应 token；既有识别器失活时禁用以取消，恢复重新启用，不重建/叠加手势。
- `scripts/task3_test_inventory.py`：只追加四个固定 Host 身份；Host 2→6，selected 138→142，declared 139→143，原 performance excluded 仍 1。SWIFT_GROUPS 不纳入 Host，避免双计。
- `scripts/check_reading_entry_diagnostics.py`、`scripts/check_device_build_validation_entry.py`：只适配明确计数及标签 142/143。loader 四节点、runpy/scripts path、illegal command 防护与所有其它断言/时限不改。
- 新 `Tests/YueJingHostTests/ReaderInteractionInterruptionTests.swift`：四个普通 `@Test`，串行 MainActor，自含合成 ReadingWindow fixture。
- 新 `scripts/check_reading_interruption_recovery.py`：同步桥接/生产接线/代号与取消/真实采样/所有权及精确改动 ledger 的 source guards、负控和真实 pre-edit 语义拒绝；不是 Python 手势行为模型。
- 本文。

## 四项 Host 源码（未编译、未执行）

1. `interruptedDecelerationRecoversOnSameControllerWithoutMovingAnchor`：真实 table.delegate 注入 didEndDragging(true)，有意不发送 didEndDecelerating，真实 table idle；同 VC 经失活/恢复后 fresh tap 可 toggle，window/anchor/offset 不变。
2. `interruptionRevokesOldTouchAndAcceptsFreshIntent`：旧 touch 结束/取消不能复活或消费 fresh touch，新 intent 经真实生产 callback 与 ReadingToolsPresentation 生效；取消后可接收下一 touch。
3. `momentumAtTouchBeginStillStopsBeforeANewIdleTouchCanToggle`：开始时惯性锁存、结束前 idle，第一 tap 仍 stopMomentum，下一静止 tap toggle；另覆盖 shadow 被一次 stop 消费。
4. `viewportInterruptionForwardingIsIdempotentAndDetachedControllerIsInert`：重复 phase/同 VC attach 不撤销 fresh touch；replacement 继承 inactive，旧 detach/回调无效；无 VC 时失活、之后 attach 仍 inactive，恢复后可接收新 touch。

这是**真实 VC＋生产决策 helper 事件序列注入**，没有 UITouch，不是原生系统中断或漏 callback 的复现。Windows 无 swiftc/Xcode/iOS；Swift 编译、4 Host 执行、旧回归执行、实际切屏/命中/真机验收全部未做，native executions=0。

## 冻结与离线验证

本批权威 evidence 目录：`artifacts/reading-interruption-recovery-local-20261031T131526220169Z/`。包含真实 pre-edit 六文件副本、baseline.json、完整九文件 diff/最终 SHA256、命令退出码和原始输出、精确改动 ledger、保护复核与最终报告/机器 JSON；不覆盖任何旧 evidence。

运行方式：`python -B scripts/check_reading_interruption_recovery.py --baseline artifacts/reading-interruption-recovery-local-20261031T131526220169Z/baseline.json`。保护以真实编辑前 worktree 为准：范围外 tracked 全部逐一 SHA256，加显式 Skills/lock/AGENTS、三私文件（只 hash）、预存 pyc 与最新 fd4 IPA/有界验证报告样本；不是遍历全 artifacts。原 139 身份、所有旧 Tests/预算、位置保存与模型/route/DB/Picker、dock 三 Swift/Motion/Visibility、C/D1 focus、B 空中部和 Reduce Motion 均保护。

最终命令结果见本批 `IMPLEMENTATION_REPORT.md` 与 `machine.json`。现有三个 `--device-release-ci` 只作当前 dock source 合同，不代表脏树通过旧 exact8 发布 gate；本批没有发布权限。普通旧 dock/motion/cohesion 的历史 freeze/ledger/138-139 冲突应保留原失败，不修改旧断言换绿。未来若获云端授权，task3 workflow 旧“2 Host/138”步骤名称需另批同步；当前 ios-build exact8 gate 不适用于此功能批，本批两 workflow 不动不触发。

实际离线结果：新 checker **30 source contracts / 18 negative controls** 通过（含真实 pre-edit 语义拒绝和保存尾段负控）；inventory、runner preflight/self-check、entry/launch、Task3 synthetic validator、loader、library navigation、三个 dock `--device-release-ci` 与 diff/whitespace 检查通过。不同入口有重叠断言，不合计作唯一测试数。初次新 checker 因 SequenceMatcher 将相同空行/闭括号对齐到插入点 3/65 而拒绝，已仅校正精确 ledger 坐标，原失败输出保留，未因此修补生产源码。

保留失败：旧 dock 普通入口 `existing-visibility-only-animation-and-reduce-motion-isolation`；旧 motion 普通入口 `Non-paint delta: App/Reading/ReaderScreen.swift`；旧 cohesion 普通入口 `Non-paint delta: App/Reading/ReaderToolAppearance.swift`；旧 navigation-panel `inventory:138-selected-test-declarations-intact`（现为 142/143）。最后一项是批外历史 count 锁，不自行扩围改 checker。motion 现有 source function 单独检查通过；navigation-panel 在原 count 断言前的 source assertions 均执行通过，断言仍失败，未伪造旧库存换绿。所有原始 exit/stdout/stderr 见 evidence。

## 不在本批

dock 动画/外观、显隐卡顿及旧退出故障不处理。不得由离线检查、合成 Host 源码或上一包构建成功推导切屏已修好、动画/视觉/VO/FPS/性能或真机验收。完成停在未提交，等待一次独立定点复核。
