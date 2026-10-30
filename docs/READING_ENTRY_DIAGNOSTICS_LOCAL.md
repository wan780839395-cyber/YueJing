# 阅读共同入口有界取证（仅本地，2026-10-30）

## 授权、基线和状态

用户在只读共同入口诊断后同意继续此前方案。本批只补合成 UI fixture 的入口期命中／状态证据和必要离线检查，不修复装饰层、不改阅读业务；不含提交、push、Actions dispatch/rerun、模拟器操作或打包。

基线为 `2876d070318ad13a0e7a6262442e6296f1ee7909`。历史 run `40989010917 / attempt 1` 为 127 passed / 8 failed / 0 skipped / 3 unexecuted；八项 UI 均在首次打开后的设置按钮 exists+hittable 等待失败。已解析的 141 份自动快照均记录 enabled=true、唯一查询和稳定 frame，但没有可证明实际拦截层的失败期 hit-chain。标题栏／Dock 装饰组合仍只是优先候选，不是已确定根因。

本批 **原生执行 0**。Windows 离线源码检查、合成附件解析和只读代码审查不能证明 Swift 编译、Darwin 通知送达、UIKit/AX 行为、采样开销或真机修复。没有新的 0.2.0 IPA。

## 七文件白名单

1. `App/Reading/ReaderEntryProbe.swift`：新增 DEBUG fixture 专用显式采样请求／缓存 endpoint。
2. `App/Reading/ReaderScreen.swift`：仅 DEBUG 区挂载新 endpoint，旧 endpoint 仍仅原 legacy 开关启用。
3. `App/Reading/ReaderViewController.swift`：仅 DEBUG 取证区复用状态／几何／hit-test 读取，入口独立采样额度和协作截止。
4. `Tests/YueJingUITests/ReadingEntryEvidence.swift`：新增非门禁请求、证据保存及身份／时间／几何校验。
5. `Tests/YueJingUITests/ReadingFlowUITests.swift`：准备开关、首次入口采样、失败补充；保留原谓词和原等待结果断言。
6. `scripts/check_reading_entry_diagnostics.py`：离线源码合同及合成证据解析回归；可只读检查单份导出附件。
7. 本说明。

`ReaderFloatingToolsView`、标题栏／Dock 装饰内容、按钮尺寸与动作、状态转换、视口、正文、导入、原书、数据库、保存位置、工具链、版本／图标／包名、所有工作流及测试清单不变。现有三份用户文件、本地 Skills／lock、历史报告／证据及两份旧 IPA 不修改。

## 请求与缓存协议

- App 新路径同时要求 `#if DEBUG`、`ReadingUITestFixture.isRequested`、`YUEJING_READER_ENTRY_PROBE=1` 和有效 `YUEJING_UI_TEST_SESSION` UUID。常规 Debug 会话及 Release 均不会启用此通道。
- 利用已有系统 CoreFoundation Darwin notification center；不安装、不扩权、不启动服务、不发送网络请求。通知名只含固定前缀、随机合成测试 nonce 及 `initial`／`failure`，无书名／路径／正文；无通知 payload。
- App 进程内单例只注册这两个具体通知名；首次挂载时弱绑定 store 和 endpoint，后续阅读 route 不得替换。observer 存活到合成测试 App 进程退出，无跨线程 unmanaged 对象指针；回调将已复制的名字交主 actor。
- 每阶段最多消费一次，合计最多两次请求；重复通知不重新采样，failure 先于 initial 时记录 unknown 且不补采。缺失 endpoint、旧 route 释放、编码／大小异常均保留 unknown。
- 新 AX endpoint 的 `accessibilityValue` **只返回缓存字符串**，自动 AX 查询不做原生采样、不递增采样额度。旧退出 probe 的 32 次 getter 额度保持独立，不会阻止入口显式采样。
- 每个原生 sample 最多接受 24KiB JSON，最多两条；AX envelope 上限 64KiB。不能因输出文件存在而宣称观察成功。
- 新增 1×1 只读节点和原 marker 可扰动 SwiftUI／AX 组合；报告明确 `observationMayPerturbComposition=true`，不能称为无扰动实验或生产行为复现。

## 测试时序、预算与保存

1. `withFixture` 保留原随机 session，并启用入口开关。测试侧只允许本用例第一次 `open` 进入新取证；后续重开／跨书／同用例进程重启不追加请求。
2. 原书架行点击后仍只创建一个 **20 秒**共享截止。原预期正文几何可见断言完成后、设置按钮等待前发 initial 请求；诊断消耗该截止剩余时间，不延长或重置它。
3. 每阶段 runner 协作式额度最多 **2 秒**，initial 还受原共享截止约束。发出一次通知后，最多两次缓存查询尝试，不重发通知；分别检查请求名、session nonce、App/runner PID、route/window、原生 sample 时间顺序和版本窗口。
4. 设置按钮仍使用原 `exists == true AND hittable == true` 谓词和原等待返回值断言。只有已经返回非 completed 且属于首次入口时，才尝试 failure 请求；不重新功能等待、不点击、不启动或关闭 App。failure 的补充最多 2 秒协作式额度，不改变原失败结果；全程仍受原 UI／单例执行上限约束。
5. 每阶段最多三条 keepAlways 附件：`started`、`app-cache`、`finished`。先保存开始标记；再保存原生缓存（包括 unknown／部分结果）；最后读取设置按钮 exists／enabled／hittable／frame、退出 frame，并保存逐项起止时间。
6. 名称为 `YueJingUI--<case>--entry-<initial|failure>-<checkpoint>.entryprobe.json`。复用现有全量 xcresult 附件导出／哈希和 artifact 上传；不修改工作流或旧成功用例 PNG/open-AX 门。

原生读取的协作额度为 **0.25 秒**；复用最多 128 个 AX 对象、深度 8、每容器／子视图最多 32、命中父链最多 6 的边界。到截止后不再启动下一次受控查询，返回 unknown／truncated。单次 UIKit／XCTest 调用本身无法在这里强制抢占，跨进程通知调度也不是实时保证；已发送的通知不保证能取消。记录实际时间、预算剩余和超时量，**不承诺严格 0.25 秒或 2 秒墙钟上界**。

缺失、过期、错身份、非 key window、原生／测试 frame 对不上、AX 遍历截断或没有 settings hit-chain，一律不能升级为完整 observed。`stateValidation` 和 `settingsGeometryValidation` 分开报告：状态观察有效不代表设置命中链有效。settings.hittable=false 是可以记录的事实，不会因此把测试判为通过。所有数据是顺序观测，非原子触摸时状态；hitTest 只做预测，没有发送触摸。

## 保持的验收门与后续边界

- 不新增／删减原生 case，固定 **138** 个唯一用例：25 Core Debug + 93 Domain Debug + 6 Block Release + 1 串行测量 Release + 2 Host + 8 UI + 3 Canvas。
- Host **480 秒**、UI **900 秒**、单例 **180 秒**、退出 readiness/回书架共享 **10 秒**不变。不以新增诊断附件、Python 回归或模型审查替代原断言或真实计数。
- 原 `.completed` 断言保留同一 waiter 返回值。辅助诊断若发生 XCTest／进程异常，仍不能解释为功能通过；需结合先保存的附件和原始日志报告真实失败，禁止自动重试。
- 本批不执行原生验证。后续公开七文件发布和一次 Task3 attempt1 须另行明确批准；只有完整 138 项逐项真实通过、无缺失／重复／跳过后，才允许同 SHA 设备 Release 和 IPA 校验。失败即停，不自动修补重推／rerun。

## 已执行的离线检查与使用方式

从仓库根使用现有 Python（不安装工具）：

```powershell
python -B .\scripts\check_reading_entry_diagnostics.py
python -B .\scripts\check_task3_validation.py
python -B .\scripts\check_reading_launch_diagnostics.py
python -B .\scripts\run_reading_ui_tests.py --preflight
```

本轮首次本地执行：57 项源码合同、64 项合成附件解析回归通过；既有 13 项门禁回归、40 项 Swift 日志解析、12 项 Host/UI 日志解析和 61 项启动诊断合成回归通过，138 项源码清单一致。重复调用的旧回归不重复计作新增测试。这些数值均不是原生通过数。

检查真实导出附件时，仅使用 manifest 指定的现有文件：

```powershell
python -B .\scripts\check_reading_entry_diagnostics.py --attachment <已有导出附件路径>
```

该离线分类器不运行测试、不改写附件、不修改原生计数；输出始终包含 `NON_GATE` 和 `native_test_result: not evaluated`。缺失或 malformed 的 JSON 返回 unknown。合成正／反例只验证 Python 解析器，不等于 Swift 生产端／UIKit 协议已验证。

已进行一次有界只读 Swift 代码复核，未发现可确认的具体缺陷；仍须真实 Xcode 编译验证 Swift 6 并发／API 可用性，以及实际 Darwin 回调、AX endpoint、采样耗时和证据完整性。本批停在本地未提交状态。
