# EPUB P0 会话分段观测发布：0.2.11 / build13

基线 `a8f044bcb9b0892bdc4843736ec074dd3fa170f6`；入口 `epub-session-profile-3`，沿用 Task3 的独立 epub_freeze 作业。0.2.10功能及IPA校验通过，但真机仍反馈开书3.245秒、会话1.294秒；性能尚未解决。

## 授权和边界
用户批准P0本地观测及3项云验证、普通push和独立设备IPA交付。逐项独立验证，失败保留并继续其余独立检查；收齐结果后统一处理，按影响选择必要复测。不进入P1迁移，不启用字体/CSS，不放宽完整性或预算。

精确11路径由runner的ALLOWED限定：会话分段、开书计时、LibraryStore、LibraryService、内容池测试、观测源码检查，以及workflow、发布runner、自检、project和本说明。仅新增EPUBSessionBreakdown.swift与check_epub_session_profile.py。project只允许0.2.10/build12→0.2.11/build13。

原书及逐资源完整SHA、路径/符链/类型/大小/预算、最新偏好/进度、permit/session/epoch与同步事务语义不变。无schema迁移、不清库、不重导入。私有书籍/截图/用户文件/Skills不公开提交。

## 定向选择及依据
- Domain：`epubWarmReopenTransfersFolderWithFreshSessionPositionAndPreferences`，覆盖最新进度/偏好与新会话。
- Domain：`recentBooksReuseIndependentVersionsWithoutCopying`，在原租约、元数据及损坏回归中验证18分段、有限计数、嵌套时序、成功/抛错/合并行为。
- Host：`epubWebKitLoadsValidatedLocalResourcesAndRestoresTextNodeUTF16Position`，覆盖实际model与WKWebView资源/位置路径。
- 共3个身份/3次计划执行，无选定参数化或UI用例；清单229声明/230展开，227展开未选择。完整15项UI清单均为not_selected，不能计通过。UI/JS业务未变，不默认重跑20项或全量。
- 参数化与UI解析器的离线合成负例保留，但不添加到本批云执行范围。

## 验证及设备包
保留逐项命令、selection/execution/counts/failure、原始日志和xcresult。失败、超时、阻塞、未执行、未选择准确区分；未知执行数保留null，不用计划3替代。已有失败不能被后续绿色回执覆盖。

固定macOS15、Xcode16.4/16F6、Swift6.1.2、XcodeGen2.46.0、既定GRDB/ZIPFoundation及iOS16.6。保持480秒调用、180秒用例、120秒模拟器启动和60分钟job预算。

build_ipa显式控制设备阶段，在全部选定测试尝试之后执行；独立原生失败不阻断设备Release/完整性检查。正式定向资格要求3项全部通过，不代表全量或UI验收。诊断降级须显式allow_unqualified_ipa=true并标注DEVICE_DIAGNOSTIC_ONLY / UI_NOT_QUALIFIED；编译或完整性失败不得交付。

下载后核验API SHA/大小、ZIP CRC/安全成员、source/run/attempt、实际Release二进制、Swift SDK/TAPI依赖、资源/图标/许可证及IPA字节；交付副本再核对摘要。

## 真机观测与P1门槛
本包是观测包，不是提速修复。`session-breakdown-v1`保留18个固定墙钟分段及元数据字节数，不记录书名/路径/正文。外层preferencesCall、beginCall、confirmCall、releaseCall包含各自等待；内层actorAdmission、storeSetup、databaseEntry、bookRead、formatRead、metadataRead、metadataCompare、progressRead、progressDecode、positionValidation、rowUpdate、transactionReturn、storePublish、returnResume包含于beginCall，不能重复相加。actorAdmission不是纯数据库竞争，transactionReturn也不是纯fsync。

通过现有TrollStore覆盖安装，不卸载、不清库、不重导入。确认0.2.11/build13及标识；同一慢书、位置、设置，记录初次打开、连续复开和A→B→A的完整总阶段与18分段诊断。功能通过不是首绘/FPS/RSS或性能验收。取得真机数据后再选择P1优先级；完整性验证时机变化须单独决策。
