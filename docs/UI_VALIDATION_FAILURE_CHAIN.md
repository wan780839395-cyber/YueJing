# UI原生失败优先级与非验收时间记录

## 目的与边界
本批仅修改测试执行/诊断链，不改变App、UI用例、工具布局、路由、TXT或保存行为。当前手机13项手工检查均由用户反馈正常；这不是XCTest或完整146项通过证明。

已有完整运行41573803328/attempt1（提交a6bb53a）为142通过、1项UI未完成、3项Canvas未执行、0跳过。UI套件900秒超时、原生退出-9，随后附件导出64。新分类不得改写这些历史结果。设备诊断IPA仍为TESTS NOT RUN/full regression NOT PASSED资格。

只读日志显示首例前约226.55秒，其中测试Runner启动请求到回执135.409秒；UI步骤本身无SwiftCompile/Ld行。具体启动慢的内部原因未知。本修复不声称改善启动速度、消除超时、修复xcresult或提高FPS。

## 修改路径
- `scripts/run_reading_ui_tests.py`：UI协调函数及有界时间记录器。
- `scripts/check_ui_result_failure_precedence.py`：仅离线的合成检查。
- 本文档。

原`stream_native`、`export_ui_evidence`、`count_log`保持原文。`run_native`仅UI分支转到`_run_ui_attempt`；Host分支还原后须与原AST一致，其他命令、预算、来源和计数逻辑保持。

## 两层结果及优先级

| 实际情况 | 结果 |
|---|---|
| Popen、流读取或wait等原执行异常，再有导出普通异常 | 原执行异常对象与traceback继续传播；导出错误单列 |
| 原生timed_out=true（包括-9）且导出失败 | 主因NATIVE_TIMEOUT，导出次失败及实际导出码仍可见 |
| 原生非零退出且导出失败 | 主因NATIVE_FAILURE，不把65等原始退出改成别的原生码 |
| 原生返回字段类型无效/缺失 | NATIVE_RESULT_UNAVAILABLE，不补造成功或退出码 |
| 原生成功但原生收据写入失败 | 原IO异常继续传播，不能进入计数通过门 |
| 原生成功但导出help/命令/manifest/PNG/AX检查失败 | ATTACHMENT_EXPORT_ERROR，整体仍失败 |
| 原生及导出均正常 | 只返回原生结果，随后仍须通过原有完整计数和来源检查 |

普通失败仍由现有Python入口非零退出；原生-9/65保留在各自收据中，不等同Python脚本退出码。KeyboardInterrupt、SystemExit等控制异常不聚合成普通ValueError、不转为成功；按原生、收据、导出阶段顺序优先透传已捕获的控制异常。普通导出异常不覆盖更早的原执行异常。

原有收据保持：
- `YueJingUITests-exit-code.txt`：真实原生退出。
- `YueJingUITests-execution.json`：原选择/来源及真实native_exit、timed_out。
- `attachment-export-help.json`：help是否可用及其退出。
- `attachment-export.json`：导出native_exit、export_exit及导出自己的timed_out。

导出收据的timed_out=false仅说明导出没有超时，不推翻原生UI timed_out=true。导出码注释只从匹配本次source/run/attempt/target/native_exit的已有收据读取；不匹配或不可读就显示未知，不能用于通过判定。

保持一次原生执行、一次导出入口调用；help失败时原逻辑不继续交付真正导出命令。help30秒、导出120秒保持，无重试、无补造manifest或附件。原生结果收据先写，再尝试导出；原执行未返回时不编造execution收据。

## 时间sidecar
未来真正运行UI时，新增`YueJingUITests-process-timeline.json`，放在既有证据目录；当前工作流已经归档该目录，无需改工作流。

- `kind=NON_GATE_UI_PROCESS_TIMELINE`，`schema=1`，`acceptance_role=none`。
- 记录固定事件名、序号、UTC、monotonic和有界整数/布尔值。允许的身份字段仅source_commit、run_id、run_attempt、target。
- 原生观察点：Popen请求/返回/失败、timer启动/回调、已有poll结果、kill前后、stdout EOF、wait前后、流返回/异常、清理。
- 另记首个测试START被观察到的时刻、stdout行数、原生收据写入状态及导出前后。它们不是用例START/FINISH真值，也不是测试通过证据。
- 不记录stdout正文、书名/正文、任意字符串参数、完整命令、环境或Token。
- 最多64个事件、序列化总量最多16KiB；超过容量明确truncated和丢弃数量，时钟失效标unknown，不写NaN/Infinity。
- 使用短内存锁保证序号；计时器回调不写盘、不启动子进程、不增加poll、信号、等待或重试。
- `finish()`只是标记原生流结束，不封闭记录器；导出完成后才统一独占创建sidecar，不覆盖已有文件。
- sidecar写入失败只作非验收观察未知，不能改变主结果；写入中断可能留下不完整JSON，此时不得把它作为有效观察。
- UTC用于关联日志，耗时使用monotonic；`late_events_possible=true`明确不保证捕获所有异步尾部事件。外层强制终止时也不保证产生sidecar。

原timer调用位置、Host480/UI900秒、单用例180秒、工作流UI18分钟及job35分钟均不变。观察本身不是零开销，也没有测得性能改善。终止仍使用原process.kill，不在本批凭推测增加宽限期或改变信号。

## 离线验证

使用已有Python标准库，无新增依赖。例如从仓库根运行：

```text
python -B scripts/check_ui_result_failure_precedence.py --self-check
```

可以追加：
- `--baseline <本批冻结的原run_reading_ui_tests.py>`：比较原函数原文；不执行该文件。
- `--evidence <已下载的41573803328 reading-ui-native目录>`：只读历史收据和固定SHA原始日志，保留超时失败分类。

检查器只AST选取被测函数/类，不导入或运行执行脚本顶层。原生工具交付由拒绝桩或明确的假对象替换；临时项目、日志和合成附件使用scratch/临时目录并清理。合成PNG仅用于测试原检测器的字节签名分支，不是可视截图或真实图像验收；合成AX明确按macOS的UTF-8 LF写入，避免Windows CRLF误差。

覆盖：
1. 超时/nonzero/正常退出与导出成功、64、help失败的组合。
2. Popen/读取/wait异常、收据IO异常、原生及导出阶段取消。
3. 缺失/重复/跳过/失败/未知/未完成身份，以及缺manifest、PNG或AX。
4. 原stream_native的Popen次数、原poll/kill、计时器数值、关闭与wait行为。
5. 时间记录容量、并发序号、隐私、独占写、时钟失效、UTC跳变和诊断IO隔离。
6. 实际run_native在假工具环境下的Host/UI成功路径和最终计数门。
7. 故意吞掉失败、削弱计数门、重复交付原生命令的错误实现必须被检查器检出。
8. 历史900/-9+导出64仍归原生超时；未完成原始日志不能通过计数门。

输出`SYNTHETIC_NOT_NATIVE`及逐项结果。数量以实际输出为准，不是Swift用例数。原9项UI、97断言、147声明/146选择不变；不得将合成测试与真实原生回归相加。

## 原生验证仍须另批批准
本次本地修改和检查不包含commit、push、Actions派发、原生执行、重导出或IPA构建。Windows合成验证不能证明Xcode、UIKit、实际导出或完整146项通过。

后续只有在另外批准的同一完整运行中，146项逐项真实通过、零跳过，计数/来源/附件有效，才进入实际设备Release编译及同源IPA独立校验。任一步失败保留首错并停止，不自动修补重推或重跑，不把补跑剩余用例拼接为一次完整通过，也不自动沿用旧诊断例外。
