# 场景邻章修复发布：0.2.7 / build9

## 本批范围

基线 `6960385c20f35c35f45a3bf61b307e8bf2e584af`，沿用既有Task3/epub_freeze作业，scope为 `epub-scene-24`。用户批准发布/验证/IPA及范围内具体失败修复，逐项失败继续独立工作，终态汇总；不放宽断言或预算。

精确12路径由 `run_epub_freeze_validation.py:ALLOWED` 锁定：ChapterWindow、LocationScript、WebView、ResourceStore、EPUBLibraryTests、EPUBReaderHostTests、continuous JS检查，以及project版本、既有workflow、runner、自检、本说明。无新增/删除路径，project.yml只允许0.2.6/build8→0.2.7/build9；不得夹入用户私有文件、Skills、原书或artifact。

产品变化：
- 紧邻下一章优先、逐章预载，近章不再等待远处图片整批完成；窗口实际有进展才继续，当前窗口补齐后才考虑扩大，64章/40MiB限制保持。
- 同坐标延迟scroll去重，真实滚动仍节流；局部窗口滚动条隐藏，不改变纵向滚动能力。
- 同DOM配置不重复发送完整bootstrap；新文档才初始化。
- SHA256算法/完整字节校验不变，仅十六进制输出减少String(format:)中间分配。复开仍需完整校验与新WebView排版，不承诺秒开。

## 最小充分测试

选择保持18个Domain、3个Host、3个EPUB UI，24个函数身份/25次展开执行；Domain含一个Bool参数双值。全清单222身份/223展开不变，不运行未受影响的198次。

- Domain：资源读与摘要/源变化/损坏拒绝、暖目录复用、独占归属、取消/关闭/进度/设置/EPUB2图片复开，包含新增标准摘要断言。
- Host：资源加载/UTF16恢复、图片页、排版与导航；后者含逐章规划和滚动条断言、连续窗口及目录跳转。
- UI全3：目录/跨章/同进程复开，进程重启进度恢复，设置/无封面/TXT隔离。原断言保持。
- JS辅助：本地生产JS/CSS的16项synthetic/static、18组Chromium检查，已有源码指纹匹配才引用；不能代替Swift/WKWebView/真机。

## 执行与交付合同

1. 单项独立xcodebuild与selection/execution/log/xcresult/counts目录；准备/编译/断言/超时失败记录后继续下一项。取消、源码身份漂移及共同前置失效不会被吞掉。
2. 480秒调用、180秒测试、120秒boot、60分钟作业预算保持。原始输出直写日志，进程组有界清理，不因PIPE遗留阻塞后项。
3. 设备Release提前独立编译；设备失败不阻断依赖已具备的模拟器测试，测试失败不阻断已成功设备的打包验证。各分支依真实step outcome，不以全局success误判依赖。
4. Actions始终显示24选定项和15项UI完整清单，12项独立TXT/通用UI明确not_selected。passed/failed/timed_out/error/blocked/not_run区分，失败不伪写为skipped/pass。
5. 正式 `release_gate()` 仍要求25次真实通过及原始事件、参数xcresult叶、设置、source/run/command完整匹配。汇总表不等于正式资格。
6. 显式 `allow_unqualified_ipa=true` 与原workflow_dispatch输入、环境和scope事件摘要一致时，允许测试未全过的诊断交付；默认false。只有源身份、固定工具链/依赖、真实device构建、WebKit linkage、设备完整性与IPA逐文件字节全通过后才写 `epub-freeze-package.json`。
7. 未全过包标记 `DEVICE_DIAGNOSTIC_ONLY / UI_NOT_QUALIFIED`；计数不确定用null并列known/unknown分支，不以计划数冒充执行数。工作流可因测试保持failure，同时上传真实已校验诊断IPA；没有隐式刷绿。
8. arm64/iOS16.6/unsigned、实际Release二进制、动态依赖图、7项SwiftSDK证明、资源/许可证/图标/清单及IPA字节门不削弱。不换工具链/依赖，不新凭据或权限，不force。
9. 下载核验artifact SHA、ZIP CRC/安全路径/成员哈希；独立复核原始测试和实际Release字节，交付复制后再验IPA摘要。结果只存ignored artifacts，不为结果再推送。

## 检查入口

`python -B scripts/check_epub_freeze_validation.py` 为离线门/故障注入自检，不计原生通过。实际受测结果须读取本次同SHA原始证据。旧0.2.6失败与成功项不改写成本轮结果。

后续仅调用既有Task3 `validation_scope=epub-scene-24`，明确绑定本次批准的诊断许可。失败先保存证据，只修复具体范围内缺陷，不做无假设多轮循环。

## 真机验收

交付YueJing-0.2.7.ipa，使用既有TrollStore覆盖安装，不卸载/清库/删书/强制重导入。重点：3简介→4场景图一及前后相邻章自然滚动、目录前后/快速跳章、无异常滚动条跳动、同进程复开及进程重启后位置恢复。记录资源准备和排版摘要，不把本地夹具或编译成功当作原书真机问题已全部解决。
