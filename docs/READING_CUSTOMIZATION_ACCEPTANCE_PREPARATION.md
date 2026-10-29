# 排版候选：本地验收准备交付（2026-10-29）

## 状态与授权边界

**本批仅本地验证准备；Swift/Xcode编译、原生单元/UI/Canvas测试及真机验收均未执行。没有新的候选提交SHA、CI run或IPA。**

基线HEAD：`edce5c2302563e228ad35d8e30dd2532389daf87`，App版本0.1.0(1)。候选身份是该HEAD加当前工作树差异及文件SHA-256，不能把HEAD的历史结果当成本候选结果。原129项历史128通过/1失败仍保留；原UI滚动后退出按钮可命中断言未删除、放宽或延长等待。本说明不宣称修复其根因。

本次批准仅同步Task3验证配置、必要清单/脚本、排版与续读测试及说明。不修改产品代码，不安装依赖、不提交推送、不触发CI、不构建设备包、不操作设备或读取密钥。旧实现说明保留，见 `READING_CUSTOMIZATION_LOCAL_IMPLEMENTATION.md`。

## 修改文件与职责

- `.github/workflows/task3-validate.yml`：从冻结清单取得选择参数，运行新增4项Domain预设测试及原3项Canvas，同次聚合后才保留原有设备App/IPA门。仅修改配置，未运行。
- `scripts/task3_test_inventory.py`（新增）：逐文件、逐函数名的独立预期清单；维护分组、固定预期数量、选择参数及独立性能基线排除理由。清单不是由原生通过结果生成；源码漏项/新增/改名/重复均拒绝。
- `scripts/validate_task3.py`：冻结候选源码与清单指纹；各组按同SHA、run、attempt、清单、实际日志和退出码复核；聚合及打包复核整个唯一用例集合，不再依赖散落的89/90/121/129常量。追加Canvas真实App-host设置核对。
- `scripts/run_reading_ui_tests.py`：两App测试组共用冻结清单，预期2项host＋8项UI；保留原串行运行、超时、失败证据、原生附件导出和无跳过要求。
- `Tests/YueJingUITests/ReadingFlowUITests.swift`：仅追加两项验收和一个有界滚动辅助函数。原六项测试及原辅助函数保持。
- `scripts/check_task3_validation.py`（新增）：离线清单、脚本、工作流文本/选择顺序、shell语法及聚合门合成证据正反例；临时证据仅进入系统/会话临时目录，绝不放进真实原生结果目录。
- 本说明（新增）：范围、映射、实测离线结果及原生验收缺口。

既有排版产品候选7份源码/测试保持原字节；未修改App、Sources、project.yml、数据库、TXT内核或原Canvas测试。用户看板、架构师脚本/记录及Skills/lock不纳入本批发布范围。

## 最终逐用例映射与数量口径

逐文件逐函数名的权威预期清单在 `scripts/task3_test_inventory.py` 的 `FILES`；不是仅检查下表总数。该脚本以声明解析结果逐文件逐项比较，并检查纳入集合无重复；带 `@Test(.timeLimit(...))` 的性能声明也纳入排除清点。

| 执行组 | 预期项数 | target / 配置 / 选择边界 |
|---|---:|---|
| TXTCoreTests | 25 | TXTCoreTests / Debug；排除TXTBlockDecoderTests，原25项不变 |
| ReaderDomainTests | 93 | ReaderDomainTests / Debug；原89＋预设4，排除ProcessingReuseMeasurementTests |
| TXTBlockDecoderTests | 6 | TXTCoreTests/TXTBlockDecoderTests / Release；原6项不变 |
| ProcessingReuseMeasurementTests | 1 | ReaderDomainTests/ProcessingReuseMeasurementTests / Release；原串行合成测量不变 |
| YueJingHostTests | 2 | YueJingUI scheme真实App-host / Debug；原2项不变 |
| YueJingUITests | 8 | YueJingUI scheme真实App UI / Debug；原6＋本批2 |
| YueJingCanvasTests | 3 | YueJingCanvas scheme真实App-host / Debug；原3项首次并入Task3同次门 |
| **纳入集合** | **138** | **原129＋排版预设4＋Canvas3＋新UI验收2；全部逐项真实执行且零失败/跳过/未执行才通过** |
| 明确排除：TXTCorePerformanceTests | 1 | `automaticDecodeAndChaptersBaseline`；独立大文件性能基线，不属于本次排版验收，不运行其专用workflow |

前轮136是新增UI验收前的133＋Canvas3；全仓当时137还包含独立性能1。当前因新增UI2而变为纳入138／全仓声明139。声明、计划选择和真实执行结果始终分开；本轮原生执行数仍为0。

### 原有4项排版纯值测试（不改断言）

1. `presetsKeepTheCurrentThemeAndStayWithinExistingRanges`：预设范围、唯一匹配和全主题保持。
2. `standardRestoresExistingTypographyWithoutForcingThePaperTheme`：恢复默认数值且保持背景。
3. `customTypographyDoesNotClaimToMatchAPreset`：自定义不误选预设。
4. `applyingAPresetKeepsTheOriginalPreferencesJSONContract`：既有偏好JSON合同。

### 本批新增2项UI验收（尚未原生执行）

- `testTypographySliderPresetsAndConfirmedRestore`：字号滑杆14/36边界、加减禁用、行距20边界、三预设选中和主题保持、恢复默认取消/确认、自定义退出预设、同书重开偏好保持。
- `testTypographyAndChapterSurviveProcessRelaunch`：定位第33章→深色宽松预设→正常保存退出→另一书→终止App并在同一合成夹具UUID/临时数据库下重启→核对第33章仍为当前章以及24/10/深色/宽松保持。夹具继续走既有重复导入保护；不访问或清理真实用户书库。保存后正常终止不等于保存中崩溃或强杀恢复。

进程重启UI用例验证的是当前章节级别的非开头位置恢复，**不宣称精确到字节/行内像素位置**。原Domain版本化锚点回归保留；真机精细位置和视觉稳定性仍需单独验收。

## 门控与候选来源

原生运行前先核对源码声明与冻结清单，再保存App/Sources/Tests/scripts/workflow/project定义的SHA-256及运行标识。执行期间、聚合时、打包前重新核对。Swift组解析器要求正确唯一用例、原生退出0、成功摘要和`TEST SUCCEEDED`，拒绝缺项、重复、意外项、失败或跳过。App runner继续逐项验证Swift Testing/XCTest日志与原生附件；原超时没有延长。

CI固定macos-15/arm64、Xcode16.4/16F6、Swift6.1.2（语言6.0）、XcodeGen2.46.0、GRDB7.0.0、部署iOS16.6；只手动workflow_dispatch、attempt1，串行、失败即停、不得自动重跑。独立ios-build工作流仍保留旧父提交/白名单限制，不改、不用作本批替代。

CI checkout只能验证远端提交。未来如获准执行，须先白名单提交/推送当前候选，记录对应提交与冻结文件清单；不能在远端旧HEAD运行后声称验证了当前未提交文件。本地Mac快照验证同样必须明确dirty文件指纹，不得仅标HEAD。当前CI冻结入口要求已提交且工作树干净，不能直接拿来验证本地dirty候选。

## 本轮实际离线验证

执行 `python -B scripts/check_task3_validation.py`，结果：

- 13项清单/脚本/工作流/聚合门检查通过：逐项源清单及唯一集合、4份Python AST、工作流选择/配置/顺序/原超时文本检查、15个shell块的Git Bash `-n`纯语法解析、合成7组聚合接受，以及旧SHA、旧run、错误89预期、错误选择、漏Canvas项、重复Canvas项、跳过、源码漂移拒绝。
- 共享Swift日志解析器40项合成正反例通过；App日志解析器12项合成正反例通过。
- 单独执行清单自检及App runner `--preflight --self-check`均退出0；`git diff --check`退出0。
- 修改前指纹已记录；13项既有候选/用户文件指纹复核一致。移除新增UI区段后，原六项流程和原全部辅助函数与HEAD文本完全一致（统一换行后比较）。已跟踪差异只包含本批四个目标及原有三个产品候选文件。

以上是Windows离线脚本/文本/合成证据检查，**不是Swift语法或类型检查，不是XcodeGen生成、Xcode编译、原生测试、App交互、性能或真机通过结论**。本机无YAML库，未安装；工作流仅做文本映射与shell块语法检查，完整Actions配置解析仍待后续获准环境。

## 剩余验收与授权

后续先独立审查本批差异；审查不等于原生通过。需要用户另行批准获准Mac或当前候选白名单提交/普通推送及一次现有Task3运行。安装/准备依赖、设备App/IPA、真机操作均须在新的明确批准范围内，本轮未执行。

原生成功后，仍在iPhone13/iOS16.6.1验收：

1. 横竖屏、最大辅助字体、large/medium面板均可滚动到所有控件与完成，44点控制可达；VoiceOver调整、焦点与Escape正确。
2. 拖动过程中只变示例和数值，松手才实际重排；字号14–36/行距0–20边界，加减一档；示例不承诺与CoreText正文同断行。
3. 深色下三预设及默认确认/取消正确，自定义不误选；诊断/许可返回仍在阅读，书架主题不受污染。
4. 拖动中关闭、切后台、快速重开不让旧草稿迟到覆盖。正常退出/同书重开/换书/进程重启后应用偏好保持，恢复同一语义文字位置，不明显跳回章首或开头。
5. 正文重排、工具显隐不留位；滚动后退出按钮仍可命中。保留历史失败证据，不把新包出包成功当修复证据。

大文件冷启动、首绘、RSS、强杀/崩溃时保存以及精细行内位置不是本批离线验收结论。当前产物仅为未提交源码/配置/测试和本说明，无新IPA。
