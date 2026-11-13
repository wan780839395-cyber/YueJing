# 阅读交互与作者字号：0.2.19 / build21 定向验证

## 当前最终复验范围（覆盖下方首轮计划）

两轮13项验证后，恢复时序与字号漂移修复已原生通过；第二轮11通过、2项打开就绪等待失败。产品/测试冻结在 `a493a37d641aa483c52da252d06944ab96edc858`。最后一次仅复验 `epubOpeningRouteStartsOnceAndObservesMountedPresentation` 与 `epubWebKitLoadsValidatedLocalResourcesAndRestoresTextNodeUTF16Position`，仍保持原超时和断言，独立编译设备Release及严格IPA完整性门。

本轮资格明确为2项定向新执行；另外11项是前一轮同产品/测试字节的通过观察，不写成13项同轮通过，也不把失败组的个别绿色事件写入机器复用资格。最终发布改动仅范围JSON、自检选择与本文；任何产品/测试漂移必须重新评估。若两项仍失败，停止追加重试，报告真实阻塞。下方13项为首轮范围和影响依据，保留历史。

## 批次身份

基线 `e98fb9f609a37f37ec646a3d8be41ccc467cd9c1`。本批承接阅读重开、滚动、目录切换、作者字号与局部UI修复；用户已批准执行验证、必要修复及IPA编译。本文是范围合同，不是原生通过声明。

沿用既有 Task3 `validation_scope=epub-author-layout`，`build_ipa=true`、`allow_unqualified_ipa=false`、`prior_validation_run`为空。固定原工具链与依赖，不扩权、不新增付费规格。每轮独立记录提交、run、attempt、失败日志与产物；不把旧20项资格用于本候选。

## 产品范围

- 原始排版70%–180%文字比例：基于原计算字号/行高，保留作者字体、字重、层级、CSS和文字坐标，100%撤销覆盖；新邻章、冷暖重开和模式切换保持比例及锚点。
- 已加载字体保留其解码对象，不反复重装；旧URL仍不具有新session/epoch请求权限。
- 自然跨章保留原生触摸目标，但导航/保存仍受ready和会话权限门控；明确目录复用使用短暂旧帧保护，ready或失败后清理。
- 固定阶段超时诊断与统一失败撤权；不延长15/12秒预算。
- 移除阅读器html/body重复边距；作者相对尺寸继续按其CSS语义重排，不承诺复杂容器像素保真。
- 作者字号控件、目录定位与兼容提示沿现有视觉体系协调，保留浅深色、动态字号和可访问操作。

## 精确原生选择

| 文件 | 用例 |
|---|---|
| EPUBFontLoadingHostTests | epubWebKitDecodesSyntheticFontServesResourceAndMeasuresGlyphMetrics；epubWebKitGatesReadinessOnFontDecodingAndRebindsCapabilityAcrossEpochs |
| EPUBReaderHostTests | epubOpeningRouteStartsOnceAndObservesMountedPresentation；epubWebKitLoadsValidatedLocalResourcesAndRestoresTextNodeUTF16Position；epubTypographyReflowRestoresAnchorAndGatesStaleNavigationCallbacks；epubFailedRestorationRejectsLateReadyAndPendingContinuation；epubBoundaryViewportRestoresInFreshControllerAfterCloseOrSuspend；epubWebKitAppliesAuthorCSSPerChapterSwitchesLayoutModesAndReopensColdAndWarm；epubResourceHandlerEnforcesFontCapabilityMediaTypeAndHashVerification；epubFontIntegrityFailureRevokesReadyAndRejectsStaleFailureSignals |
| EPUBFlowUITests | testEPUBShelfCoverAndDirectoryCrossChapterNavigation；testEPUBProgressSurvivesExitAndProcessRelaunch；testEPUBTypographyNoCoverFallbackAndTXTIsolation |

10 Host＋3 UI，共13声明/13计划执行，按两Host文件组与三UI单例调度。解析/存储/TXT核心未变，不默认全Domain/TXT重测。新增字体及字号断言不是既有原生通过证明。

每次调用480秒、用例180秒、模拟器boot120秒、job60分钟保持。独立失败继续，真实公共前置失败仅阻塞依赖分支；设备Release独立编译。正式出包仍须选定测试、源身份、依赖、资源/许可证、arm64/iPhoneOS/iOS16.6/unsigned和逐字节IPA校验全部满足，不以失败续跑放宽资格。

## 公开白名单（21路径）

```text
App/EPUB/EPUBContentsView.swift
App/EPUB/EPUBLocationScript.swift
App/EPUB/EPUBReaderScreen.swift
App/EPUB/EPUBReaderViewModel.swift
App/EPUB/EPUBSettingsView.swift
App/EPUB/EPUBWebView.swift
Tests/YueJingEPUBUITests/EPUBFlowUITests.swift
Tests/YueJingHostTests/EPUBFontLoadingHostTests.swift
Tests/YueJingHostTests/EPUBReaderHostTests.swift
scripts/check_epub_author_scale_contract.py
scripts/check_epub_continuous_script.cjs
scripts/check_epub_interaction_contract.py
scripts/check_epub_ui_projection.cjs
scripts/epub_author_layout_fixture.cjs
scripts/epub_author_scale_fixture.cjs
scripts/epub_interaction_fixture.cjs
project.yml
scripts/epub_author_layout_scope.json
scripts/run_epub_author_layout_validation.py
scripts/check_epub_author_layout_validation.py
docs/READER_INTERACTION_RELEASE.md
```

UI投影检查器只用于本地设计验证，所需ignored预览及截图不进入云端或公开提交。用户状态/协作文档、私有文件、原书、历史证据与Skills排除；只能逐路径暂存，不reset/stash或广泛git add。

## 验证与交付边界

本地浏览器/源码合同证据仅说明相应机制，不代替Swift、WKWebView或手机。原生通过和设备IPA也不证明用户原书、触控惯性、首绘或偶发超时唯一根因已验收。覆盖安装保留旧库与位置，不卸载、清库、删书或强制重导。结果报告与每轮产物留在ignored artifacts，不为结果追加公开提交。
