# C 方案：退出控件与 XCTest 查询恢复

## 范围与边界

基线 `2f962b60c4837ed6d226a518971495699f1c81f8`。仅修改 ReaderScreen、ReadingFlowUITests、ios-build，新增本说明及 check_c_exit_recovery.py，共五路径。保留唯一 C（侧栏导航、右侧可展开 dock）；不改 ReaderFloatingToolsView、ReaderViewController、Viewport、ViewModel、路由、TXT、数据库、保存/进度、Task3 工作流、工程、依赖、资源及既有其他测试。

用户批准：`批准5路径修复、一次完整验证及必要时诊断IPA（含UI超时）`。普通 commit/push 各一次；Task3 full/attempt1 一次。全部146项真实通过、零跳过后才正常打包。若仍仅 UI 断言、UI 超时或附件导出失败，允许未完成 UI，另执行一次同源诊断 IPA；编译、依赖、打包等失败仍停止。诊断包必须标记 TESTS NOT RUN、完整回归未通过；不追加修补提交、重推或重跑。

## 已知错误，不夸大根因

前次原生运行41565930201/1：139通过、2失败、1未完成、4未执行、0跳过。UI 外层900秒终止（native_exit=-9）；大字号折叠再展开用例在原共享10秒内等待耗尽；关闭设置、滚动后退出用例仍未同时满足退出/设置可点击，退出点击未执行。UI 日志有87组两次隐式重试，可支持减少缺失控件解析成本，但不能证明产品动画/FPS瓶颈。

xcresult 附件导出64，元数据 reader 报 MinimalTSCBasic.FileSystemError error 3；没有取得可用当前截图/AX附件，不能据旧附件认定点击被遮挡、保存丢失或产品无法修复。

## 实现

- 标题栏使用稳定外层 ZStack，仅可见时挂载原退出按钮与标题。按钮 action、busy/interaction gate、focus、DEBUG probe、44pt、标题高度、padding/fill 原样保留。原160ms/6pt仅局部过渡，Reduce Motion关闭过渡动画；不改变正文 viewport、sheet、模型或路由生命周期。隐藏保留控件是候选假设，不是已经证明的退出根因。
- XCTest 先 exists 再 isHittable，避免对不存在对象触发隐式解析；单次保存 targetFrame，不反复读取同一帧；设置/目录入口复用 revealDockControl 的现有可点击及中心位于可视工具区证明，不再立即重复同一个 waiter。真实 tap 和最多3次工具内慢速滚动保留，不新增正文点击、重新打开/启动或预算。
- waitHittable 的格式谓词改为明确短路闭包，仍是 exists AND hittable、同 timeout、相同 XCTAssertEqual。

### 97断言语义映射

| 原断言 | 新断言 | 关系 |
|---|---|---|
| 大字号折叠后/初始紧凑态 collapse.isHittable 为 false（两处） | collapse.exists 为 false | 更强：不只是不可点，而是非活动树不存在 |
| 展开后 expand.isHittable 为 false | expand.exists 为 false | 更强，且与现有 collapse.exists && !expand.exists 一致 |
| 设置面板中 exit.isHittable 为 false | exit.exists && exit.isHittable 为 false | 等价；不存在对象不可能可点击，避免解析不存在对象 |
| 可视中心断言读 button.frame 的 midX/midY | 同一次 targetFrame 的 midX/midY | 相同真实对象/可视区域条件，帧只读一次 |

其余断言逐项比较保留；静态97调用不是97项测试。整个严格 App 切回用例逐字不变（一次新鲜中央点击、PID/锚点/window/update断言）；exitReader、showTools 两 helper 逐字不变，包括退出与设置同时可点击/共享10秒和惯性10+10秒协议。Host480/UI900/case180/open20秒不变，不跳过/标记已知失败。

## 诊断构建门禁

新增 `c-exit-recovery-2f962b6-exact5`，复用 host_validation_run_id，原输入默认/权限/旧分支/构建/资源/依赖/unsigned检查不动。固定唯一父、192→194完整工作区/index/commit对象相等、其他189对象不变、main手动attempt1及同源Task3原生运行。

上游只有UI step16可失败；准备/Core25/Domain93/Block6/measurement1/Host9必须成功，后续门禁/设备步骤应跳过。读取既有token的API回执和唯一原始证据artifact，验证size/digest/安全ZIP/CRC/源码子集/逐用例事件/退出码/回执身份。签名CDN下载不转发Authorization，不重试或增权。

- 完成UI断言分支：9个真实完成case，native65，每个失败原因须为其自己区间内的源码XCTAssert/XCTFail；所有error行归属，拒绝混入自动化/编译错误。
- UI超时分支：真实900秒/-9/timed_out，允许最多一个未完成case及未执行case，不制造通过；至少真正开始UI，拒绝未知/重复/重叠/跳过事件和未归属error。
- 附件分支：9UI通过/native0但已核实附件导出非0，不能当完整回归成功。

固定Xcode16.4/16F6、Swift6.1.2（语言6.0）、XcodeGen2.46.0、iOS16.6；官方GRDB7.0.0/revision4de97e6903d29697caae1179cdef8479c64c2639及原Package.swift哈希保持。

## 验收与实机记录

Windows本地检查仅证明范围/合同/映射/门禁，不能证明Swift编译、UIKit可点击、设备视觉或帧率。原生及IPA结果存ignored artifacts，不为结果另提交。IPA交付前独立核验源码/运行/Release资格、archive/checksum、ZIP/CRC、实际plist/资源、arm64/iOS16.6、unsigned、依赖闭包和官方GRDB资源/静态链接；交付原始字节，不换旧包或重签重包。

iPhone13/iOS16.6.1由用户操作（已有备份为用户报告，未检查）。现有TrollStore/文件/录屏，仅合成TXT，不卸载、不清书库、不删除原书/进度，不能保证覆盖安装零风险。先确认包SHA/run，再录静止状态dock展开一次/收起一次、大字号工具内滚动、设置关闭-正文滚动-显示工具-退出、切App回来一次新鲜中央点击，随后合成书保存/重启/目录/末行/sidebar/theme；首个异常停下记录步骤、点按数、预期/实际、可见错误和录屏时间点。区分口述、实际看过的录屏、未执行；人工操作不能证明XCTest isHittable、同PID、精确44pt/0.5pt或FPS。助手不能直接操作该iPhone，未得到实际操作反馈前保持待执行。
