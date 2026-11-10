# 多本近期 EPUB 生命周期定向验证：0.2.9 / build11

基线 `eee357c1bce90cd576657b1610116e55b75c1b92`，既有Task3/epub_freeze作业，scope `epub-recent-20`。

## 批次授权与阶段

用户批准重新绑定本批定向范围并全部验证：单项失败记录后继续独立项目，初轮全部结束前不立即修复；之后统一修复失败项，按影响范围复测，最后设备编译、打包、独立核验，交付IPA及完整验证/修复结果用于真机测验。

- 初轮 `build_ipa=false`：只验证，不构建设备IPA，业务源码冻结。
- 汇总初轮全部结果后才修复。保留每次原始错误、退出码、超时、日志和xcresult，不用后续通过覆盖历史失败。
- 打包阶段显式 `build_ipa=true`，与原始dispatch事件和环境绑定。设备构建位于验证后，条件独立于测试结论；编译或完整性失败不能交付。
- 严格资格要求所有选定执行通过；若最终仍只能提供诊断资格，必须显式 `allow_unqualified_ipa=true` 并标 `DEVICE_DIAGNOSTIC_ONLY / UI_NOT_QUALIFIED`，不将未通过、未知或未选项目计为通过。

## 精确范围

`run_epub_freeze_validation.py:ALLOWED` 锁定21路径：本批15个产品/测试路径，加workflow、runner、自检、清单、project和本文6个发布路径。仅新增4个文件：EPUBWarmRendererCache、EPUBParkReply、EPUBContentPool及EPUBContentPoolTests。project只允许0.2.8/build10→0.2.9/build11。

实现包括多本稳定版本内容目录、独立资源租约、有界热页面LRU、分层失效及缓存诊断。不改简介/场景图衔接、TXT业务、数据库schema、原书/资源完整SHA或session/epoch权限。XianxiaReader仅有限参考，不作标准。缓存成本为估算，未宣称真机速度、内存或首绘通过。

## 最小充分选择：20声明 / 21次展开

- Domain14：EPUBLibrary中8个受影响用例（原书/资源重开、最新进度/设置与新会话、重叠租约、损坏同mtime/符链回退、失败/取消关闭、打开失败释放、失败导入隔离、EPUB/TXT隔离），加全部6个新内容池用例（多书、租约淘汰、磁盘重发现/取消、损坏已租版本、坏回执隔离、缓存根异常降级）。损坏用例Bool展开2次，共15次Domain执行。
- Host3：首次资源加载及同书页面复用、排版重排/过期导航门控、新多书LRU/布局变化/打开中缓存清理。
- EPUB UI3：真实路由同进程重开、退出及进程重启恢复、设置/无封面/TXT隔离。会经过既有跨章步骤，但不扩大产品修改到图文衔接。
- 完整源码清单229声明/230次展开；209次展开本批未选择。15项UI清单完整展示，12项通用TXT/UI明确not_selected。

25组Chromium、16项synthetic/static和本地源码保护记录只有受测输入摘要一致时复用；不是本批原生通过。新Swift目标必须实际编译运行。

## 保留的执行与交付约束

每个声明独立xcodebuild及证据目录，失败不终止后项；公共工具链/依赖/模拟器前置不可用只阻塞真实依赖，不制造通过。取消仍终止。保留480秒调用、180秒单例、120秒boot和60分钟job，不放宽断言或时限。

使用固定macOS15、Xcode16.4/16F6、Swift6.1.2、XcodeGen2.46.0、现有固定依赖、最低iOS16.6。arm64 unsigned设备构建、WebKit链接、SwiftSDK依赖证明、图标/资源/许可证和IPA逐字节校验保持。

产物下载核验API摘要、ZIP CRC/路径/成员，独立核验source/run/attempt、实际Release二进制及交付副本摘要。未知执行总数保留null，单列已知/未知。结果只存ignored artifacts，不发布私有记录、用户脚本、书籍、录屏或Skills。

真机通过现有TrollStore覆盖安装，不卸载、不清库、不重导入。分别测试首开、A→A、A→B→A、多书轮换、后台与进程重启，观察正确进度和实际可交互时间；出包不是微信读书级性能已达到的证明。

## 初轮结果与受影响复测

初轮提交 `0cf3849908f9e142733a378848ae70a6bc9366b7`、run `42764634775/1` 已结束并完整采集：Domain14声明/15展开通过；Host3和UI3均实际发起，但同一Host测试文件的3个局部辅助函数缺少主actor隔离，编译退出65，行为测试未开始。没有将6项编译失败写成行为通过；初轮未请求设备包。

统一修复仅为 `makeModel`、`bind`、`openAndClose` 添加 `@MainActor`：这些函数构造或操作主actor拥有的UI模型/控制器，原断言、时间预算和生产实现不变。

复测 `epub-recent-host-ui-6` 仅选原Host3＋UI3，当前运行计划6次、资格名 `EPUB_RECENT_HOST_UI_6_TARGETED_NATIVE`；Domain15次通过仍归属初轮，不写进本轮通过数。相对初轮仅允许Host测试、workflow、runner、自检及本文5路径变化，严格保持产品、Domain测试、工具链、依赖和project不变。此前25组Chromium/16项脚本检查因受测生产JS未变不重复执行。设备阶段使用 `build_ipa=true`；诊断许可与正式资格仍独立，任何编译/完整性失败均不交付。
