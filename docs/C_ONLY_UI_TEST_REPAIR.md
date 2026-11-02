# 唯一 C：UI 测试适配与前台等待修复

## 范围与依据

用户批准：`批准3文件修复及一次完整原生验证，通过后打包IPA`（消息ID不可用）。基线为 `38d6293321e829a7026afd23e6e738f40aa238ae`。仅修改 `Tests/YueJingUITests/ReadingFlowUITests.swift`，新增本说明与 `scripts/check_c_only_ui_repair.py`；不修改 App、Sources、ReaderScreen／Viewport／Controller／ViewModel、场景恢复、手势、工具状态、导航、数据库、测试清单、工作流或依赖。

上一轮 Task3 `41417052271/1` 的真实结果为134通过／9项UI失败／3项Canvas未执行，未打包。8项停在旧helper等待 `reader.tools.settings` 可点击；代码和原始UI日志中没有 C 展开／收起控件操作。另1项在 `app.activate()` 与 app前台等待后，即时断言系统设置已不在前台而失败。失败证据保持不变；未据此判定全部生产功能失败，也不把这些源码缺口当成已完成原生修复证明。

## 测试改动

1. **真实使用 C 入口**：初次开书在原有20秒共享期限内等待折叠态控件可点击，真实点击 `reader.tools.expand`，确认 `reader.tools.collapse` 可点击且展开入口不可点击，再保留原排版按钮就绪断言。目录／排版helper也先核对C展示状态，必要时仅点击一次可见展开按钮，不使用隐藏AX Invoke、坐标兜底或重开书。
2. **补充 C 自身回归**：在既有重复面板用例中实际收起、核对隐藏排版控件／44pt入口／viewport不变，然后重新展开并继续全部原有面板与辅助页断言。不新增测试身份或把旧断言替换为状态常量。
3. **前台状态等待**：在原返回前台10秒总期限内，先等待阅境前台，再通过只读公开 `XCUIApplication.state` 连续两次观察阅境前台与系统设置已后台／挂起／退出。每次用前后两次阅境state读取包围系统设置读取，非匹配清零，保留最后4组数值与wait结果用于原始日志。它是顺序观察，不声称原子状态快照。
4. **保留恢复门槛**：原即时 `XCTAssertNotEqual(settings.state, .runningForeground)`、同PID／同阅读器／同正文位置，以及返回后一次新鲜中央点击同时恢复header和dock、后续字号与跨章窗口实际变化的断言不删除。返回后不得调用C展开或showTools helper补救，不增加第二次中央触摸。测量前通过正常C入口展开；未另声称覆盖折叠态跨App专项场景。
5. **一般惯性helper**：仍最多允许原有两次中央触摸（第一次可能只停惯性，第二次才显示），共享原10+10秒额度；改以可见C入口／收起按钮判断工具组，而不是把“排版按钮未展开”误当“整组工具隐藏”。这不改产品的先停惯性规则，也不替代恢复用例的严格单触断言。

UI测试仍为XCTest，遵守Xcode16.4／Swift6.1.2语言6.0／iOS16.6。无skip、known-failure、增加预算、私有AX、Timer/sleep、重新启动／重开书、强制改应用状态、C默认自动展开或生产手势补丁。原9项UI身份／146项总选择及Host480／UI900／case180／开书20／共享退出10秒预算保持。

## 本地与原生验证

本地入口（Windows，仅文本和哈希）：

```text
python -B scripts/check_c_only_ui_repair.py --baseline artifacts/c-only-ui-repair-local-20261102T094529942713Z/baseline.json --self-check
python -B scripts/task3_test_inventory.py --self-check
python -B scripts/run_reading_ui_tests.py --preflight --self-check
```

专用checker对照真实前像的明确全文转换、原断言集合（仅一个前台wait参数改为原10秒剩余期限）、严格单触恢复段、C真实控件操作、预算及测试身份，并检查范围外保护哈希／HEAD／index／staged／diff。负面对照只在内存进行；不是Swift AST、编译或UI执行。全部生产源码哈希须保持基线，历史C源码checker与旧三布局checker不修改或借用为当前通过证明。

本批完整结果应以 ignored artifacts 的本地报告、命令stdout/stderr/退出码和后续同提交原生证据为准。仅一次普通commit/push及现有Task3 `full` workflow_dispatch／attempt1，25Core+93Domain+6Block+1测量+9Host+9UI+3Canvas=146项全部实际通过且无跳过，才继续同run设备Release arm64/iOS16.6 App编译、未签名IPA打包与独立核验。任一准备／检查／编译／计数／断言／打包失败即停，不自动修补重推、rerun或追加dispatch，不拿旧Host或旧IPA替代。本说明不预告原生通过，更不代表真机FPS／卡顿或全场景验收。
