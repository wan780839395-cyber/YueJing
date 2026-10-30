# Host 采样收窄与外层退出时序（仅本地）

## 本批边界

基线 `788cef89959ecc6e63ca6d6c387ce304cf4c9277`。用户批准仅本地收窄 Host 采样、补充外层退出时序；**不改业务／Swift 测试／断言／功能预算／138 项门，不提交、push、dispatch、rerun 或打包**。本批原生执行 0；现有成功／失败记录不变。

背景：run 40999373385 记录了 127 项通过、11 项未执行；Host 两例通过、App exit 0，但外层 xcodebuild 到 480 秒被终止，原始 exit -9、timed_out=true。只读解码定位启动请求到 PID 返回约 293.827 秒，外层最后退出调用仍未知。本批增强证据，不宣称已修复启动或退出。

白名单仅四文件：

- `scripts/reading_launch_diagnostics.py`
- `scripts/run_reading_ui_tests.py`
- `scripts/check_reading_launch_diagnostics.py`
- 本说明

原 `READING_LAUNCH_DIAGNOSTICS_LOCAL.md` 保留为当时记录，本说明描述新候选行为。App／Sources／全部 Swift 测试、入口取证通道、版本／图标、project.yml、工作流、测试身份清单、打包脚本、用户文件、Skills／lock、旧 IPA 及原始证据均保持。

## 1. 收窄 Host 采样

仅既有 Host observer 启用。两轮时机仍是启动后约 90 秒和功能截止前约 40 秒；每轮总预算 15 秒、单命令 3 秒、截止前 5 秒安全边界、每命令输出 256KiB 全部保持，不追加快照、重试或备用命令。

新 profile `priority-process-stacks-v2` 的顺序为：

1. `/bin/ps -axo pid=,ppid=,stat=,etime=,comm=`，只保留既有固定进程名及监督的 native PID，不保留参数／环境。
2. 同一进程列表唯一确认的当前 native **xcodebuild PID**，一次 `/usr/bin/sample <pid> 1 10 -file /dev/stdout`。
3. 未截断列表中唯一的 **CoreSimulatorService**（接受固定全名／短名），同样一次 sample。

每轮最多三条实际命令。移除本轮 live profile 中的 device、launchctl、testmanager socket、App host 栈、宿主／模拟器系统日志查询，避免它们在优先栈采样之前消耗窗口。context 的 `not_requested` 明示这些项未请求，不把省略伪装为成功观察。旧解析 helper 及其离线回归保留，但不在新 live profile 调用。

CoreSimulatorService 是**宿主机级服务**，不是“已确认属于某一个 UDID 的 App 进程”。无 PID、多个服务候选、进程列表截断或 native PID 名称不匹配，一律 unknown，不选第一个凑数。ps 与 sample 是顺序读取，不能完全排除 PID 重用。

新增 sample 内容校验：必须有唯一匹配 PID／进程名的 `Process:` header，以及 Call graph 段内的线程头和后续栈帧；解析到下一个顶层段落即停止。仅有 sample 提示、错误文字、错误 PID、空栈或后续汇总段数字不能算有效堆栈。仍执行原有敏感内容过滤、文本上限和显式截断标记。

单命令 3 秒／每轮 15 秒是源码截止，不保证系统工具严格在墙钟上限内返回；预算内也可能得不到有效栈。不会因为结果 unknown 自动放宽预算、重新采样、启动／安装／重置模拟器、debugger attach 或改变原生命令。

## 2. 固定槽位的进程时序

仅 `YueJingHostTests` 创建 `ProcessLifecycleDiagnostics`；UI／Canvas／附件导出不创建它。

最多 22 个固定一次性槽位：Popen 请求／返回／失败、timer.start 返回、首次 stdout／测试输出／成功文字、stdout EOF、wait 调用／返回、stream 错误、timer callback／poll结果或错误、kill 请求／返回或错误、timer cancel、stdout close、异常展开、stream 返回及其 timed_out。

- 原生执行线程与计时器线程只写固定内存槽位并通知后台 writer；没有文件 IO、额外 poll、重试或等待 writer。
- `timer_poll.value=null` 表示那一次原 poll 返回 None；事件缺失则在 `unknown_events` 列出，不能当作已退出或未超时。
- 时间记录包含 monotonic 和 Unix clock。`timer_started` 是原 timer.start 返回后的观察时刻，不是精确调度起点；API 事件时间及两时钟值是顺序读取，非原子采样。
- 计时器仍是一次 `Timer(timeout_seconds, expire)`，回调仍是一次 `process.poll()`，只有原 poll 返回 None 才设置原 timed_out 并 kill 同一子进程。不得根据成功文字取消原计时器或把 -9 变为 0。
- 记录 `success_marker` 只说明读到了文字，与 `stdout_eof`、`wait_returned` 是不同事实。进程已退出而 EOF 较晚、EOF 已到而进程尚未退出、poll/kill 之间退出的竞争均保留原行为。
- 原生 Popen／读取／wait 等异常继续传播；诊断钩子异常只影响诊断。只记录异常类型标识，不保存错误消息、路径、命令参数、环境或输出正文。
- `timer.cancel()` 不等于正在运行的回调已结束。保持原有不 join 计时器的行为，快照可能先于某些 timer 事件；`timer_thread_not_joined` 和 `sequential_not_atomic` 明示此限制。

## 3. 保存与边界

计时器启动后才启动独立 daemon writer，写新文件：

```text
artifacts/reading-ui-native/YueJingHostTests-process-lifecycle.jsonl
```

第一行非门禁元数据，之后每个事件最多一行；使用 exclusive create，不覆盖已有文件。writer 只读内存槽，不调用或控制进程；主执行路径不 join。writer 不持有原生记录端需要跨 IO 等待的锁。文件／线程不可用、runner 被终止或较晚 timer 事件可造成缺失／部分记录，不能假称完整。

正常返回 `stream_native` 后，既有 `YueJingHostTests-execution.json` 保留原 `native_exit`／`timed_out`，只追加 `process_lifecycle_observation` 内存快照，最大 16KiB。快照失败、非 JSON、非有限数或超限时写 non-gate unknown。这样即使后台 writer 慢，原结果记录仍能携带已捕获事件；不新增主线程诊断文件写入步骤。

该内存快照在已有 execution 文件落盘时一并保存；原生命令若永不返回，只有后台 JSONL 的已落盘部分可用。Popen 尚未返回时 writer 还未启动；不承诺捕获所有进程创建阻塞。文件落盘、线程调度和额外时钟读取都可能影响耗时，不宣称零开销或绝对不扰动。

复用原 workflow 的递归 artifact 上传，不改上传／权限／任务。新增字段和 sidecar 均带 `acceptance_role: none`，不生成任何 tests-passed 或 gate 证据。

## 4. 保持不变的验证合同

- Host 480 秒、UI 900 秒、单例 180 秒；打开共享 20 秒、退出共享 10 秒不变。
- 138 项唯一原生用例及顺序、禁止缺失／重复／跳过、原始退出码／超时门、设备 Release 与 IPA 条件门不变。
- 不改原生 Popen 参数、串行设置、依赖／工具链或实际测试选择；不安装新工具。
- 原 `_capture` 的独立 session、诊断进程组清理、输出 cap 和取消机制保持；不会向被采样的 xcodebuild／CoreSimulator 服务发诊断终止信号。
- 不根据 unknown 记录自动放宽时限或启动额外验证。

## 5. 离线检查口径

```powershell
python -B .\scripts\check_reading_launch_diagnostics.py
python -B .\scripts\check_task3_validation.py
python -B .\scripts\check_reading_entry_diagnostics.py
python -B .\scripts\run_reading_ui_tests.py --preflight --self-check
```

首次 115 项诊断回归通过后，一次有界只读复核指出“空 Call graph 后的汇总数字可能被误认作栈帧”。已限定段落并要求线程／后续帧，增加四项拒绝反例及一项实际 observed 正例检查，最终 **120 项诊断合成回归**和三份 Python AST 检查通过。采样回归只使用 fake subprocess；时序回归只用 fake Popen／Timer 和本地临时文件／线程，不调用 Xcode、simctl、sample 或系统日志。覆盖错误 PID／空栈、顺序和预算、成功文字后超时、EOF 与退出不同步、poll/kill 竞争、钩子／writer／快照失败、阻塞 writer 不延迟主执行返回。

既有 13 项门禁、40 项 Swift 日志解析、12 项 Host/UI 日志解析，以及入口取证的 57 项源码合同和 64 项合成解析检查均通过；preflight 保持 138 项唯一清单。重复执行的检查不重复计作新增测试，更不代表原生通过。

原 61 项诊断回归中的三项 profile 相关断言随八命令改为三命令更新（数量与单命令 cap、采样 PID 集合、工具顺序）；其余旧合同继续验证。所有 Swift 断言及 138 项清单不改。

本批仍为 **原生执行 0**。实际 macOS sample 格式／可用性、时序记录完整性、权限和开销仍需另行批准后的单次原生验证。后续公开四文件及 Task3 attempt1 须单独批准；任何原生编译／执行／计数／打包失败即停，不自动修补重推或 rerun。
