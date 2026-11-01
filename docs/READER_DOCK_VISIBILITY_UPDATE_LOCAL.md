# 阅读显隐更新的同 theme 容器配色去重（仅本地）

授权问题：“是否先做这7文件的本地显隐更新去重，追加2个Host回归（145声明/144选择）？这只是局部优化，不代表卡顿已解决；保留切App修复，不提交、不构建。”用户回答：“批准，先做局部去重”。messageID unavailable。公开/云写、网络、安装、原生编译与执行均为0。

## 范围与边界

在 `fd4b925192cf97f9afca459be703b1ac5510a10f` 上保留未提交的九路径切 App 恢复候选，增加恰七路径增量（五重叠、两新建；合并十一候选），不以 HEAD 重置前批。

- `ReaderViewController.swift`：仅增加初始 nil 的 `appliedTheme` 与精确 `setTheme` 替换。同 theme 在加载/颜色计算前返回 false；首次包括 paper 和真实变化计算一次背景、赋给 view/table 两容器、记录 theme、返回 true。Bool 是 internal 回归接缝，无计数、计时或遥测。
- 新 `ReaderThemeUpdateTests.swift`：两个普通串行 MainActor Host 测试源码。首次 paper/重复/暗亮切换检查 Bool 和真实两容器颜色；真实引擎产生不同目标的两个 paper window，再生成匹配 dark window，验证同 theme false 不阻止独立 apply、新 id/正文/后续 cell 颜色。直接调用 VC，不冒充 SwiftUI 回调测试。
- `task3_test_inventory.py`：仅新增两个固定 Host 身份、Host6→8、selected142→144；总声明143→145、excluded performance1、原143身份及 SWIFT_GROUPS 不变。
- `check_reading_entry_diagnostics.py`、`check_device_build_validation_entry.py`：仅相应计数/标签增量，原 loader/路径/命令阻断和20s/10s预算保留。
- `check_reading_interruption_recovery.py`：只追加显式后继 phase 与增量保护；旧 source/18负控、LEDGER、baseline、143/142旧入口原语义不变。
- 本说明是第七路径。

`setTheme` 原本只设置两容器背景，没有 visibleCells/render/setNeedsDisplay；不能称其为 CoreText 重绘或已知卡顿根因。正文 render/AX 拼接仍由 cellForRow/window apply 路径负责；测试不要求容器 setter 遍历旧窗口 cell。未增加 ReadingCell 计数框架，也未声称减少正文失效/绘制次数；AX 文本不变只能保护内容，不能证明 guard 的性能收益。

Viewport 原 update 顺序保留：owner → phase → callbacks → setTheme → window.id 门 → apply → applied/onApplied；不以 Bool gate callbacks/apply，不缓存整个 Representable、不 Equatable 跳 update。前批 Scene/Viewport/四 Host/说明逐字节保护；重叠 VC 在反向移除唯一缓存字段、精确还原 setTheme 后须与前批 dirty 全字节相等。库存/两适配器按唯一精确逆替换全字节比较；旧 checker prefix 和原入口也逐字保护。范围外 tracked/显式 Skills、三私文件仅 hash、前批报告和既有指定 IPA/六 pyc 受冻结保护，不遍历全 artifacts。

不改主显隐160ms/6pt、C局部100ms、dock外观/布局/gesture/焦点、读写/anchor/save/恢复/session/退出。iOS16.6、Swift语言6、Xcode16.4保持。

## 离线入口与证据

原九路径干净阶段先运行旧入口，记录30 source /18 negatives。修改后旧入口可能因合法新增行 ledger/库存不适用而失败，原始失败必须保留，不能把145伪装143传进去换绿。

```powershell
python -B scripts/check_reading_interruption_recovery.py --baseline artifacts/reading-interruption-recovery-local-20261031T131526220169Z/baseline.json --theme-update --previous-stage artifacts/reader-dock-visibility-update-local-20261031T151222008580Z/baseline.json
```

后继输出分列原恢复语义/18负控、theme source/负控和145/144/Host8保护。反例包括真实前 theme VC 缺幂等门的语义拒绝、首次 paper 错跳、变化不应用、callbacks/new window 被 gate、回滚旧 scene/context、前四 Host/正文/库存/loader 漂移。Python 仅改源字符串验证 guards，不模拟 Swift/UIKit 行为。

权威本批结果、所有真实命令/exit/stdout/stderr、完整七路径增量与十一候选 diff、保护分母、最终 hash 位于：
`artifacts/reader-dock-visibility-update-local-20261031T151222008580Z/IMPLEMENTATION_REPORT.md` 与 `machine.json`。

旧 navigation-panel138/139锁及 dock/motion/cohesion 历史全文件账本冲突不修改；必要当前 source/CI 入口另列，重叠断言不相加。

Windows 无 Swift/Xcode/iOS，两个新 Host、前四 Host 均未编译执行，native0；无真实 SwiftUI/触摸/切 App/视觉/VoiceOver/绘制/FPS/walltime 验证。卡顿仍无根因或改善证据，不宣称主 dock 动画或用户卡顿已解决。不提交、不构建、不出 IPA；停本地等待唯一一次独立复核。
