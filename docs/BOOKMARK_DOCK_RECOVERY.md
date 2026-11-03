# Bookmark dock 测试恢复：八文件、一次完整验证、条件诊断 IPA

## 批次与边界

本批批准原文：**批准修复、一次完整验证及条件诊断IPA**（消息 ID 不可用）。随后本地 runner 自检发现 `scripts/check_reading_launch_diagnostics.py:466` 仍硬编码900秒，与已批准1200秒冲突；用户补充明确批准：**批准新增这一个自检文件**（消息 ID 不可用）。只允许该文件第466行的UI预算900→1200及对应label同步，其余修复、一次完整验证及条件IPA约束不变。基线为 `da2f05aa6816cad1a600c687133fffc626de0e0e`，唯一父提交；213 个 tracked 文件变为 215 个。只允许以下八路径改变：

1. `Tests/YueJingUITests/ReadingFlowUITests.swift`
2. `scripts/run_reading_ui_tests.py`
3. `scripts/check_task3_validation.py`
4. `.github/workflows/task3-validate.yml`
5. `.github/workflows/ios-build.yml`
6. `scripts/check_bookmark_dock_recovery.py`（新增）
7. `docs/BOOKMARK_DOCK_RECOVERY.md`（新增）
8. `scripts/check_reading_launch_diagnostics.py`（补充批准；仅第466行）

不改 App/Sources、实际手势、dock 动画、书签数据、路由/身份/session/进度。冻结全部 166 项身份、测试正文和断言；不删测、不跳过、不降低断言、不补充正文点击。固定 iOS16.6、Xcode16.4/16F6、Swift6.1.2（语言6.0）、XcodeGen2.46.0、官方 GRDB7.0.0 及原 revision/manifest hash。既有其他诊断 scope、公共 Release 编译/IPA 校验链保持原样，不借旧九项 UI/900 秒 gate 放行。

## 窄诊断依据，不是产品修复证明

旧 run `41639270133` attempt1/full 已失败：166 中 160 passed、1 failed、1 unfinished、4 unexecuted；UI 为 8/1/1/1，Canvas3 未执行。Core25、Domain107、Block6、measurement1、Host13 通过，不能替代本批验证。旧执行 UI 原生 exit=-9、900 秒超时，同时保留原断言失败；附件导出 exit64，结果包 metadata 读取失败。没有该提交的新 IPA。

原 `showTools` 仅以 expand/collapse 可点击判定工具栏。大字时已展开的滚动 tray 可让 collapse 在屏外，而 directory/settings 实际可见；helper 可能误判为隐藏并再次点击正文，把本来可见的 tray 隐藏。源码逻辑与原日志一致，但未以录像/真机几何证明产品根因，不能声称已修复真机。

本批仅让 helper 检查 expand、directory、settings、collapse 的 exists、isHittable、非空 frame，并证明中心位于 screen；tray 控件还必须在 screen 与 dockScroll 的交集。初始 guard 和首次触碰后的 predicate 共用该判断。保留原最多两次正文触碰、共享20秒 deadline；最后用既有 `revealDockControl(settings)` 在同一剩余预算内局部滚动，不新增触碰或重置 deadline。原 expand/reveal helper、全部测试正文及断言不动。

原 UI 调用约162.122秒启动，9个已结束 case 合计661.338秒，未结束第10项约76.49秒，共约899.95秒；这是调用壁钟预算，不是 CPU 或性能结论。批准 UI 整组900→1200秒、工作流 UI 步骤18→23分钟（留3分钟导出余量）；job60分钟、Host480秒/步骤12分钟、单例180秒、open20秒、dock10秒、exit10秒、showTools20秒不变。增加整组余量不代表断言会通过。

## 单次执行与失败停止

协调端完成本地检查后，只普通提交/push 一次，运行一次既有 Task3 `full`、attempt1，选择25+107+6+1+13+11+3=166。全部真实原生通过才走原 Task3 的设备 Release/同 SHA unsigned arm64 IPA 校验链。成功后停止，不继续任务，不把模拟器结果说成真机通过。

若失败，仅以下窄条件可另运行一次同源码 `ios-build`、attempt1：

- `package_scope=bookmark-dock-da2f05a-exact8`；`host_validation_run_id` 为本批**新** full run ID，绝不能是旧 `41639270133`。
- 当前 main/manual/attempt1、workflow SHA、输入、唯一父提交、exact8、213→215、全部 tracked working/index/commit 字节一致；其余207条目不变。
- 上游同 SHA、main/manual、Task3 workflow398234793、attempt1、completed/failure；精确核对当前步骤名称（Host13、Run11），仅 UI step16 失败。准备/工具链/生成/依赖、Core25、Domain107、Block6、measurement1、Host13 和 evidence upload 均成功；Host-only步骤和 UI 后 Canvas/full gate/device/package/IPA upload 均跳过。
- 每组原日志、exit、provenance、计数/身份/选择必须一致，全部前置原生 case 真正 passed。完整 candidate hash map 与当前 checkout 一致，Host/UI source subset 必须完整且完全相等，不能接受任意非空子集。
- UI11 原始事件逐项保留 passed/failed/unfinished/unexecuted。只接受归属本 case 且源行真实为 XCTest assertion 的失败，或 receipt 证明1200秒原生 timeout/exit=-9，或全部UI通过但独立 attachment export 非零。编译、数据、Host、未知测试、跳过、连接/runner/工具失败不得绕过；纯附件分支仍不算 full regression passed。
- API artifact ID/run/SHA/name、size、SHA256 digest 绑定；全部 ZIP member CRC 读取，拒绝不安全/重复路径、符链、加密。压缩包≤256MiB、展开≤1GiB、单 member≤256MiB、成员≤20000；保留日志/JSON/exit每项≤64MiB、总≤128MiB。下载允许600秒，只读GET；CDN redirect 必须HTTPS白名单且不转发 Authorization。不安装、不增凭据/权限，读取失败即阻断。

新诊断脚本不运行任何原生测试，状态必须是 `qualification="TESTS NOT RUN"`、`tests_run=false`、`full_regression_passed=false`、`native_tests_this_run={status:"not run",executions:0,selection:[]}`、`physical_device_acceptance="not performed"`，`source_commit` 严格对应当前 SHA。保存完整上游失败分类和 case ledger，不伪造166通过。公共 packaging 保留规范名称 `YueJing-0.2.0.ipa`，不重打包/重签；诊断 artifact/交付目录与状态单必须明确 TESTS NOT RUN / full regression NOT PASSED。

不满足窄条件、任何编译/校验/打包失败立即停止，没有新 IPA 就明确报告没有。不得自动补丁、重提交/push、rerun、改 scope 或追加 probe。诊断 IPA 成功也停止，等待真机复现，不是正式发布。

## 本地检查与接口

`python3 -B scripts/check_bookmark_dock_recovery.py` 默认离线：从 git BASE 验证 App/Sources/其他 Tests 全部字节、UI 测试正文/断言及非目标 helper 冻结；核对可见 dock predicate、有限双触碰/共享deadline、1200/480/180及60/12/23预算；严格验证第八文件只改原第466行至 `else 1200`、label `host-480-ui-1200-approved-budgets`，其他字节完全等于BASE；逆向剥离新增 scope 后整个旧 ios-build 必须逐字相同；执行纯 synthetic 正反例。只输出 stdout，不发网络、不生成原生结果。

CI 专用互斥模式：

- `--device-repro-gate`：读取标准 `GITHUB_*`、`GITHUB_EVENT_PATH`，以及 `PACKAGE_SCOPE`、`HOST_VALIDATION_RUN_ID`、既有 `NATIVE_READ_TOKEN`；仅此模式可只读API。全部条件通过后排他写入 `artifacts/task3/bookmark-dock-exact8-gate.json` 与 `artifacts/verification-status.json`。
- `--fixed-dependency`：依赖解析后核对既有 `artifacts/task3/dependency-resolution.json` 的官方固定 revision/manifest，绑定当前诊断状态，写入 `artifacts/task3/bookmark-dock-fixed-dependency.json`；不解析/安装依赖。

本地 Python AST、合成反例、shell/YAML 静检都不是 Swift 编译、原生 XCTest、首绘或真机验收。原生计数、设备编译、IPA校验及真机结果必须分别报告；本文件不预先宣布任何新 native run 通过。

## 真机安全复现清单

交付前在新独立诊断目录保存原 IPA、SHA256、source SHA、上游 run/attempt、真实 ledger、验证状态和打包校验收据。用户先确认现有书库/进度已有可恢复备份；不要卸载、清数据或用私人原书进行破坏性测试。无把握保留数据时暂停安装。

仅用可丢弃合成 TXT，在 iPhone13/iOS16.6.1 记录系统/字体档位、App版本及 source SHA：正常字号和大字分别导入→滚动→显隐dock→目录→书签新增/跳转→局部滚动设置→删除测试书签→退出复开/真实进程重启后位置恢复。重点看大字 tray 部分可见时 directory/settings 是否可操作，退出后旧回调是否影响新阅读会话。测试只删合成书签/合成书，不动个人资料；若失败保留操作顺序与不含私人内容的截图/录像，停止并反馈，不自行重跑云测试或再改源码。
