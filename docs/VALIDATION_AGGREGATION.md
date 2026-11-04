# 验证策略：独立组继续执行，统一汇总失败

本次用户要求将“第一个错误后停止整批”改为“继续检查全部独立项目，一次汇总发现的问题”。本修改仅限验证链，本地实现/离线检查，不授权新的提交、推送或 Actions 运行。历史批次的失败报告、额度及原始日志不改写。

## 提前终止原因

1. `task3-validate.yml` 中测试组以 `success()` 为条件，Host 还使用隐式 success 条件。一组 xcodebuild 返回非零后，其他无依赖测试组均被跳过。上轮 Domain 虽然跑完 138 项，后面 42 项仍因此未执行。
2. `validate_task3.all_test_evidence` 和 `audit_native_case_events.audit_evidence` 在循环内遇到首个校验异常直接抛出，后面组/收据无法检查。
3. 旧事件解析器把 Swift Testing 的 `recorded an issue` 断言详情误列为未知事件，造成额外的不完整审计标记。

## 新行为

- 共同准备（范围、工具链、工程、依赖、模拟器、冻结候选）全部成功后，8 个测试组按原顺序串行执行各一次。后续组不再依赖之前测试组成功。
- 使用显式 `!cancelled() && steps.candidate.outcome == 'success'`；不设置 `continue-on-error`，不使用 `|| true` 掩盖错误。每组原始退出码和失败状态保留，不重跑。
- Core/Domain/Block/measurement/Host/TXT UI/EPUB UI/Canvas 数量保持，总选择 205、声明 206。原 480/1200/480 秒组预算、单例 180 秒和 job 60 分钟不扩大。
- 各组内部有数据依赖的操作仍受保护：无有效工程/依赖无法真实编译；未运行成功不能生成绿色计数收据。错误不会阻止其他独立组执行或最终审计。
- 总门逐组收集严格校验错误，并分别审查事件链；一个组的坏文件不会短路其他组。失败时也保存 `native-test-gate.json`，返回非零。
- 原始审计分别读取日志、退出码和每份收据，捕获对应错误并继续；失败用例、跳过、未执行、未结束、歧义、来源不符、坏 JSON/UTF-8 均不当作通过。
- `recorded an issue` 绑定到准确用例，保留原行。出现问题却报告绿色结束时判为歧义；未知身份仍拒绝。
- 最后始终尝试生成 `artifacts/task3/validation-summary.json` 和 `.md`，同时写入 Actions Job Summary。包含所有组、失败用例、断言/编译错误的日志行位置、证据校验错误、准备/构建/打包步骤状态。
- 设备编译、打包仍要求整体成功且全 205 项严格门通过，不允许失败后的诊断出包。末尾汇总失败也会阻止 IPA 上传。

## 边界

“继续所有项目”指所有准备条件已满足的独立验证组，不是忽略错误去运行不安全或缺依赖的操作。用户取消、runner 丢失或 job 硬超时可能让后续步骤（含汇总）无法执行；有机会汇总时明确列为取消/阻塞/未执行，不能声称已检查。编译失败时也不能运行该组未生成的测试二进制。

本轮未修复上轮 EPUB 路径用例，不修改 Swift 业务代码或原生测试断言，不用合成检查代替真实 WebKit/Xcode 验证。

## 本地验证入口

```text
python -B scripts/check_validation_aggregation.py
python -B scripts/check_task3_validation.py
python -B scripts/audit_native_case_events.py --self-check
python -B scripts/run_reading_ui_tests.py --preflight --self-check
```

新增离线回归读取实际 workflow 条件并验证：
- 多个组及同组多个用例同时失败，后续组仍检查，全部失败用例同时输出；
- UTF-8、JSON、退出码、来源四处同时损坏，不中断后面组；
- 总门多组错误均返回，失败收据先保存再返回非零；
- 准备失败、取消及缺证据明确失败，不能出包；
- 全205合成正向对照仍可通过，断言详情不被误报为未知事件，也不能让失败变绿。

这些是隔离合成文件的 Python 回归，禁止启动原生进程。新的真实云端完整验证仍需单独批准。
