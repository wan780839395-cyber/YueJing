# EPUB 定向验证：独立设备构建与显式诊断交付（0.2.6 / build 8）

## 当前范围

本轮保留 UI 全3项及逐项 continue：单项失败保留失败退出码、不重试，继续不受影响环节，最后汇总。**严格正式资格仍须25次真实通过；诊断交付不是全绿，也不代表UI合格。** 用户已再次批准此前发布/IPA范围及失败可修复后推送重编译；本说明不记录任何尚未发生的云端成功。

入口仍为 Task3 `validation_scope=epub-reopen-24` / `epub_freeze`；新增 boolean `allow_unqualified_ipa`，默认 `false`。只有本次 dispatch 显式 `true` 才允许设备完整性通过但原生资格不通过的 `DEVICE_DIAGNOSTIC_ONLY / UI_NOT_QUALIFIED` 包。保留基线 `7888b00fe13220775d7bd53045858cda298b08b6`、累计精确20路径、0.2.6/build8。此次只改既有workflow、runner、自检、validate_task3及本说明五文件，不改产品/Swift测试/版本。

### UI 漏项核对

源码 `EPUBFlowUITests` 已有3项，原 `epub-reopen-22` 仅选第1项，且没有完整逐项展示。本轮不改Swift断言，补入原有第2、3项：

| 用例 | 覆盖 |
|---|---|
| `testEPUBShelfCoverAndDirectoryCrossChapterNavigation` | 底部工具点击、目录/章内锚点、分页/连续跨章、同进程退出复开坐标 |
| `testEPUBProgressSurvivesExitAndProcessRelaunch` | 退出并终止进程后的进度恢复、当前章目录状态 |
| `testEPUBTypographyNoCoverFallbackAndTXTIsolation` | 阅读设置、无封面占位及TXT隔离；与上轮设置面板回归直接相关 |

汇总同时展示 `YueJingUITests` 的全部12个独立TXT/通用UI用例，明确标为 `not_selected`，不自动扩大到全量执行、不计通过。

### 选择与计数

- Domain仍18函数：`EPUBLibraryTests`资源/复开/所有权/并发/损坏/取消/清理13项，`EPUBProgressTests`4项，EPUB2图片/WebP复开兼容1项。
- Host仍3函数：本地资源与UTF16恢复、图片页恢复、排版与旧回调隔离。
- UI由1增为完整EPUB3项。
- 共24个函数身份；Domain中Bool参数`false/true`展开两次，合计25次执行。
- 全清单仍222身份、223次执行；其余198次本轮未选择。不改测试身份、不删除断言。

## 执行与展示

`run_epub_freeze_validation.py run-all --destination ...`：

1. 一次核对固定工具链/依赖、模拟器和本批source/run身份。公共前置不满足时停止无意义调度，全部未开始项目显示阻塞；不是给每项重复探测失败环境。
2. 每个声明独立调用xcodebuild、独立selection/execution/log/xcresult/counts目录（domain-1…18、host-1…3、ui-1…3）。参数化声明内仍核对两个Bool结果。
3. 单项准备/编译/断言/证据失败或超时均记录 `failure.json`，继续下一项，不自动重试。当前用例内部仍保持 `continueAfterFailure=false`，避免前提失败后继续点击错误界面；原tearDown清理保留，下一个UI独立启动。
4. 原生输出直接写日志，不使用可能被子进程占住的PIPE；macOS独立进程组在超时/退出时清理。单项原生调用480秒、测试180秒、boot120秒、作业总60分钟不增大；取消/总预算终止时剩余项目诚实标未执行。
5. 每项后更新 `artifacts/task3/case-results.json` 和 `.md`。Actions `if: always()` 汇总步骤即使前置或测试失败也展示全部选定项及完整UI清单。状态区分 passed/failed/timed_out/error/blocked/not_run/not_selected；保留失败退出码，不只展示已通过项。
6. 有任何失败/阻塞/缺失时run-all最终非零退出。工作流不使用 `continue-on-error` 或 `|| true` 把整轮刷绿。身份或源码漂移与主动取消是调度中止条件，不吞掉继续运行。

逐项Markdown/JSON仅为诊断展示，标记 `DISPLAY_ONLY_NOT_RELEASE_QUALIFICATION`。正式 `qualification()` 仍重新读取每项原始事件、执行回执、实际xcresult、参数叶、有效设置及source/run/destination/command/hash，拒绝任何failure或调度错误记录；全部25次通过才产生 `EPUB_REOPEN_24_TARGETED_NATIVE`。

## 发布与设备门

- `scope` → `toolchain` → `dependencies` 为共用前置；`device` 使用原Release命令和原始exit记录，先于模拟器执行。`simulator` / `boot` / `tests` 不依赖device成功；device失败仍继续这些独立环节。测试或模拟器失败不阻止已成功device的打包检查。
- `native_gate` 始终保留严格 `qualification()` / `release_gate()`，25次通过才允许正式标签；不以失败汇总替代证明，不使用continue-on-error刷绿。`simulator_linkage`仍属正式交付要求；设备WebKit linkage始终强制。
- `package` 独立调用 `package-gate-epub-freeze` → 原package_ipa → `verify-ipa-epub-freeze`。前两级source/toolchain/dependency/device保护失败绝不诊断放行；所有arm64/iOS16.6/未签名、依赖图、GRDB/ZIPFoundation许可证资源、WebKit与IPA逐文件字节门保留。
- 许可绑定原始 `GITHUB_EVENT_PATH` 的inputs、job环境 `ALLOW_UNQUALIFIED_IPA`、scope回执中的 `allow_unqualified_ipa` / `dispatch_event_sha256`；再次读取scope时完整比较。不得运行中改环境从false变true，也不得跨scope/SHA/run借用许可。
- `final_summary` 使用 `always()` 写 `delivery-summary.json`，含source/run/attempt、各step outcome及package qualification。已校验IPA上传条件仅为 `!cancelled() && steps.package.outcome == 'success'`；测试失败的工作流仍失败，即使诊断IPA可交付。
- UI进程重启用例加入不等于其已通过；首绘/RSS/秒开、真机原书仍独立验收。覆盖安装，不清库/删书/重导入掩盖问题。

### 独立package回执与审计字段

`artifacts/task3/epub-freeze-package.json` 只在设备门及所有IPA字节检查完成后新建；`ipa-verification.json.native_evidence` 内嵌相同资格。原 `epub-freeze-gate.json` 仍为严格原生资格，可缺失/失败，不为诊断伪造通过回执。

- `qualification`：严格通过为 `EPUB_REOPEN_24_TARGETED_NATIVE`，否则仅显式许可下为 `DEVICE_DIAGNOSTIC_ONLY`；对应 `coverage=UI_NOT_QUALIFIED`。
- `strict_native_qualification`、`diagnostic_reason`、`verified_passed`：非严格全过时verified_passed为null，绝不写25；完整资格仍逐项重读原始事件、xcresult、参数叶、设置和provenance。
- `native_tests_executed_this_run`：完整资格为25；部分执行无法精确计数为null。`known_executions` 单列可由原始成功链与本轮selection/execution严格绑定的执行数；`unknown_execution_groups` 明列其余项，不把计划25或部分执行写成0。
- `cases` 附24项真实状态及每项 `executed_count` / `execution_count_status`；`case_results_qualification=DISPLAY_ONLY_NOT_RELEASE_QUALIFICATION` 明确这不是正式通过证明。原case-results仍展示全部15项UI清单。
- `evidence_sha256` 绑定本地原始native证据、工具链、依赖、设备build日志/exit及scope；另有 `device_linkage_sha256`、`device_dependency_sha256`、`ipa_sha256`、`ipa_integrity=passed`、`verified_packaged_files`，并继承source/run/attempt及授权字段。

调用命令保持 `run_epub_freeze_validation.py scope/run-all/report/gate` 与 `validate_task3.py package-gate-epub-freeze/verify-ipa-epub-freeze`；新增内部 `delivery_gate()` 与 `complete_delivery()`，没有新增自动降级scope。仅构建提前，60分钟作业期限和30秒工具query、480秒case、180秒test、120秒boot预算不扩大；总预算/取消可能使后续package未运行，不能承诺必有IPA。

## 本地验证

```powershell
python -B scripts/check_epub_freeze_validation.py
```

保留原312项离线检查覆盖（仅适配被明确替换的路由与package入口），追加设备/UI失败互不阻塞、默认拒绝、显式true及防篡改绑定、source/device/linkage/IPA完整性失败拒绝、部分执行null/known计数及严格门不弱化。新增合成诊断包实际ZIP字节检查；仍不代表原生通过。

这些是离线检查，不是Swift/WKWebView/真机验证；Windows无法验证macOS进程组及真实Xcode重入行为。原生执行数必须单列为0，后续云运行再核验每项真实结果。
