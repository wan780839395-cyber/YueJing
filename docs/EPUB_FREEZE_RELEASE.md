# P0观测与滑动候选发布：0.2.8 / build10

## 本批批准范围

基线 `51f5e113295e98a32289335f9dcab0cbc2323f53`，既有Task3/epub_freeze作业，scope `epub-p0-9`。用户批准一次普通公开推送、一次定向云验证及独立设备构建；测试未全绿但设备/IPA字节校验合格时允许交付明确标注的诊断IPA。不自动追加推送、dispatch或rerun。

精确18路径由 `run_epub_freeze_validation.py:ALLOWED` 锁定；新增仅 `App/EPUB/EPUBRuntimeTrace.swift` 与 `Sources/ReaderDomain/EPUB/EPUBOpeningTimings.swift`。project.yml只允许0.2.7/build9→0.2.8/build10。私有文件、Skills、原书、录屏、scratch及artifact不公开。

产品内容是上一轮滑动止损＋P0观测：
- 后方追加无位移时不发scrollTo；拖动/惯性中前插或裁剪暂缓，停稳后续做；保留双向滚动、真实位置、窗口限制和session/epoch权限。
- EPUB开书固定阶段计时；原生和JS分别有界记录预载、图片、提交、运动及程序滚动。现有诊断页按需读取，无书名、路径、正文或内容摘要，不逐帧发布到SwiftUI。
- 原书SHA、逐资源完整性、独占目录归属、保存与取消语义保持。P1预载调度与P2渲染热复用尚未实施；本包不承诺卡顿消除或秒开。JS就绪/采样耗时不代表真实首绘/FPS。

## 最小充分选择：9声明 / 10次展开执行

- Domain3：`epubOriginalArchiveAndValidatedResourcesSurviveReopen`、`epubWarmReopenTransfersFolderWithFreshSessionPositionAndPreferences`、`epubDamagedClosedWorkspaceFallsBackWithoutTrustingMtime`。最后一个Bool参数false/true，共4次执行；覆盖冷/热资源与新增计时、损坏拒绝/回退。
- Host3：资源加载/UTF16恢复、静态图片页、排版与过期导航拒绝；既有复合用例还含双向跨章、拖动/惯性保护和新诊断快照断言。
- EPUB UI3：`testEPUBShelfCoverAndDirectoryCrossChapterNavigation`、`testEPUBProgressSurvivesExitAndProcessRelaunch`、`testEPUBTypographyNoCoverFallbackAndTXTIsolation`。覆盖目录/跨章/同进程重开、进程重启恢复、设置与TXT隔离。
- 完整清单222声明/223次展开不变；本批不运行其余213次展开执行。全部15项UI身份仍显示，未选的12项明确not_selected。
- 本地23组Chromium和16项synthetic/static仅在产品JS/CSS摘要匹配时引用；不是本批原生执行或真机验收。

## 执行和交付

1. 单项独立xcodebuild与证据目录。失败/超时后继续无依赖的后项，取消及公共前置失效仅阻塞受影响路径；保留准确passed/failed/timed_out/error/blocked/not_run/not_selected状态。
2. 480秒调用、180秒单例、120秒boot及60分钟job不变；不放宽断言、不自动重试。旧UI超时仍是历史失败，不能预先声称已解决。
3. 设备Release与模拟器测试独立；测试失败不阻断成功设备产物校验。编译失败或IPA完整性失败不交付。
4. 严格release_gate仍要求本批10次真实通过、原始日志/xcresult参数叶/设置/命令/source/run全部匹配，不以汇总或旧提交结果替代。
5. 本批显式输入 `allow_unqualified_ipa=true`，与原dispatch事件及环境绑定；诊断交付不绕过源码、工具链、依赖、架构、资源、许可证和实际Release/IPA字节校验。
6. 未全绿包保留 `DEVICE_DIAGNOSTIC_ONLY / UI_NOT_QUALIFIED`，workflow可以保持failure。未知执行数保留null并列known/unknown，不以计划10次伪造完成数。
7. 固定macOS15、Xcode16.4/Swift6.1.2、XcodeGen2.46.0、最低iOS16.6及现有依赖/权限。arm64 unsigned、设备WebKit linkage、Swift SDK证明、资源/图标/许可证和IPA字节门保持。
8. 下载核验artifact摘要、ZIP CRC/安全路径与成员哈希，再独立核验源身份、测试结果及实际Release二进制；交付副本再次核对摘要。结果只存ignored artifacts，不为结果再次推送。

离线入口 `python -B scripts/check_epub_freeze_validation.py` 只验证选择器、门控和故障续跑，不计原生通过。

## 真机基线

使用既有TrollStore覆盖安装，保留原书/进度/书签，不卸载清库。原图文段分别慢拖、快速甩动、惯性中回滑、点击停惯性；返回书架重开后读取“排版→诊断与耗时”。分别分析完整校验、重建/排版、图片等待和预载取消。真实首绘及Web合成帧时间仍需原生/真机证据，不把本地通过或成功出包当作用户问题已解决。
