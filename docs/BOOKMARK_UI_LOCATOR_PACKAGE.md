# 书签 UI 定位诊断 IPA：独立 exact3 门禁

## 授权与边界

用户批准原文：**“批准诊断出包并交付IPA”**。本批只允许以下三条路径变化：

1. `.github/workflows/ios-build.yml`（主端维护）
2. `scripts/check_bookmark_ui_locator_package.py`（新增）
3. `docs/BOOKMARK_UI_LOCATOR_PACKAGE.md`（新增）

固定 scope：`bookmark-ui-locator-c77853a-exact3`。唯一父提交为
`c77853a46d2d536a431944cca6f2b1af5454855a`；父树 215 条，子树 217 条。
只有 workflow 修改、脚本与本文新增；其余 214 条 mode/type/blob 完全相同。
**不修改 App/Sources/Tests，不修复定位器，不新增或重跑原生测试。**
这是通过既有 `ios-build` 公共链进行的一次独立诊断编译/打包资格，不是上游 full 门禁续跑、正式发布或真机验收。
提交、push、dispatch 和最终 IPA 交付由主端负责。

## 固定上游：失败必须保留

- 仓库：`wan780839395-cyber/YueJing`。
- run：`41749976876`，attempt `1`，workflow ID `398234793`。
- workflow：`.github/workflows/task3-validate.yml`，`main` / `workflow_dispatch`，source 为上述父提交。
- 终态：`completed` / **`failure`**；完整选择 **166**。
- 唯一 artifact：`13286472309`，名称 `task3-evidence-41749976876-c77853a46d2d536a431944cca6f2b1af5454855a`。
- 原 ZIP：`163905336` bytes，SHA256 `2c6bfb9203b94a2251b347cf41fb99056060ffaf8327ddaf3ee5270eb862ba85`；无 IPA。

| 原生组 | passed | failed | unexecuted | native exit |
|---|---:|---:|---:|---:|
| TXTCoreTests | 25 | 0 | 0 | 0 |
| ReaderDomainTests | 107 | 0 | 0 | 0 |
| TXTBlockDecoderTests | 6 | 0 | 0 | 0 |
| ProcessingReuseMeasurementTests | 1 | 0 | 0 | 0 |
| YueJingHostTests | 13 | 0 | 0 | 0 |
| YueJingUITests | 9 | 2 | 0 | 65 |
| YueJingCanvasTests | 0 | 0 | 3 | 未执行 |
| 合计 | **161** | **2** | **3** | **full failure** |

UI11 均有开始/结束事件，`timed_out=false`；全体 skipped / unfinished / ambiguous 均为 0。
仅以下两例失败，不能用任意 UI failure 代替：

- `testBookmarksAccessibilityCloseAndConfirmedDeletion`
- `testBookmarksPersistIsolateAndJumpAfterRelaunch`

API steps 9/10/11/12/14 成功，16 失败，17/18/19/20/22 skipped，21 成功；13/15 为父 workflow 的 Host-only skipped。
所有步骤名称、状态和 setup/cleanup 也检查；Canvas、full union、上游 device 编译与打包未执行。

## 原始定位证据，而非汇总推断

以下相对路径均以 `COLLECTION/evidence/` 为根；行号从 1 起。

1. `reading-ui-native/YueJingUITests.log:437-464`：大字号例点击 add 后，448 行试图 swipe `reader.bookmarks.list` **Table**，454 行报无匹配，464 行该例失败。
   `reading-ui-native/YueJingUITests-attachments/AA3F1983-0C90-483B-8998-0C3CDAADE872.txt:89` 实际为同 identifier 的 **CollectionView**；98 行“此位置已有书签”、108 行“书签已保存。”，121 行 rename 的 y=736，低于该快照视口底部 667。
2. 同一原 UI log `564-601`：564 行 add、578 行 rename 点击，584-592 行查找 `reader.bookmarks.name` TextField，593 行等待断言失败，601 行该例失败。
   `reading-ui-native/YueJingUITests-attachments/F952DE2E-E385-4B7F-B5F0-345940CFB29A:302,325` 有“重命名书签” Alert 和 placeholder“书签名称”、Keyboard Focused 的 TextField，**没有 identifier**。该附件原文件名没有扩展名，不得另猜 `.txt`。

固定原始 SHA256：

| 文件 | bytes | SHA256 |
|---|---:|---|
| YueJingUITests.log | 244872 | `95c1c93df2d59aa7eb71efc22bcbcb4549b8522b717357cc51b4ef2377edde4f` |
| AA3F1983…txt | 19143 | `a3f0ed0a2f33a370c6ffacc88d3f10ea6ccda3001195051730c1454d1ef432e3` |
| F952DE2E…（无扩展名） | 35479 | `f354d2f29a501586878a7002da6e42e9c36280f5c8175f713a89c3724433b903` |
| task3/candidate-sources.json | 31508 | `b4315d26ca105a7dbc998d35fa0695dfc46bdaae76c67ed64371e61389f17100` |

脚本核对固定字节/hash、错误位置与动作顺序，并解析全部组原始事件、selection/counts/execution、provenance、log hash 与退出码。
只复用 `audit_native_case_events.parse_events`，**不复用旧 full146 结论**，不修改原始日志或解析器。
上述证据只说明这次定位失败及已观察界面；不能证明持久化、隔离、跳转、删除流程已完成，也不证明真机行为。

## CLI 与函数接口

在仓库根执行（四种模式互斥）：

```text
python -B scripts/check_bookmark_ui_locator_package.py --self-check
python -B scripts/check_bookmark_ui_locator_package.py --offline-evidence artifacts/bookmark-repair-native-47e9c1f-01/COLLECTION
python3 -B scripts/check_bookmark_ui_locator_package.py --package-gate
python3 -B scripts/check_bookmark_ui_locator_package.py --fixed-dependency
```

- `--self-check`：合成正/负向控制，只读本地源文件，不联网、不调用 Git、不启动原生测试或构建，不写文件。
- `--offline-evidence COLLECTION`：读取固定 terminal-run/jobs/artifacts JSON 与原 ZIP，走和云端相同的 `validate_evidence` / `evidence_gate`；CRC 读取全部 2135 ZIP 成员，比较解压路径集合及使用到的原始证据字节。核对完整父候选 159 项 SHA256；本地新增 workflow 块可逆去除后比较父 hash。不会使用 `AUDIT-FINAL/summary.json` 推断通过。只打印 JSON，无网络或 Git 写入；明确不声称已验证未来云端 commit/index/source gate。
- `source_gate(env, state)`：纯函数，校验当前仓库、main/ref/workflow、dispatch attempt1、新 run 不同于上游、inputs 恰固定 scope/run、唯一父、exact3、214 未改条目及工作树/index/commit 一致。
- `cloud_state` / `workflow_gate`：仅云端 package 模式使用只读 Git，计算完整父159/current160 candidate 与全部217 tracked SHA256，拒绝额外候选/生产资源文件。去除唯一新增 choice、case 和两个**精确内容** marker 块后，workflow 必须与父版本逐字一致；不允许 marker 内偷偷增加命令、改条件或移动到公共构建之后。
- `--package-gate`：要求 `GITHUB_ACTIONS=true`、标准 GitHub 身份/event 环境及 `PACKAGE_SCOPE`、`HOST_VALIDATION_RUN_ID=41749976876`、`NATIVE_READ_TOKEN`。在工具链准备前从 GitHub API 只读取固定 run、attempt1 jobs、artifact 列表及原 ZIP；先 source gate 后网络，所有门禁成功才写资格状态。
- `--fixed-dependency`：仅云端，在公共依赖解析后读取既有 `artifacts/task3/dependency-resolution.json`，检查官方 GRDB `7.0.0`、revision `4de97e6903d29697caae1179cdef8479c64c2639`、manifest SHA256 `8140971be34f0cc80ef71e96a2b709ff98358a5c7412fe2e2a1687a4cb21867a`，并核对本次诊断状态。

工作流两块 marker 分别以 `GATE` 和 `DEPENDENCY` 结尾：
`# BEGIN BOOKMARK UI LOCATOR PACKAGE GATE` / `# END BOOKMARK UI LOCATOR PACKAGE GATE`，以及对应 DEPENDENCY 块。
新步骤必须严格 `if: inputs.package_scope == 'bookmark-ui-locator-c77853a-exact3'`；不改变旧 scope、公用编译、依赖验证、打包和上传逻辑。

网络复用已检查的 `check_bookmark_dock_recovery.api_read`：仅 HTTPS GET、既有 token，无安装或凭据回退；JSON 上限 8MiB，ZIP 上限 256MiB（足以容纳此 163905336-byte ZIP）。签名 blob 重定向仅限安全 HTTPS 主机，**不转发 Authorization**；ZIP 校验路径、重复名、特殊文件、加密标志、成员/展开大小和全部 CRC，不落盘解压。
如果 token 无读取权限、artifact 已过期、API 失败或证据不匹配，立即阻断；离线成功不代表未来 API 一定可用。

## 云端输出与交付资格

- `artifacts/verification-status.json`：`source_commit` 为新提交，`app_candidate` 为父提交；`qualification='TESTS NOT RUN'`、`tests_run=false`、`native_tests_this_run={status:'not run',executions:0,selection:[]}`、`physical_device_acceptance='not performed'`、`full_regression_passed=false`、`formal_release=false`。
- 保留 `prior_validation_run/attempt/source_commit`、真实 `prior_counts`（161/2/3、其余0）、`prior_failed_cases`；**不设置 prior_full146_passed=true**，不改上游 full failure。
- source/scope receipt 为 `bookmark_ui_locator_exact3_gate`，含全部 tracked/hash、完整父/当前 candidate map、上游身份、各例原始事件与固定定位说明；状态会由既有公共链合并到最终 manifest。
- `artifacts/task3/bookmark-ui-locator-exact3-gate.json`、`bookmark-ui-locator-candidate-sources.json`、`bookmark-ui-locator-upstream-{run,jobs,artifacts}.json` 和 `bookmark-ui-locator-fixed-dependency.json` 提供独立核查资料。
- `artifacts/task3/bookmark-ui-locator-prior/` 只保留所用原生日志/JSON/exit-code 与两份原始 AX 附件。**不重新上传完整163MB ZIP或上游 xcresult**。
- gate 与 dependency 都写 step summary，披露诊断、TESTS NOT RUN、非正式验收。最终 IPA 仍须独立核对公共链的 manifest、source/hash、SHA256SUMS 和打包字节一致性；门禁脚本本身不生成 IPA。

## 本地实现验证记录

- `--self-check`：**15 正向、135 负向通过**（身份/输入/父/额外改动/生产漂移、上游身份与全部步骤、166 事件计数、额外失败/未完成/skip/重复、退出码/超时、固定证据破坏、ZIP 路径、依赖漂移）。
- 真实 `--offline-evidence`：**通过**，父159项、2135 ZIP 成员、固定原日志/附件 hash，重算得到 **161 passed / 2 failed / 3 unexecuted / 0 skipped / 0 unfinished / 0 ambiguous**。
- 额外真实证据内存变异检查：**34 负向通过**，包括4份固定证据单字节损坏、五组 counts 各5项变异、额外 Canvas/full/Host-only/IPA、父候选 map 漂移；没有修改原始文件。
- Python AST 解析通过；在拒绝 socket/subprocess/文件写入的审计钩子下重复自检与真实离线验证通过。
- **没有执行网络、Git 操作、原生 test、构建或历史 entrypoint。** 云端 source/index/API/依赖步骤及最终 IPA 需主端提交 dispatch 后验证；本记录不是其成功声明。
