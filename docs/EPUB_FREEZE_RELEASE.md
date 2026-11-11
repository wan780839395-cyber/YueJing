# EPUB Ready 打开提速发布：0.2.14 / build16

基线 `46d0ea00661cd1a05049f88cf2c4153e4d6f1a63`；入口 `epub-ready-open-36`，仅Task3独立epub_freeze作业。

## 授权与边界
用户批准本批白名单普通提交/push、36个定向测试身份/37次展开、独立设备Release与IPA核验。一次初始dispatch；重复批准消息不代表额外dispatch。单项失败保留原日志、退出码与超时状态，继续独立步骤；汇总后仅修复并复测受影响项，不放宽预算或断言。

精确25路径由runner ALLOWED限制：20个实现/回归/检查文件和workflow、runner、自检、project、本说明5个发布文件。新增仅EPUBReadyArtifact.swift、EPUBReadyTests.swift、check_epub_ready_open.py。project只允许0.2.13/build15→0.2.14/build16。用户文件、私有书籍、截图、Skills、内部证据不公开。

## 实现与约束
- 导入净化资源经完整校验后保存为UUID Ready版本，数据库存轻量描述/按章节点索引；节点数据存有完整摘要的nodes.bin。原节点编号、UTF-16/字素坐标、book/version ID保持。运行时节点缓存最多4章/8MiB估算，不增加独立整书常驻缓存。
- v7只新增EPUB版本目录引用表，旧TXT/进度/偏好结构不变。旧书自动一次性迁移：先落盘并由租约保护，再按旧metadata实际字节CAS事务切换。取消/失败不覆盖旧描述；数据库提交后无取消点阻止持久化确认。旧版本最后租约释放后才回收。
- 每次开书仍完整读取原书SHA、校验manifest和全节点包SHA、验证全部净化资源。每次打开最多4个资源任务，沿用真实路径/符链/类型/大小/读取上限/完整SHA，全部完成后才创建阅读会话。不是延后到使用时才发现未访问章节损坏。
- 损坏只做一次精确原书重建，全部语义字段、节点摘要/偏移须匹配旧描述，目录代号可更换。没有mtime/TTL短路。最新进度、设置、permit/session/epoch保持当次确认。
- 停驻仅裁掉视口外无关邻章，保留当前可见正文及图片位置；像素锚点无法保持时恢复原DOM顺序与滚动坐标。原16MiB+图片解码估算+2×整书XHTML公式和3renderer/96MiB上限不变。当前章自身超预算仍真实拒绝，不靠少算内存或隐藏内容达标。
- `chapter-ready-v1`区分按章路径及本次迁移/重建；发生准备时不显示解析0/复制0。原`reopen-reasons-v1`和分段计时继续保留，不含书名/路径/正文，不上传。

## 定向验证与依据
选择完整身份由runner SELECTED_FILES列出：
1. Domain29：Ready新增7，受影响导入/关闭/重建/迁移/隔离12，内容池租约与恢复4，进度权限4，图像兼容1，TXT迁移保护1。损坏文件用例Bool双参数，Domain共30次展开。
2. Host5：资源与UTF-16定位、WebKit安全、字体/epoch、图片兼容、同书/多书页面复用与LRU。
3. EPUB UI2：目录跨章/同进程重开，进度退出/进程重启恢复。

全库236声明/237展开，本批36声明/37次计划执行；200展开未选择，全部15项UI中13项not_selected。原生实际计数来自原始事件及xcresult参数叶，未知保持null，不能将计划37填为实际通过。
本地27组Chromium布局、16项synthetic/static横排检查及Ready源码合同不代替Swift、WKWebView、原生或真机验收。

## 工具链与发布资格
固定macOS15、Xcode16.4/16F6、Swift6.1.2、XcodeGen2.46.0、GRDB7.0.0/ZIPFoundation0.9.19、iOS16.6。保持480秒调用、180秒用例、120秒模拟器启动、60分钟job预算。
测试失败不阻断独立设备Release；编译、测试资格、IPA完整性及真机性能分别报告。默认allow_unqualified_ipa=false，37次真实展开全通过才获 `EPUB_READY_OPEN_36_TARGETED_NATIVE`。只有另行明确授权才启用DEVICE_DIAGNOSTIC_ONLY/UI_NOT_QUALIFIED，且不能绕过设备和完整性门。
下载后独立核对API摘要/大小、ZIP CRC/安全成员、source/run/attempt、原始事件/xcresult、实际Release二进制、Swift SDK/TAPI、资源/图标/许可证、unsigned arm64/iPhoneOS/minOS与IPA摘要，交付副本再次核对。定向通过不等于全量、真机首绘/FPS/RSS或提速通过。

## 真机验收
TrollStore覆盖安装，不卸载、清库或重导入。新格式读取旧数据，但旧0.2.13不保证读取已迁移的轻量metadata，未经验证不要降级。
目标从点书到正确正文可见且可立即滚动/翻页：常规300ms内、P95≤500ms，并由用户确认无明显等待。录屏与实际交互交叉核对；locatorReady/windowCommitted不作为首绘证明。
同机同书同位置设置，分别记录Ready后首开、同进程重开、A→B→A、进程重启回书架后点书。先3次冒烟，再每组至少20次，报告中位数/P95/最大值；旧书一次性迁移单列且报告实际等待，不混入正常暖开。完整校验仍随整书规模增长，不承诺任意大书固定耗时，不以理论并行倍数宣称提速。
