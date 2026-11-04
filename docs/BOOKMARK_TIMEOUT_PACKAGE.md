# 暂停修复：当前源码书签超时诊断 IPA

## 授权与唯一范围

用户批准原文：**“批准暂停修复并诊断出包”**。暂停功能和测试修复，使用当前源码制作诊断包；这不是“无法修复”的判断，也不是已知 Swift 编译失败。

- scope：`bookmark-timeout-fe09e95-exact3`。
- 唯一父提交：`fe09e95cd30a6326179d740cc0b9248a0a532735`。
- exact3：仅修改 `.github/workflows/ios-build.yml`，新增 `scripts/check_bookmark_timeout_package.py` 和本文。
- 父树 217 条、子树 219 条；其余 **216** 条 mode/type/blob 不变；工作树、index 与提交一致。
- **不修改 App/Sources/Tests、runner、事件解析器、inventory、依赖或超时预算，不执行原生测试。**
- 主端负责一次普通 commit/push、一次既有 `ios-build`（workflow ID `397959305`）dispatch attempt1、收集与交付；失败即停，不自动修复或重跑。脚本不提交、不 dispatch、不构建、不生成 IPA。
- 诊断包仅供用户后续真机测试，不是正式发布或 full 验收。未签名 IPA 需用户已有签名安装方式，不新增证书或凭据。

## 固定上游：保留失败事实

仓库 `wan780839395-cyber/YueJing`，Task3 run **41767851984 / attempt1**，workflow ID `398234793`，`.github/workflows/task3-validate.yml`，`main / workflow_dispatch`，source 为上述父提交，终态 **completed / failure**。

| 原生组 | passed | 原解析 unfinished | 未执行 | native exit |
|---|---:|---:|---:|---:|
| TXTCoreTests | 25 | 0 | 0 | 0 |
| ReaderDomainTests | 107 | 0 | 0 | 0 |
| TXTBlockDecoderTests | 6 | 0 | 0 | 0 |
| ProcessingReuseMeasurementTests | 1 | 0 | 0 | 0 |
| YueJingHostTests | 13 | 0 | 0 | 0 |
| YueJingUITests | 10 | 1 | 0 | 65 |
| YueJingCanvasTests | 0 | 0 | 3 | 未执行 |
| 合计（166 选择） | **162** | **1** | **3** | **full failure** |

**两套计数同时保留，不混写：**

- 原始事件解析：`passed=162, failed=0, skipped=0, unexecuted=3, unfinished=1, ambiguous=0`。UI `parser_complete=false`，唯一 unknown 为原日志 **1706** 行。
- 基于原始 XCTest 超时行的补充分类：`passed=162, failed=1, timed_out_cases=1, skipped=0, unexecuted=3, ambiguous=0`。`timed_out_cases` 是 failed 的子集，不另加一例。
- 唯一超时例：`testBookmarksPersistIsolateAndJumpAfterRelaunch`，**单例 180 秒**。UI execution receipt 为 `native_exit=65, timed_out=false`，不是 1200 秒总进程超时。
- 不修改日志/解析器，不造普通 failed/passed finish，不将 unfinished 悄悄改成成功，不推断整段持久化、隔离、重启跳转已完成。
- `testBookmarksAccessibilityCloseAndConfirmedDeletion` 已通过 **97.148 秒**，包含实际新增时命名、重命名、跳转、取消/确认删除及大字号操作；14 个 Domain 和 4 个 Host 书签例已通过。仍不能替代真机验收。
- 上游 Simulator App/Host/UI 编译成功；实际模拟器为 SE3 / iOS18.5 / arm64，不是用户 iPhone13 / iOS16.6.1。Canvas3、上游 device Release 编译和 IPA 未执行。

API 步骤：1–12 success，13 skipped，14 success，15 skipped，16 failure，17–20 skipped，21 success，22 skipped，44/45 success。门禁检查唯一 job、全部步骤集合、名称、状态与结论，拒绝其他失败、取消、额外步骤或 attempt。

## 原始证据与固定 SHA256

只读来源：`artifacts/bookmark-add-name-native-c7aec22-01/COLLECTION`。不使用旧汇总文件代替原证据验证，不修改或重新封存历史目录。

- 唯一 artifact ID：`13295545933`。
- 名称：`task3-evidence-41767851984-fe09e95cd30a6326179d740cc0b9248a0a532735`。
- ZIP：**164537177 bytes**，SHA256 `3354263403f81ed253fc0ef3c796982a1ae5bcdb31a6fb4c9759eb06d18d4d45`，无 IPA。

下表路径以 `COLLECTION/evidence/` 为根：

| 文件 | bytes | SHA256 |
|---|---:|---|
| `reading-ui-native/YueJingUITests.log` | 328858 | `7413dbed3c9ae6d58d33630e2f9b980e01f0811b688e1e1e595950117f43308e` |
| `task3/candidate-sources.json` | 31628 | `aa365be5735455ca2d40b3b966d8192267dc604aede7d721b075190a2ec13298` |

原 UI log 共 **4847** 行：778 行大字号例 passed，779 行长流程 started，1706 行 `exceeded execution time allowance of 3 minutes`，1835 行 XCTest framework restart，4842–4843 行 Failing tests 明列该长流程。1706 行模板中的 `may have hung` **不构成 App 卡死诊断**。框架在同一次 xcodebuild 中恢复执行剩余用例，不是代理手工重跑。

门禁核对 ZIP hash/size、全部成员 CRC、2215 文件成员路径集合、所用原始解压证据字节、完整父候选 **160** 文件 SHA256（当前候选161）。逐组重新解析原生日志并核对 selection/counts/execution/source-hashes、provenance、exit-code、声明用例及原计数 schema；拒绝额外 Canvas/full/Host-only/IPA 或成功 UI counts。

## 四种 CLI 模式

在仓库根执行；四模式互斥：

```text
python -B scripts/check_bookmark_timeout_package.py --self-check
python -B scripts/check_bookmark_timeout_package.py --offline-evidence artifacts/bookmark-add-name-native-c7aec22-01/COLLECTION
python3 -B scripts/check_bookmark_timeout_package.py --package-gate --source "$GITHUB_SHA" --run-id "$HOST_VALIDATION_RUN_ID"
python3 -B scripts/check_bookmark_timeout_package.py --fixed-dependency --source "$GITHUB_SHA"
```

- `--self-check`：合成正/负向控制，只读，不联网、不调用 Git、不启动 native test/build、不写文件。
- `--offline-evidence COLLECTION`：读取 terminal-run/jobs/artifacts JSON、原 ZIP 与解压证据，走云端同一 `validate_evidence` / `evidence_gate`，再比较本地父候选内容。新增 workflow 块可逆去除后须匹配父 hash。只打印 JSON；不声称已验证未来云端提交/index/API。离线模式拒绝 `--source/--run-id`。
- `--package-gate`：**必须**带 `--source` 和 `--run-id`；要求 `GITHUB_ACTIONS=true`、标准 GitHub 身份/event 环境、`PACKAGE_SCOPE`、`HOST_VALIDATION_RUN_ID=41767851984`、既有 `NATIVE_READ_TOKEN`。先验证 source/main/ref/workflow SHA/attempt1/唯一父/exact3/index/工作树，再只读 GET 固定上游证据，全部通过后才写资格状态。
- `--fixed-dependency`：**必须**带 `--source`，不接受 `--run-id`。云端公共依赖解析后读取 `artifacts/task3/dependency-resolution.json`，核对官方 `https://github.com/groue/GRDB.swift.git`、GRDB7.0.0、revision `4de97e6903d29697caae1179cdef8479c64c2639`、manifest SHA256 `8140971be34f0cc80ef71e96a2b709ff98358a5c7412fe2e2a1687a4cb21867a`，并验证同 source 的诊断状态。

`workflow_blocks()` 返回两块精确允许内容，主端应直接据此维护 workflow：

- `# BEGIN BOOKMARK TIMEOUT PACKAGE GATE` / `# END BOOKMARK TIMEOUT PACKAGE GATE`，步骤名 `Require the fixed bookmark timeout evidence and exact three-file package scope`，位于公共 toolchain 前。
- `# BEGIN BOOKMARK TIMEOUT PACKAGE DEPENDENCY` / `# END BOOKMARK TIMEOUT PACKAGE DEPENDENCY`，步骤名 `Require fixed official GRDB for the bookmark timeout diagnostic package`，位于公共 `validate_task3.py resolved` 后、Release settings 前。
- 两步仅 `if: inputs.package_scope == 'bookmark-timeout-fe09e95-exact3'`。只新增一个 choice 与一个 case whitelist 项。
- 去除两块**完整精确内容**和 scope 两处添加后，workflow 必须逐字等于父版本。marker 内加命令、少 CLI 参数、改条件、重复块、改公共链或旧 scope 都拒绝。

复用 `check_bookmark_dock_recovery` 的参数化纯 helpers 及原始事件解析函数，不调用历史 entrypoint/旧 source scope gate，不改其 globals。网络仅 HTTPS GET、JSON≤8MiB、ZIP≤256MiB；签名 blob 重定向不转发 Authorization。ZIP 展开≤1GiB，CRC 读取全部成员、不解压落盘，拒绝不安全路径/重复/特殊文件/加密。API 失败、过期或证据不匹配即阻断；离线通过不保证未来 API 可用。

## 状态与输出 schema

`artifacts/verification-status.json`：

- `source_commit` 为新提交，`app_candidate` 为固定父提交；`qualification='TESTS NOT RUN'`、`tests_run=false`。
- `native_tests_this_run={status:'not run',executions:0,selection:[]}`、`native_execution=[]`。
- `physical_device_acceptance='not performed'`、`full_regression_passed=false`、`formal_release=false`。
- `prior_validation_run/attempt/source_commit` 固定上游；`prior_counts` 与 `prior_raw_parser_totals` 均为原解析 162/0/3/unfinished1；`prior_classified_totals` 为补充 162/1/3（timed_out_cases1）。
- `prior_validation_failed=1` 明确指补充超时分类，`prior_raw_unfinished=1` 保留原解析；`prior_failed_cases` 和 `prior_timeout_evidence` 明列用例及证据行。
- `prior_task3_tests_rerun=false`，不设置 `prior_full146_passed=true`；source receipt 为 `bookmark_timeout_exact3_gate`，含完整 tracked/candidate maps、上游身份、逐例原始事件和分类说明。

云端还输出：

- `artifacts/task3/bookmark-timeout-exact3-gate.json`
- `artifacts/task3/bookmark-timeout-candidate-sources.json`
- `artifacts/task3/bookmark-timeout-upstream-{run,jobs,artifacts}.json`
- `artifacts/task3/bookmark-timeout-fixed-dependency.json`
- `artifacts/task3/bookmark-timeout-prior/`：只保留所用原生日志、candidate、counts/selection/execution/source-hashes/exit-code，不复制完整164MB ZIP、attachments 或 xcresult。

两门禁均输出 step summary。公共链合并状态至 manifest；最终 IPA 仍须主端独立核对 source/hash、官方依赖、构建 App 与 IPA 内字节、签名状态、SHA256SUMS，再交付原始未重打包 IPA。本文不声明云端构建或 IPA 已成功。

## 未解决项与真机待测（全部未执行）

当前未解决：长书签流程单例180秒超时的具体原因、真机表现和整段重启持久化/跨书隔离/跳转可靠性；Canvas3未执行、完整回归未通过。不要把诊断出包当成修复完成。

**先备份；不要卸载、清空或破坏真实书籍。** 使用单独合成测试长书 A、短书 B，记录设备型号/iOS、字体、步骤、耗时及录屏。可复用既有 `artifacts/iphone-only-repro-09c61b5/UITest-Long-A.txt` 与 `UITest-Short-B.txt`，不改原文件。长A SHA256 `7eba0501d0dcd66797ac92054b9212e3a6e14afca1c60fbdf063baec483c59c5`；短B SHA256 `7fe33027ff14de0b45d920219ea0baea6676e26a1c220e24601b546e4bd4561b`。

| 待测项 | 操作 | 预期结果 |
|---|---|---|
| 新增时命名 | A 阅读处打开书签，点新增，输入专用名称并确认 | 先打开名称编辑器，确认后只新增一条，名称正确 |
| 新增取消 | 换位置新增，输入后取消，再打开列表 | 不产生新书签，不改变已有书签或阅读进度 |
| 短距离/多个书签 | 在A多个可区分位置短滚动后添加不同名称 | 列表可滚动，项目可区分，操作区不挤压遮挡；同位置重复添加不产生重复 |
| 大字号操作布局 | 最大常用字号下重复新增、选择、重命名、删除 | 文字可读，键盘/安全区不挡关键按钮，操作区可触达 |
| 重命名 | 改名确认，再改名取消 | 确认持久化，取消保留原名，无额外书签 |
| 删除取消/确认 | 先取消删除，再确认删除选中书签 | 取消不删；确认只删目标，列表与操作区同步 |
| 点击跳转 | 逐一点击A内不同位置书签 | 到对应文本锚点，不误跳其他书签，列表正常关闭/更新 |
| 重启持久化 | 记录A书签/位置，正常离开并终止后重新启动 | 名称、数量、位置保留，书签可跳转；逐步记录耗时，不以180秒内完成自动判通过 |
| 跨书隔离 | 打开B添加书签，往返A/B并重启 | 两书书签不串用，删除/改名不影响另一书 |
| 失败与进度保护 | 只在测试副本上遇到无法跳转时记录前后进度，不破坏真实文件 | 给出明确反馈，不误覆盖有效进度、不崩溃；无法安全触发则记未测 |
| 相关回归 | 列表关闭后阅读滚动、目录/搜索跳转、前后台切换、旋转及常用字号 | 操作正常、进度一致，不残留遮罩或不可点击区域 |

任何卡顿记录停在哪个动作、多久、是否仍可点击/滚动、重启是否恢复；区分测试时限与 App 无响应。手工结果需用户回传，不能由模拟器已通过用例代填。

## 本地实现验证记录

- 新脚本 `--self-check`：**16 正向、157 负向通过**，包括 exact3/source、全部上游步骤、逐例事件、唯一 unknown 超时、额外失败/跳过/重复/伪造 finish、原生退出码/预算、证据字节、ZIP路径、固定依赖和诊断状态。
- 真实 `validate_evidence`：**通过**；原ZIP固定hash、2215文件成员、父候选160、原生收据和162/unfinished1/unexecuted3重算均通过；补充分类162/timeoutfailed1/unexecuted3。
- 真实证据内存变异：**78 负向通过**，包括固定证据破坏、全部五组 counts、Host/UI selection/execution/source maps、额外下游证据、父map漂移、超时/unknown/重复/伪造finish、ZIP破坏。未改原证据。
- Python AST 解析通过；在禁止 socket/subprocess/写文件/读取 private3 的 audit hook 下重复验证通过。无网络、Git、native test/build 或历史 entrypoint 调用。
- 实施时主端 workflow 两条新调用尚未携带本节规定的 CLI 参数，实际完整 `--offline-evidence` 因精确 workflow 块不符而拒绝。仅在内存补入这两条参数后的完整离线路径通过，**不冒充磁盘 workflow 已通过**。主端补齐后须再跑真实 CLI 与 workflow 逆向比较；云端 source/index/API/依赖和最终IPA仍待主端执行。
