# 阅读面板局部轻动效与目录载入展示稳定性打磨（仅本地）

## 状态、用户授权与证据边界

- **仓库根与基线**：`D:\ai项目\YueJing`，HEAD `d084dfec49b0c033e4eebf84535959c513676a9a`（`project.yml` `0.2.0` / build `2`，iOS `16.6` / Swift `6.0` / GRDB `7.0.0`）。
- **工作树前提**：完整保留上一轮已获批的本地成果（8 个已修改 tracked 文件 + 3 个新增文件：书架规划页单目的地门控、排版三等宽居中列与对勾角标、目录四位总数徽章与真实 `Text` 隐藏等宽测量章序列、文字按钮非内缩完整包边），不恢复 HEAD 覆盖工作树。
- **本轮用户本地授权**：在现有第三版“开卷成境”界面基础上直接改进局部轻动效一致性与目录翻组载入展示稳定性，减少生硬突切与重复列表行插删；**仅授权本地源码实现与离线检查**，禁止 `git commit`、`git push`、Actions 触发/重跑、打包、云端写入、外部会诊、安装或更改 Skills。
- **证据等级声明**：
  - 本批落地的是**局部装饰层轻动效设计参数与目录载入指示槽位稳定化**，**不是**经设备 trace 证实的卡顿根因修复，**不宣称**“60FPS 通过”或实测耗时下降。
  - Windows 环境无 `swiftc`、`xcodebuild`、Simulator 或 iOS 渲染运行时：**原生编译 = 0、原生测试 = 0、UI 触摸 = 0、像素渲染 = 0、FPS/帧时间测量 = 0**。

---

## 唯一写入白名单（4 生产文件 + 2 离线检查/说明文件）

### 1. `App/Reading/ReaderMotion.swift`（仅设计时间 token）
- `toolVisibilityDuration` 由 `0.12` 微调为 `0.16`（秒），保持 `.easeOut(duration: toolVisibilityDuration)` 与 `hiddenTravel = 6`、`pressFeedbackDuration = 0.10` 不变。
- 新增 `selectionFeedbackDuration: Double = 0.14` 与 `selectionFeedback: Animation { .easeOut(duration: selectionFeedbackDuration) }`。
- 以上均为渲染设计参数，非设备实测延迟；未引入 `spring`、`repeatForever`、延迟队列、计时器或 iOS 17+ `snappy/smooth/bouncy` API。

### 2. `App/Reading/ReaderSettingsView.swift`（仅装饰层选中过渡与稳定对勾）
- 新增 `@Environment(\.accessibilityReduceMotion) private var reduceMotion`。
- **快捷排版预设按钮（`presetButton`）**：
  - `.animation(selectionAnimation, value: selectionMotionKey)` 仅挂载在 `.background` 内的圆角填充与 `strokeBorder` 渲染子树，以及右上角装饰对勾 `Image` 上；不挂在 `Button`、文字 `VStack`、`threeOptionLayout` 或 `ScrollView` 上。
  - 右上角 `checkmark.circle.fill` 保持稳定节点存在，改为 `.opacity(selected ? 1 : 0)` 过渡，避免选中切换时装饰子节点反复插入/移除；保留 `.font(.caption)`、`.padding(6)` 与 `.accessibilityHidden(true)`。
- **阅读背景按钮（`themeButton`）**：
  - `.animation(selectionAnimation, value: selectionMotionKey)` 仅挂载在右上角装饰对勾 `Image`（稳定存在 + `.opacity(selected ? 1 : 0)`）及外框描边 `RoundedRectangle.stroke(...)` 上；不动画“阅”字样张、底部标题、示例预览或全局阅读画布。
- **Reduce Motion 与交互门控**：
  - 统一使用 `selectionMotionKey = reduceMotion ? 0 : (selected ? 1 : 2)`、`selectionAnimation = reduceMotion ? nil : ReaderMotion.selectionFeedback`，并在同层 `.transaction` 中于 `reduceMotion` 开启时清除 `transaction.animation`。
  - **零 `withAnimation` 包裹业务提交**：`apply`、`commitDraft`、`finish`、滑块松手提交、加减步进即时提交、字号 `14...36` / 行距 `0...20`、三档预设 `17/5 20/7 24/10`、恢复确认背景隔离、快速连续点击响应以及全部 AX trait / value / identifier 逐字保留。

### 3. `App/Reading/ReaderDirectorySheet.swift`（避免已有目录页翻组时重复插删列表尾行）
- `List` 内完整载入行收窄为 `if model.state.loading && (model.state.page?.chapters.isEmpty ?? true)`：
  - 首次打开尚无目录页（`page == nil`）或目录为空（`chapters.isEmpty`）时，继续在 `List` 内显示完整 `ProgressView + "正在读取目录…"`。
  - 当已有非空目录页（`!page.chapters.isEmpty`）正在翻组或定位时，不再向 `List` 末尾插入/删除额外载入行，保留已显示章节行稳定；同时将 `loading: model.state.loading` 传入列表外固定 `ReaderDirectoryFooter`。
- 未对 `List`、章节行、`reveal` / `proxy.scrollTo` 添加任何 `.animation` 或整页淡入淡出；分页步长（32）、`ownerRevision` 校验、失败保留旧页及重试逻辑原样保留。

### 4. `App/Reading/ReaderDirectoryFooter.swift`（恒定 16pt 忙碌指示槽位）
- 新增纯展示输入 `let loading: Bool`，不持有模型、异步任务、`@State` 或后台常驻旋转的 `ProgressView`。
- 共用 `rangeText(singleLine:)` 两侧对称保留固定 `16pt` 宽（`loadingSlotWidth = 16`）槽位：左侧为静态 `Image(systemName: "hourglass")`（`.opacity(loading ? 1 : 0)`，无自驱动画，Reduce Motion 下亦无新增运动），右侧为 `Color.clear.frame(width: 16, height: 1)` 平衡槽（不固定文本高度，保留单行测量与大字多行增高能力）。
- 翻组载入期间继续展示当前已加载页的真实 `rangeLabel`，不预测或伪造下一组范围；`loading` 切换不改变 `rangeText` 横向中轴线与 Footer 高度。
- 7 处 `rangeText` 调用点与 3 组 `ViewThatFits(in: .horizontal)` / 辅助大字号回退全部复用该槽位；辅助功能合并为单一元素，保留 `label = "目录范围，\(rangeLabel)"`，并在 `loading` 为真时提供 `value = "正在读取目录"`，装饰图标隐藏不单独朗读。

### 5. 新增离线检查与本文档
- `scripts/check_ui_motion_polish.py`：实际源码词法/局部结构合同检查、内存突变负对照（不写磁盘）及 214 路径基线 SHA256 保护核验。
- `docs/UI_MOTION_POLISH_LOCAL.md`：本说明文件。

`ReaderScreen.swift`（含已确认的标题栏 stroke background 在 fill background 之前的顺序与命中门控）、`ReaderToolVisibility.swift`、`ReaderFloatingToolsView.swift`、`ReaderCompactButtonStyle.swift`、`ReaderSettingAdjustment.swift`、`ReaderTypographyPreview.swift`、书架单目的地导航文件、`Sources/**`、`Tests/**`（139 声明 / 138 选定测试）、`project.yml`、工作流、用户本地三文件、Skills/lock 及指定 IPA 均零改动。

---

## 本地离线验证与尚待原生/真机验收项

### 已执行的本地离线检查（非 Swift 编译 / UI 运行 / FPS 实测）
1. `python -B scripts/check_ui_motion_polish.py`：核验 **136 项真实源码词法/结构合同**（4 个改动文件与受保护文件的括号平衡、iOS 16.6 API 边界、token 参数、4 处局部装饰 `.animation` + Reduce Motion 双重门控、无 `withAnimation` 包裹提交、目录载入行谓词与 Footer `16pt` 对称槽位）、**20 项内存突变负对照拒绝**，以及 214 项实际工作树基线中 **210/210 非白名单文件 SHA256 零漂移**。
2. 独立运行上一轮 `python -B scripts/check_navigation_panel_layout.py`（未修改该脚本）：确认 **107 项源码合同 + 35 项合成规格**与本轮改动完全兼容通过。
3. 运行既有离线门控回归：`check_task3_validation.py`、`check_reading_entry_diagnostics.py`、`check_reading_launch_diagnostics.py`、`check_device_build_validation_entry.py` 及 `git diff --check`。

### 尚待获批后执行的原生与真机验证（当前计数 = 0）
1. macOS / Xcode 16.4 / Swift 6.0 / iOS 16.6 真实编译及既有 138 项原生测试。
2. 阅读工具显隐与连续快速反转（含 `0.16s` 过渡中途反向点击、滚动开始自动隐藏、停稳唤出），确认退出/目录/排版按钮命中与隐藏后无 AX 残留。
3. 设置与目录面板反复开关、系统下拉交互取消、选章自动关闭；预设与背景快速连点（`0.14s` 装饰过渡不阻塞下一次点击、正文仅按既有提交语义更新、主题与字号行距隔离）。
4. 目录首屏空页载入行、已有非空页翻组时 Footer `16pt` 静态 `hourglass` 显示/隐藏（列表不增删尾行、范围文字不偏移、Footer 不跳高）、读取失败重试、四位章节（`999 -> 1000 / 9999`）与窄宽/横屏/大系统字号表现。
5. Reduce Motion 开/关切换、VoiceOver 焦点与“正在读取目录”范围值朗读、纸色/白色/深色主题对比度，以及 iPhone 13 / iOS 16.6.1 真机主观流畅度与（如需性能结论时）Instruments 帧时间观测。
