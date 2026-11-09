# EPUB reopen/jump 定向发布（0.2.6 / build 8）

基线 `7888b00fe13220775d7bd53045858cda298b08b6`，入口为既有 Task3 的 `validation_scope=epub-reopen-22` / `epub_freeze` 作业。本轮用户批准发布、验证及 IPA；范围内失败允许修复后普通推送及重新编译。每次使用新的 dispatch（attempt1），保留失败证据，禁止增大时限、弱化断言或自动降为 diagnostic。

## 精确范围与计数

BASE 到候选 HEAD 必须恰好改动 `run_epub_freeze_validation.py:ALLOWED` 的20路径：原13业务/测试/脚本路径加本轮7基础设施路径，无新增、删除或符链；版本只允许 0.2.5/7 → 0.2.6/8。重试仍检查整个 BASE→HEAD 差异，而非只检查最后一次提交。

全模块 inventory 从214增为222个函数身份（Domain146→154）；新增8函数之一有 `symlink: Bool` 的 `[false, true]` 参数，因此全模块展开为223次执行，Domain155次。这里只运行22个函数身份、23次执行，不运行/不声称其余200项通过。

### Domain：18函数 / 19次执行

- `EPUBLibraryTests` 13函数：原资源/磁盘缓存复开、8个新增 warm workspace/并发归属/损坏及符链/完整metadata/失败取消close/transfer清理/deinit回归，加 duplicate保进度、commit前取消、commit后取消、失败workspace清理。
- `EPUBProgressTests` 全4函数：位置单位/版本/UTF16、readiness和递增序列、旧navigation/新session/closed回调、typography epoch和设置。
- `EPUBCompatibilityTests.epubCompatibilityEPUB2DoctypeImageWebPImportProgressSurvivesReopen` 1函数。
- 精确函数名固定在 runner 的 `SELECTED_FILES`；不选迁移、cover、安全解析等无关用例。

### Host：3函数，各独立调用

1. `epubWebKitLoadsValidatedLocalResourcesAndRestoresTextNodeUTF16Position`
2. `epubCompatibilityWebKitLoadsStaticImagePageAndRestoresAnchor`
3. `epubTypographyReflowRestoresAnchorAndGatesStaleNavigationCallbacks`

每个独立 Host 调用仍480秒，单case180秒，迟到通过无资格；不选择cover/security。Domain480秒、UI480秒、单case180秒、模拟器准备120秒均不扩大。

### UI：1函数

`testEPUBShelfCoverAndDirectoryCrossChapterNavigation` 覆盖目录、跨章、同进程退出复开，并比较保存前后的path/node/offset。初查发现旧case只退出；协调端已在同一批准测试路径补足warm reopen，基础设施未编辑测试断言。`scope` 仍拒绝缺少exit→open或以terminate/launch替代同进程复开的候选。

## 真实证据与正式发布门

- Domain复用 `run_epub_reading_validation` 的未宿主scheme/effective settings机制；Host/UI仍用真实App及原scheme核验。共享同job中间产物，不复用跨run通过记录。
- Swift Testing汇总计数为函数声明数。参数化函数必须有正确 `(symlink:)` 身份、唯一父start/pass、false和true各一次原始argument事件，且位于父事件之间；无失败/跳过/未知事件。
- 参数化日志签名仅在内存中适配既有审计器；保存原始日志SHA、原行号/行文及参数事件，不重写日志、不伪造子case的console finish。
- 实际xcresult必须存在，`xcresulttool get test-results tests` 中两个Bool参数叶节点均Passed；父级green不能替代参数完成证据。保存原始JSON，正式门重新从同bundle提取并比较，未知格式拒绝放行。新增格式解析目前只有离线合成测试，尚待Xcode16.4实际输出验证；必要修复须保留失败证据且不弱化条件。
- selection/execution/counts/source/run/attempt/destination/command/timeouts均重算；所有组选定原生执行均通过才生成 `EPUB_REOPEN_22_TARGETED_NATIVE / EPUB_TARGETED_NOT_FULL`。
- 当前 `epub-freeze-diagnostic` 明确禁用并移出选项；其他历史diagnostic仍绑定旧源，不授权本候选。无自动fallback。
- `validate_task3.py` 的 package/IPA入口再次调用严格release gate；原arm64/iOS16.6/未签名、设备依赖图、GRDB/ZIPFoundation许可与资源、WebKit linkage、IPA provenance及逐文件payload字节门保持。
- 新scope默认选中且与原全量作业互斥。只在所有门成功后上传正式IPA；失败上传证据，不交付正式IPA。

## 离线检查及后续执行

```powershell
python -B scripts/check_epub_freeze_validation.py
```

自检覆盖选择/参数事件/xcresult负例、scope路由与边界、artifact/provenance/release/IPA字节拒绝；临时夹具放会话scratch。`offline_checks_passed` 是合成门禁测试，不是Swift测试；`release_source_ready` 单独报告UI源码形状合同，不能将其当成原生通过或发布资格。

协调端重跑离线检查、核对精确20路径，普通提交/push后只调既有 `task3-validate.yml`，显式传 `validation_scope=epub-reopen-22`。云端顺序：scope→固定工具链/依赖→Domain→三个独立Host→UI→原生gate→真实设备Release→依赖门→打包→IPA字节核验。失败可在本批白名单修复并新dispatch，不覆盖/隐藏旧失败。

交付 `YueJing-0.2.6.ipa` 时核对artifact摘要/大小/安全ZIP、同SHA与run及IPA摘要，说明实际编译结果、修复次数和22身份/23执行的区别。不声称完整回归、进程重启、RSS、秒开或真机已通过；真机覆盖安装保留原书及进度，重点测同进程退出复开、目录快速跨章及位置恢复。
