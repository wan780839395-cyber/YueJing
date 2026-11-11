# EPUB opening continuity 定向复测与严格交付

当前目标：0.2.15 / build17；基础实现基线 `d5fde953ca544deaecace0434a45b014ebd630b0`。本批打开计时、加载与呈现并行、轻量反馈和资源分段计时说明见 `EPUB_OPENING_PRESENTATION.md`。

## 当前复测范围

`epub-opening-followup-3`：新执行3个用例身份、4个展开项：

- `domain-12`：`epubDamagedClosedWorkspaceFallsBackWithoutTrustingMtime`，Bool false/true两个叶。
- `host-2`：`epubOpeningRouteStartsOnceAndObservesMountedPresentation`。
- `ui-2`：`testEPUBProgressSurvivesExitAndProcessRelaunch`。

另严格复用固定历史 run `43014129792/attempt1` 中已通过且不受本次修改影响的21个单展开用例。历史源码 `3f16c2963f2d165f80500d9b23eb4036ff919260`；artifact `13853970619`、129375479 bytes、SHA256 `20bcce9f3167691818fb454e2900de70a90de4734f4f77ee3e952e2ebd10f2e5`。历史run整体失败，不能把整个run认作通过；只核验明确通过的21项。

组合覆盖仍为24个身份/25展开；全库241声明/242展开中217展开未选择。不是全量回归。

## 历史与修复边界

- 初轮 `43010590017`：24条独立命令均exit65，测试体被编译失败阻塞。长诊断摘要类型检查失败及六处Testing宏可变调用错误已在整批终态收集后修复；摘要内容、六个布尔断言、业务逻辑及预算不变。
- 次轮 `43014129792`：21展开通过；Bool用例原生exit0但xcresult计数门异常；新增Host打开呈现用例就绪断言失败；UI进程重启用例在首次打开时正文等待失败，尚未进入重启步骤。不是180秒用例超时，也未证明磁盘缓存丢失。
- 当前仅修正声明数/参数展开数解析，并提前保留原始summary/tests导出；无论summary以声明1或展开2计数，都必须另核验恰好false/true两个成功叶，拒绝缺失、重复、失败与跳过。
- Host只在该失败方法内补充有界只读失败现场诊断，仍抛出原错误；其余所有方法、共享辅助函数及App/Domain/UI源码保持与次轮一致。尚未证实两个就绪失败的根因，不作生产分页或缓存算法修复声明。

## 两阶段

1. 验证：`build_ipa=false`，`prior_validation_run=''`，新执行4、复用21。每个选定命令独立运行，完整批次结束后统一分析；公共前置失败、取消或未运行不能记作通过。
2. 交付：`build_ipa=true`，提供成功、同源码、attempt1的本范围验证run。新执行0、复用组合25，随后实际设备Release编译与IPA检查。只允许固定历史21加同源prior4的受控来源链，不接受任意递归交付证据。

`allow_unqualified_ipa=false`。不以诊断包替代合格交付。编译、原生资格、IPA完整性与真机验收分别报告。

## 严格来源与完整性

校验固定GitHub API来源、原ZIP大小/SHA、成员覆盖、源文件与受选方法、固定依赖、每项原始日志/命令/退出码/计数/xcresult和参数叶；不得重写原receipt或忽略多余成员。xcresulttool仅解析独占临时副本，避免污染原始bundle。复用Host文件只允许该未复用方法的精确诊断差异，共享helper及21项受选方法必须未变。

发布边界维持原19路径/3新增路径；`AppVersion.swift`动态读取Bundle且字节未变。保护用户本地文件与所有旧IPA、原始失败、资源SHA/路径/符链/类型/大小/预算、session/epoch、进度、偏好和TXT行为。4路资源校验、renderer上限3/估算96MiB不变。

## 固定环境与验收边界

macOS15、Xcode16.4/16F6、Swift6.1.2/语言6、XcodeGen2.46.0、GRDB7.0.0、ZIPFoundation0.9.19、最低iOS16.6。480秒调用、180秒用例、120秒启动、30秒工具链探测、60分钟job不变；不安装运行时、不新增凭据或费用。

Windows静态检查与mock不是Swift编译/WKWebView实测。CADisplayLink显示帧机会不是像素首绘；lane累计不是墙钟或CPU；资源计时开销未在真机量化。iPhone13/iOS16.6.1仅TrollStore覆盖安装，不卸载/清库/重导入/直接降级。正确正文可见且立即可交互、常规≤300ms/P95≤500ms及RSS仍待真机测量，迁移单列。
