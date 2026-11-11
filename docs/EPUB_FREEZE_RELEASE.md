# EPUB Ready 定向复验与分阶段交付：0.2.14 / build16

基线`1bf00449884f5fadf9d973a8d63220f9787b459d`；既有Task3入口`epub-ready-followup-2`。产品版本保持0.2.14/build16，此版本此前未交付IPA。

## 本批授权与步骤
用户明确批准重新绑定本批定向云验证、执行全部所选验证；验证期间记录失败并继续独立项目，不中途修复；全部结束后统一修复失败项，再编译打包并交付IPA及验证/修复结果。原失败记录永久保留，取消及真实公共前置阻塞仍须遵守。
初始边界只有6路径：两个目标测试文件、workflow、runner、自检及本说明；没有新增文件。生产Swift/JS/CSS、Ready存储/完整性/迁移、依赖、project.yml与所有共享测试helper不变。后续确有失败修复时，先根据具体改动说明影响范围并保留独立复验记录，不默认全量重测、不放宽断言或预算。

## 两项本轮验证
- Host：`epubTypographyReflowRestoresAnchorAndGatesStaleNavigationCallbacks`。旧运行字体重排后ch2/sec-mid返回node0，原要求>=6。完整根因仍未证实；仅补请求参数断言及失败后的只读几何/滚动取证，原失败继续抛出，取消不延迟，不改变测试模式或定位算法。
- UI：`testEPUBShelfCoverAndDirectoryCrossChapterNavigation`。只修隐藏工具栏后对已消失exit直接读取isHittable造成的重试；先exists短路。旧日志该段32.31–46.89秒，实际新耗时待原生验证。底部点击、封面、目录、横向翻页、退出/暖复开、精确位置和全部期限/截图保持。

全库236声明/237展开。当前新增运行2身份/2展开；旧运行中的另外34身份/35展开可以复用，但必须通过下面的证据与源码隔离门。组合目标36身份/37展开，其余200展开未选，不是全量回归。

## 历史证据绑定与隔离
固定旧source为本基线、run42954931349/attempt1、artifact13827937675、旧scope为epub-ready-open-36。旧工作流failure不否定其中逐项真实通过的35展开，但失败host-3/ui-1绝不纳入复用。
复用包括Domain29身份/30展开（Bool双叶）、其他Host4、进程重启UI1。核对API run/source/artifact摘要/大小、ZIP CRC/安全路径/成员类型与预算、原始selection/execution/log/counts/xcresult，不能只读绿色总数。源码树只有6允许路径，两个测试文件只有指定方法体可改，方法外及全部共享代码必须一致；项目版本和工具链不变。错来源、缺失/篡改、未完成、失败及隔离边界变化必须拒绝。

## 两个阶段，不重复业务测试
1. **validation**：`build_ipa=false`，`prior_validation_run`为空。新执行2项；独立核验旧35项。证据核验失败不截断可运行的新测试；首项失败后第二项仍运行。全部结束并汇总后才处理失败。正式组合资格要求新2项和旧35项证据都真实通过。
2. **delivery**：`build_ipa=true`，`prior_validation_run`绑定已完成的同源码validation运行。重新校验其原始两项证据及历史35项绑定，不启动模拟器、不执行原生测试；本次native执行0，复用37。禁止自引用、链式delivery引用、错source/attempt或以缺失/失败证据宣称通过。随后实际编译iPhoneOS arm64 Release、检查WebKit/SDK依赖并校验IPA。

两阶段使用同一互斥scope。令牌沿用既有证据复用作业的contents/actions只读配置，无新增凭据、登录或写权限。各阶段记录独立source/run/attempt及输入，不能将历史测试改绑为当前运行。

## 失败、修复与资格
记录原始错误、退出码、外层超时与XCTest用例级超时。`timed_out=false`只表示外层480秒调用未超时，不能覆盖原始180秒case-timeout；重启后的空套件也不是通过。所有所选身份必须有明确结果，原失败不被后续成功覆盖。
验证全部完成后统一处理具体失败，只复验实际受影响项；未受影响的历史成功保留身份后复用。根因未证实不得靠猜测补丁、删断言、延长等待或反复全量执行制造成功。
设备编译、测试资格、IPA完整性、正式交付、真机体验分别报告。默认`allow_unqualified_ipa=false`；未全绿诊断交付需显式授权和DEVICE_DIAGNOSTIC_ONLY/UI_NOT_QUALIFIED标签，不能绕过实际设备及IPA字节检查。

## 保持的工具链与打包检查
固定macOS15、Xcode16.4/16F6、Swift6.1.2、XcodeGen2.46.0、GRDB7.0.0、ZIPFoundation0.9.19、iOS16.6。保持480秒调用、180秒用例、120秒模拟器启动、60分钟job预算。
IPA必须核对实际Release二进制、arm64/iPhoneOS/最低系统/unsigned、动态依赖与Swift SDK证明、资源/图标/许可证、完整payload字节、API artifact摘要/大小及ZIP完整性；本地独立核验与交付副本摘要一致后才给出文件。不能以设备构建成功代替这些检查。

## 手机验收边界
现有TrollStore覆盖安装，不卸载、清库或重导入。Ready轻量metadata不保证由旧0.2.13读取，不直接降级。
旧书一次性迁移单独计时；正常点书到正确正文可见且能立即滚动/翻页，目标常规300ms内、P95≤500ms且用户无明显等待。Ready首开、同进程重开、A→B→A、进程重启后点书分开采样。诊断ready不是首绘证明，仍需录屏/交互核对。原生或IPA通过均不代表此目标已在iPhone13/iOS16.6.1验收。
