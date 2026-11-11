# EPUB Ready 定向复验与分阶段交付：0.2.14 / build16

基线`1bf00449884f5fadf9d973a8d63220f9787b459d`；既有Task3入口现绑定`epub-ready-host-followup-1`。产品版本保持0.2.14/build16，此版本此前未交付IPA。

## 本批授权与步骤
用户明确批准重新绑定本批定向云验证、执行全部所选验证；验证期间记录失败并继续独立项目，不中途修复；全部结束后统一修复失败项，再编译打包并交付IPA及验证/修复结果。原失败记录永久保留，取消及真实公共前置阻塞仍须遵守。
初始边界为6路径：两个目标测试文件、workflow、runner、自检及本说明；没有新增文件。本轮只在其中Host测试、workflow、runner、自检及说明上修改；UI测试与生产Swift/JS/CSS、Ready存储/完整性/迁移、依赖、project.yml不变。共享helper不变；仅显式放行失败用例专属`verifyHorizontalPagination()`的同步诊断，保持所有动作、断言和预算。

## 已完成批次与本轮验证
- 原验证run42954931349：35展开通过，Host片段定位断言失败，UI用例超时，原始证据保留。
- followup ROUND-1/run42973126124：Swift版本探测30秒超时，两项均未启动，不能记为原生测试失败或通过。
- followup ROUND-2/run42974144689/attempt1/source`3ed4da9eac1ce59452c35c8412a66827d6b4295e`：两项均已执行完毕，UI通过144.655秒、exit0；Host失败exit65且非用例/调用超时；旧35项复用核验通过。组合资格仍不通过。
- Host原片段定位本次恢复node15，未复现原node0失败；随后专属横向分页初始就绪检查失败，根因尚未证实。现仅补`verifyHorizontalPagination()`的合成夹具回调/错误域码/视图状态同步诊断，原15秒等待、断言和原错误抛出保持，无重试或算法修改。
- 新执行仍是完整`epubTypographyReflowRestoresAnchorAndGatesStaleNavigationCallbacks`，不裁剪子场景。UI短路修复已由ROUND-2通过，本轮不重复执行。

全库236声明/237展开。本轮新执行1身份/1展开，复用35身份/36展开（原34身份/35展开＋ROUND-2 UI1），组合36身份/37展开，其余200展开未选，不是全量回归。

## 历史证据绑定与隔离
固定旧source为本基线、run42954931349/attempt1、artifact13827937675、旧scope为epub-ready-open-36。旧工作流failure不否定其中逐项真实通过的35展开，但失败host-3/ui-1绝不纳入复用。
原35项包括Domain29身份/30展开（Bool双叶）、其他Host4、进程重启UI1。另固定ROUND-2的UI证据run42974144689/attempt1/artifact13834739136；仅复用真实通过的ui-1，不复用失败Host。两来源均核对API run/source/artifact摘要/大小、ZIP CRC/安全路径/成员类型与预算、原始selection/execution/log/counts/xcresult，不能只读绿色总数。源码树仍只有6允许路径：相对原基线仅原两目标方法及上述专属helper允许有界变化，helper调用链须仍只属于目标Host；相对ROUND-2，UI文件及全部产品/共享代码必须一致。项目版本和工具链不变。错来源、缺失/篡改、未完成、失败及隔离边界变化必须拒绝。

## 两个阶段，不重复业务测试
1. **validation**：`build_ipa=false`，`prior_validation_run`为空。新执行Host1；独立核验旧35项与ROUND-2 UI1。证据核验失败不截断可运行的新测试；全部结束并汇总后才处理失败。正式组合资格要求新1项和复用36项证据都真实通过。
2. **delivery**：`build_ipa=true`，`prior_validation_run`绑定已完成的同源码新validation运行。重新校验其原始Host1及两来源复用36项，不启动模拟器、不执行原生测试；本次native执行0，复用37。禁止自引用、链式delivery引用、错source/attempt或以缺失/失败证据宣称通过。随后实际编译iPhoneOS arm64 Release、检查WebKit/SDK依赖并校验IPA。

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
