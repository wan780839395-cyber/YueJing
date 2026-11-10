# EPUB 二次开书优化发布：0.2.12 / build14

基线 `b15c2f86434896124746db0cb0bf634a05c5d14e`；入口 `epub-reopen-fast-10`，沿用 Task3 的独立 epub_freeze 作业。

## 授权和边界
用户批准本地优化、10项定向云验证（11次参数展开执行）、普通push和独立设备IPA交付。逐项失败保留并继续其余独立检查；收齐结果后统一处理，仅复测受影响项。诊断包须明确标注，编译或完整性失败不得交付。

精确14路径由runner的ALLOWED限定：MetadataSnapshot、ContentPool、ResourceStore、OpeningTimings、LibraryStore、LibraryService、内容池测试、两个源码检查，以及workflow、发布runner、自检、project和本说明。仅新增check_epub_reopen_fast.py。project只允许0.2.11/build13→0.2.12/build14。

原书及逐资源完整SHA、路径/符链/类型/大小/预算、最新偏好/进度、permit/session/epoch与同步事务语义不变。无UI/JS/加载提示改动，无schema迁移，不启用字体/CSS，不清库、不重导入。私有书籍/截图/用户文件/Skills不公开提交。

## 实际优化
- 已有活动或停驻renderer租约持有不可变Decoded证明；重新读取数据库元数据并计算完整SHA，相同才共享解码对象。不新增独立整书常驻缓存，最后租约释放后不由闲置Entry保留解码树。未命中仍正常解码。
- 命中时每次开书JSON解码从1次减为0次；会话前仍重新读取并比较数据库原始字节，不能借用旧进度或旧许可。
- 每个资源叶子的符链/类型/大小合并为一次Foundation属性查询（原两次）。根及父目录检查、读取上限、精确大小和完整SHA保持；不将校验延迟至使用时。
- 新增`leased-metadata-v1；元数据解码复用：true/false`摘要。保留原metadata/session分段，无私人标识。

## 定向选择及依据
- Domain：EPUBContentPoolTests全部6个现有身份，覆盖独立租约、退役/逐出、取消、磁盘复用、损坏、异常缓存和临时回退。扩展原用例验证1633章对象复用、同大小元数据变化、非法JSON、最后租约释放、根/书隔离和各类符链/资源损坏；未新增测试身份。
- Domain：`epubWarmReopenTransfersFolderWithFreshSessionPositionAndPreferences`与`epubDamagedClosedWorkspaceFallsBackWithoutTrustingMtime`（Bool两次），覆盖最新状态/会话和全资源校验。
- Host：`epubWebKitLoadsValidatedLocalResourcesAndRestoresTextNodeUTF16Position`与`epubRecentBooksReusePagesAcrossSwitchesAndEvictOnlyIdleLRU`，覆盖真实WebKit资源、位置及停驻renderer租约。
- 共Domain8+Host2=10个身份/11次计划执行；全库229声明/230展开，219展开未选择。完整15项UI均为not_selected，不能计通过。无UI/JS改动，不默认全量回归。
- 参数化与UI解析器离线负例保留，但合成组不进入云执行选择。

## 验证及设备包
保留逐项命令、selection/execution/counts/failure、原始日志和xcresult。失败、超时、阻塞、未执行、未选择准确区分；未知执行数保留null，不用计划11替代。已有失败不能被后续绿色回执覆盖。

固定macOS15、Xcode16.4/16F6、Swift6.1.2、XcodeGen2.46.0、既定GRDB/ZIPFoundation及iOS16.6。保持480秒调用、180秒用例、120秒模拟器启动和60分钟job预算。

build_ipa显式控制设备阶段，在全部选定测试尝试之后执行；独立原生失败不阻断设备Release/完整性检查。正式定向资格要求11次展开全部通过，不代表全量或UI验收。诊断降级须显式allow_unqualified_ipa=true并标注DEVICE_DIAGNOSTIC_ONLY / UI_NOT_QUALIFIED。

下载后核验API SHA/大小、ZIP CRC/安全成员、source/run/attempt、实际Release二进制、Swift SDK/TAPI依赖、资源/图标/许可证及IPA字节；交付副本再核对摘要。

## 真机前后对比与剩余空间
截图基线为打开→章节就绪0.718s；准备0.644s，排版/恢复0.075s。书库/许可0.326s、原书SHA0.022s、指纹0.000s、1678资源（37622563字节）校验0.281s、会话0.015s。截图未显示版本/build；不是受控前后对比，窗口/locator就绪也不等于真实首绘。0.326s包含actor/DB/解码，不能全算作解码时间。

当前仅能确认减少了真实重复工作，不能将0.326s或0.281s直接扣除作为优化后成绩。原生回归和IPA校验不证明真机耗时下降。

通过现有TrollStore覆盖安装，不卸载、不清库、不重导入。确认0.2.12/build14及leased-metadata-v1；同书、同位置、同设置，记录首次打开、连续3次暖复开和A→B→A的总耗时/书库/资源/会话/恢复以及解码复用标志。进程重启另记，不能混入暖复开均值。

完整原书/1678资源验证、最新数据库状态与会话确认、WebKit恢复仍需耗时，不承诺零等待。后续可考虑导入阶段持久化Ready结果、轻量manifest及按章元数据以减少结构性成本；改变完整性发现时机的按使用校验须单独决策，本批不采用。
