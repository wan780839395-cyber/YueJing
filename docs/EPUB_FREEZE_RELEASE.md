# EPUB 复开原因诊断发布：0.2.13 / build15

基线 `fa25f9757f33010111419d10da3fe0e50abf5aba`；入口 `epub-reopen-diagnostics-3`，仅 Task3 的独立 epub_freeze 作业。

## 授权与边界
用户批准本批白名单普通提交/push、Domain1+Host2定向原生验证、独立设备Release与IPA核验。重复批准消息不代表额外dispatch。单项失败保留原日志、退出码与超时状态，继续独立步骤；汇总后仅修复并复测受影响项，不放宽预算或断言。

本批精确16路径由runner ALLOWED限制：11个实现/回归/源码检查文件及workflow、runner、自检、project和本说明5个发布文件。新增仅EPUBReopenDiagnostics.swift与check_epub_reopen_diagnostics.py。project只允许0.2.12/build14→0.2.13/build15。用户文件、私有书籍、截图、Skills和内部证据不公开。

## 本包用途
用户确认0.2.12/build14，真机总耗时1.040s，元数据复用false、关闭页面复用0、资源校验0.564s、书库/许可0.328s、会话0.014s。尚未证明长书预算拒收、内存警告或停驻失败中的哪项发生；本包补齐原因证据，不宣称提速成功。

`reopen-reasons-v1`记录关闭、停驻、准入/拒收、逐出、内存回收、WebContent终止、下次take原因。最多64条内存记录，同书同服务输出最近16条；只输出固定原因码和数值成本，无书名/路径/正文/私有错误，服务弱引用，不持久化、不上传。观察身份与缓存准入分开，旧generation不能污染新路由诊断，观察不授予缓存权限。

元数据原因包括reused/noLeaseProof/metadataChanged/notChecked；仍用新数据库实际字节完整SHA判断。停驻成本原公式16MiB+图片解码估算+2×全书XHTML保持，96MiB/3renderer不变；估算不是RSS。2秒停驻期限原本存在，本批仅加超时原因回调。

原书及逐资源完整SHA、路径/符链/类型/大小/预算、最新偏好/进度、permit/session/epoch和事务不变。无JS、加载提示、schema、字体/CSS或资源验证时机改动；不清库、不重导入。修补诊断丢失/重复不等于已找到用户未命中根因。

## 定向用例及依据
1. Domain `recentBooksReuseIndependentVersionsWithoutCopying`：已有租约/元数据/完整性回归中补无证明、相同SHA复用、元数据变化和最后租约释放后原因。
2. Host `epubWebKitLoadsValidatedLocalResourcesAndRestoresTextNodeUTF16Position`：真实WKWebView资源/位置及verifySameBookWarmRenderer，覆盖同书停驻、新会话恢复。
3. Host `epubRecentBooksReusePagesAcrossSwitchesAndEvictOnlyIdleLRU`：多书LRU与本批预算拒收、非法停驻状态、进程终止、旧代号隔离、有界诊断、超时晚回等新增断言；1633章仅合成成本数据，不冒充私人长书全链测试。

共3身份/3次计划执行，无实际参数化或UI用例；全库229声明/230展开，本次226声明/227展开未选择，全部15项UI not_selected。离线参数/UI解析负例保留但不进入云选择。原生执行数只能来自真实事件，未知保留null，不能填计划3。

## 验证与资格
固定macOS15、Xcode16.4/16F6、Swift6.1.2、XcodeGen2.46.0、既定GRDB7.0.0/ZIPFoundation0.9.19、iOS16.6。原480秒调用、180秒用例、120秒模拟器启动及60分钟job预算保持。

测试失败不阻断独立设备编译；编译、测试资格、IPA完整性和真机性能分别报告。本批默认allow_unqualified_ipa=false；3项全部真实通过才获EPUB_REOPEN_DIAGNOSTICS_3_TARGETED_NATIVE资格。既有显式诊断降级能力保留，只有另行明确许可才启用DEVICE_DIAGNOSTIC_ONLY / UI_NOT_QUALIFIED，且仍不能绕过设备编译及完整性。

下载后独立核对API摘要/大小、ZIP CRC/安全成员、source/run/attempt、原始测试事件/xcresult、实际Release二进制、Swift SDK/TAPI、资源/图标/许可证、unsigned arm64/iPhoneOS/minOS和IPA字节；交付副本再次核对哈希。定向通过不是全量、UI、首绘/FPS/RSS或真机提速验收。

## 真机步骤
TrollStore覆盖安装，不卸载、清库或重导入。确认0.2.13/build15和reopen-reasons-v1。同机同书同位置设置，记录初次打开后返回书架，再连续3次暖复开及A→B→A；进程重启单独记录。

保存总阶段、元数据复用标志及原因、完整reopen-reasons-v1链和数值成本。只有takeMiss不能推断更早原因（可能本进程首次/不同服务/有界记录淘汰）。看到具体拒收/失效原因后再选择性能修复；完整校验、数据库和WebKit恢复仍有成本，不承诺零等待。
