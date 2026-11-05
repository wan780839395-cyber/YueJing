# EPUB 连续阅读发布验证：0.2.4 / build 6

## 范围

以 `63a68c3d0776ec8084156f16ccd43537f79eaf24` 为基线，发布此前完成的有界同文档多章阅读、上下滚动/左右分页选择、校验后资源缓存与 DOM 复用、实际安装版本展示。实现边界见 `EPUB_CONTINUOUS_READING.md` 和 `EPUB_READING_MODES.md`。

用户已批准本批普通提交、推送、原生验证和 IPA 编译；失败可在本范围内修复、普通追加提交并启动新的 attempt1。保留每次失败证据，不改历史、不削弱断言、不以重复运行掩盖失败。交付成功后停止，不为结果再次推送。

字体选择/导入和自定义颜色/背景图延期。TXT 内核、数据库结构、原书/进度/书签格式、安全校验、现有依赖与工具链不变。用户本地文件、Skills、私人书籍和历史证据不发布。

## 最小充分原生范围

使用既有 Task3 工作流的新 `epub-reading-15` 分支，依次执行以下 15 个真实原生测试。总清单仍为 214；其余 199 本次不执行，也不宣称通过。

### Domain：8

- EPUBLibraryTests/epubOriginalArchiveAndValidatedResourcesSurviveReopen
- EPUBLibraryTests/epubDuplicateKeepsProgressAndRepairsMissingArchive
- EPUBLibraryTests/epubBooksAndTXTStayIsolated
- EPUBCompatibilityTests/epubCompatibilityEPUB2DoctypeImageWebPImportProgressSurvivesReopen
- EPUBProgressTests/epubPositionsRejectForeignVersionsUnitsAndInvalidUTF16Boundaries
- EPUBProgressTests/epubProgressRequiresReadinessAndIncreasingSequence
- EPUBProgressTests/epubOldNavigationSupersededSessionAndClosedCallbacksCannotWrite
- EPUBProgressTests/epubTypographyEpochRestoresSameTextPositionAndSettings

覆盖缓存重开、原文件校验、兼容资源、TXT 隔离及位置/会话/代号写入权限。

### Host：4

- EPUBReaderHostTests/epubWebKitLoadsValidatedLocalResourcesAndRestoresTextNodeUTF16Position
- EPUBReaderHostTests/epubSecurityRejectsScriptsFormsExternalResourcesAndKeepsIsolatedLocatorWorking
- EPUBReaderHostTests/epubTypographyReflowRestoresAnchorAndGatesStaleNavigationCallbacks
- EPUBReaderHostTests/epubCompatibilityWebKitLoadsStaticImagePageAndRestoresAnchor

覆盖实际 WebKit 的连续章节 DOM、资源、位置、阅读模式、重排和旧回调隔离。

### UI：3

- EPUBFlowUITests/testEPUBShelfCoverAndDirectoryCrossChapterNavigation
- EPUBFlowUITests/testEPUBProgressSurvivesExitAndProcessRelaunch
- EPUBFlowUITests/testEPUBTypographyNoCoverFallbackAndTXTIsolation

覆盖实际 App 手势、跨章、退出及进程重启、设置与版本展示、TXT 隔离。

## 门控与证据

固定 macOS 15、Xcode 16.4/16F6、Swift 6.1.2（语言 6、完整并发检查）、XcodeGen 2.46.0、最低 iOS 16.6、GRDB 7.0.0 和 ZIPFoundation 0.9.19。动态选择已安装 arm64 模拟器，不安装运行时。

Domain/Host/UI 聚合预算分别为 480/480/1200 秒，单例 180 秒。新增 Domain 阶段后工作流总预算为 60 分钟，单组/单例预算未放宽。逐项检查真实开始/结束事件、唯一通过、零跳过/失败/超时，以及同源 SHA、同 run/attempt、精确命令、有效配置、依赖和 xcresult 证据。

仅 15 项全部通过后编译实际 iPhoneOS arm64 Release；随后检查动态依赖/Swift SDK 证明、资源、最低系统、无签名和 IPA 与实际构建逐文件字节一致性。资格标记为 `EPUB_READING_15_TARGETED_NATIVE`，覆盖标记为 `EPUB_READING_TARGETED_NOT_FULL`，不得冒充全量回归。

Windows 的脚本/清单/离线模拟校验与 Chromium 布局检查不是 Swift 编译或 WebKit 原生测试。历史原生通过不等于本候选通过。原生结果与 IPA 核验结果存于 ignored artifacts，不将未执行结果写成通过。

## 真机交付边界

成功交付后使用既有 TrollStore 覆盖安装至 iPhone 13 / iOS 16.6.1，不卸载、不清数据、不强制重导原书。先确认版本 0.2.4（6），检查连续跨章、逆向滚动、两种模式切换、退出/进程重开和旧书进度。原生模拟器通过与 IPA 合格不代表真机惯性、视觉连续性、内存或耗时已验收；不承诺未测量的性能改善。
