# EPUB 元数据复开优化发布：0.2.10 / build12

基线 `9182f1f990fe1956bdfaedab456dc7a7df9e0422`；当前入口 `epub-metadata-20`，沿用 Task3 的独立 epub_freeze 作业。旧批次结果与原失败保持在各自归档，不作为本次修改后的原生通过。

## 本批授权和范围
用户批准重新绑定定向云验证及打包，按之前流程：逐项独立验证，失败记录后继续；收齐结果后统一处理，按影响选择必要复测；最终设备包独立核验并交付真机测验。不扩展字体/CSS功能、不放宽完整性或时间预算。

精确12路径由runner的ALLOWED限定：元数据快照、内容池、开书计时、LibraryStore、LibraryService、内容池测试、元数据源码检查，以及workflow、发布runner、自检、project和本说明。仅新增EPUBMetadataSnapshot.swift与check_epub_metadata_reopen.py。project只允许0.2.9/build11→0.2.10/build12。

本次减少同一次开书重复全书元数据解码，并用实际元数据完整SHA索引最多64个规范指纹；会话事务重新读取并逐字节比对真实元数据。原书与逐资源完整SHA、路径/符链/类型/大小/预算、permit/session/epoch、新进度和偏好均保留。指纹算法与旧磁盘receipt兼容；无数据库schema迁移，不清库、不重导入。

## 定向选择及依据
- Domain14声明/15展开：原书与资源重开、最新进度/偏好和新会话、独立租约、损坏同mtime/符链回退、取消/失败关闭、打开与导入失败清理、EPUB/TXT隔离；6个内容池用例全部覆盖。
- 既有多书内容池身份内补充：单次解码快照、同大小/同version元数据变化拒绝、64指纹上限、1633章合成元数据复用、指纹命中仍校验原书与资源、数据库读取后变化拒绝旧会话快照、恢复真实字节与旧permit拒绝。
- Host3：首次资源及同书页面复用、排版/旧回调拒绝、多书LRU与布局/后台/失效。
- EPUB UI3：目录/分页/同进程重开、退出与进程重启恢复、排版/无封面/TXT隔离。
- 共20个身份/21次计划执行。清单229声明/230展开，209展开未选择；15项完整UI清单展示，其余12项不计通过。共享openEPUB/会话接口变化，不能复用旧业务通过冒充本次；不默认全量回归。

## 验证与设备包
保留每项独立命令、selection/execution/counts/failure、原始日志和xcresult。失败、超时、阻塞、未执行、未选择准确区分；未知完整执行数保留null，不用计划21替代。已有失败记录不能被后续绿色回执覆盖。

固定macOS15、Xcode16.4/16F6、Swift6.1.2、XcodeGen2.46.0、既定GRDB/ZIPFoundation依赖及iOS16.6。保留480秒调用、180秒用例、120秒模拟器启动、60分钟job预算。

build_ipa显式控制设备阶段，位于全部选定测试尝试之后。设备Release与完整性检查不因独立UI失败而跳过。正式资格要求选定执行全部通过；若残留问题只能诊断交付，须显式allow_unqualified_ipa=true且标注DEVICE_DIAGNOSTIC_ONLY / UI_NOT_QUALIFIED。编译或完整性失败始终不得交付。

下载后核验API SHA/大小、ZIP CRC/成员、source/run/attempt、实际Release二进制、Swift SDK/TAPI依赖、资源/图标/许可证与IPA字节；交付副本再核对摘要。

## 性能与字体/CSS边界
metadata-snapshot-v1诊断标识和规范指纹独立阶段用于同机同书复测。合成数据与原生功能通过不是首绘/FPS/RSS或固定提速证明。实际改善幅度仍需真机读取前后分段耗时。

原始EPUB内的字体/CSS继续完整保留；受控启用仅已评估，本批不修改解析净化器、CSP、字体或样式加载策略。所有私有书籍/截图/用户文件/Skills只留本地，不公开提交。

通过现有TrollStore覆盖安装，不卸载、不清库、不重导入。验证同书重开、A→B→A、设置变化、后台和进程重启后的正确位置及可操作时间。
