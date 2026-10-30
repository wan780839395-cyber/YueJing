# App-host 启动阶段取证增强（仅本地）

## 状态与授权边界

按用户批准，仅增强启动阶段取证，保持原超时、断言和完整测试门不变。基线为 `bbc173969f27d2b1ac7ba0bff0f6db8124182a95`。

- 本批仅本地实现及离线检查，**未提交、未推送、未触发 Actions、未安装**。
- **原生执行：0；原生构建：0；未生成新 IPA。** 没有调用 Xcode、simctl、sample 或系统日志工具进行真实取证。
- 上轮 40980806810 的结果仍为 125 通过、13 未执行、App-host 命令 480 秒超时；原 UI 修复效果和超时底层根因未得到新的原生验证。
- 后续公开发布、一次原生验证及条件出包仍需另行批准；本批不自动沿用历史许可。

## 文件范围

只修改一份既有源码，新增两份脚本及本说明：

- `scripts/run_reading_ui_tests.py`：在既有 App-host 命令旁接入可选观察器，并把取证自检接入既有 `--self-check`。
- `scripts/reading_launch_diagnostics.py`：独立、尽力而为的启动观察器。
- `scripts/check_reading_launch_diagnostics.py`：fake Popen/Timer、合成日志及临时文件回归，不启动原生工具。
- `docs/READING_LAUNCH_DIAGNOSTICS_LOCAL.md`：本说明。

**不修改** App/Sources/Swift 测试、版本/图标、工程目标、测试身份清单、`validate_task3.py`、出包脚本或 workflow。现有 workflow 已递归上传 `artifacts/reading-ui-native/`，新增记录沿用该路径，不增加上传任务或权限。

## 取证时机与硬边界

仅 `YueJingHostTests` 创建观察器。UI 测试、Canvas 和附件导出不启动它。

- 先启动原有原生限时器，再启动 daemon 观察线程。
- 启动后约 90 秒，以及原生截止时间前约 40 秒，最多尝试两次观察；若已见到测试输出或原生命令结束，则取消。
- 每次快照命令预算最多 **15 秒**；单条诊断命令最多 **3 秒**，共享快照截止时间，不为每条重置整份快照预算。
- 观察器在原生截止前 **5 秒**的安全边界停止启动/继续诊断命令；测试输出出现、命令退出或 `stop` 时也取消。
- 每条诊断命令捕获最多 **256 KiB**，不使用无界 `communicate()`；额外输出触发未知/截断状态。
- 主测试不 join 观察线程、不等待诊断文件或诊断进程清理。`stop` 只设置 Event；原有测试限时器独立触发。
- 诊断命令使用独立新 session，无 shell；只能清理观察侧自行创建的进程组，不给宿主、xcodebuild 原生命令或 CoreSimulator 服务发诊断终止信号。

这些是源码设置的预算和取消边界，不是已测的 macOS 时延保证。系统调度、工具内部行为、权限和 IO 异常仍可能使记录缺失或不完整，统一视为**未知**。**观察可能影响时序**，不承诺零扰动，也不能用采样本身证明根因。

## 收集内容与作用域

每份快照只读尝试收集：

1. 既有选定 UDID 的模拟器状态，过滤其他设备。
2. 原生 xcodebuild 与固定进程名的 PID、父 PID、状态和运行时长；不抓进程参数或环境。包括 CoreSimulatorService 的完整进程名别名。
3. 在同一选定模拟器内读取 launchctl 列表，查找唯一 `dev.yuejing.app` 服务 PID；相似 Bundle ID、缺失或重复候选不作为确认。
4. 只查询 `TESTMANAGERD_SIM_SOCK` 是否返回值，不保存整份环境。
5. 对进程列表确认的当前 xcodebuild PID，以及选定模拟器服务与进程列表相互确认的宿主 PID，尝试短时栈采样。sample 显式输出至 `/dev/stdout`，不依赖默认临时文件；文本过滤/截断明确标记。
6. 最近两分钟的宿主系统与选定模拟器系统日志，仅保留含选定 UDID 或应用 Bundle ID 的匹配记录。

系统日志消息和栈文本有长度上限；敏感字段记录、URL、用户/私有路径和显式正文/书名字段会过滤。无个人小说、凭据或整份环境读取。此过滤不等于通用日志匿名化保证：真实云端仅限原有非私有合成测试夹具，后续验收仍须检查实际记录内容与可用性。

命令范围无 boot、shutdown、erase、install、launch、调试器 attach、killall 或测试重试。观察器不切换模拟器、不修复环境、不改阅读状态。

## 输出与结果语义

沿用现有证据目录：

```text
artifacts/reading-ui-native/
  YueJingHostTests-launch-diagnostics/
    context.json
    snapshot-1/
      context.json
      device.json
      processes.json
      selected-simulator-host.json
      testmanager-socket.json
      xcodebuild-stack.json
      host-stack.json
      host-system-log.json
      simulator-system-log.json
    snapshot-2/ ...
    finished.json
```

记录带源 SHA、run/attempt、目标、选定 UDID、native PID、观察截止时间和 `acceptance_role: none` 等上下文。顺序记录不是原子快照。

- 工具失败、超时、超出输出限制、PID 不确定、JSON 不完整、线程/文件不可用等只影响观察数据，写为 `unknown` 或保留缺失状态。
- 观察数据从不生成 `native_passed`、`tests_passed`、成功 counts 或聚合门文件。
- 缺少快照/finished 文件不是通过或失败证明；若 App-host 很快开始测试，可能在第一次观察前就停止。
- runtime 观察异常不会替换原生退出码、原生 `timed_out` 或原日志；没有吞掉原生错误的处理。

## 保持不变的验收合同

- Host 总预算 **480 秒**，UI 总预算 **900 秒**；单用例默认/最大 **180 秒**。
- 原生 `threading.Timer(timeout_seconds, expire)`、超时时 kill 原生命令、原始退出码/超时记录路径保留。
- 原始 `count_log`、所有 Swift/XCTest 断言、过滤参数、串行设置、无跳过/缺项/重复要求保留。
- 原有 **138** 项完整集合与顺序、聚合门、设备 Release 条件构建、打包和校验门均不变。
- UI 回归中的双控件就绪断言、真实退出点击、返回书目可点击断言及十秒总预算没有再修改。
- 新脚本会被既有 candidate source hash 冻结逻辑纳入；未来提交时必须与 runner 一同发布，不能只传一个文件后运行旧远端。

## 实际已执行检查

全部为 Windows 离线检查，不是 Swift/Xcode 通过结果：

- 取证自检 **61 组**通过，涵盖作用域/敏感记录过滤、设备/进程/PID 解析、观察命令失败或挂起、输出限制、读取失败、诊断子进程的独立 session、测试输出取消、默认预算、异常保留原退出码与原超时，以及阻塞观察线程不导致主 stream join。
- 既有 gate/workflow 离线自检 13 组、Swift 日志解析合成样本 40 组、App 日志解析合成样本 12 组通过；原 App parser 数量没有合并取证自检。
- `run_reading_ui_tests.py --preflight --self-check` 通过，新增取证自检结果单列为 `SYNTHETIC_LAUNCH_DIAGNOSTICS_NOT_NATIVE`，原生执行数仍为 0。
- 三份 Python 源码 AST 解析通过；runner 去除限定的可选观察钩子与自检接入后，与修改前全文一致，证明原命令、限时器、参数、断言路径及接受条件没有夹入其他更改。
- 精确白名单检查：一份既有 runner 修改、三份新增文件；214 个范围外文件哈希保持，包括项目 Skills/lock、用户文件、旧 IPA、历史报告和分析记录。
- 两轮累计 2248 份历史原生证据的尺寸/哈希不变；没有覆盖原失败记录。HEAD 和暂存区未变。
- `git diff --check` 通过。临时校验脚本、基线与结果仅位于会话 scratch 的 `launch-diagnostics-local/`。
- 一次有界模型静态只读复核未提出确定的源码缺陷；复核文字不是原生执行证据，数量以实际离线脚本输出为准，不采纳未经执行的通过/完整性断言。

## 仍需真实环境验证

macOS 上 sample/log/launchctl 的实际输出格式、权限、PID 对应、取消行为和信号清理，以及观察开销尚未验证。系统工具失败会成为未知数据，不允许因此放宽原超时或测试门。

本批不是 App-host 超时修复，也不证明两项 UI 修正已通过。后续需要另行批准白名单发布及一次真实 Task3，读取新增记录后再决定根因和必要修复；原生验证到失败或成功终态后停止，不自动重跑。
