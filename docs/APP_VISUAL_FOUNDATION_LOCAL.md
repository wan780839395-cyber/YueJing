# App 外观基础 · 首批本地源码

## 授权与范围
- 用户已接受冻结设计后选择「批准首批本地落地」。本批由协调端限定转交；用户消息 ID 工具未暴露，记为 `unavailable`，不以任务 ID 冒充。
- 基于实际工作树续做，不重置到 HEAD `d084dfec49b0c033e4eebf84535959c513676a9a`。原有 9 个 tracked 修改、5 个本地新成果及 3 个用户私文件保留。
- 仅 6 个源码/说明路径：新增 `App/AppVisualStyle.swift`、`scripts/check_app_visual_foundation.py`、本说明；修改 `App/ContentView.swift`、`App/Library/LibraryAppearance.swift`、`App/Reading/ReaderVisualStyle.swift`。无提交、push、Actions、工程生成、构建或安装。

## 已接线的 UI
- `AppAppearance` 的稳定值为 `clear` / `mist` / `ink`，完整名称为清朗 / 柔雾 / 墨夜。`AppVisualStyle` 是局部不可变 UI token，包含语义字体、间距、表面、文字、强调色与描边；不新建 ViewModel、Task、actor、Timer 或全局状态中心。
- 默认柔雾。清朗、柔雾分别随当前系统 light/dark 取对应色板；墨夜在两种系统环境下均取显式深色管理页色板。基础三主题颜色来自冻结原型；清朗/柔雾的系统深色适配为本批原生候选，仍待视觉验收。未重做原型。
- 书架工具栏增加系统 Menu，三项均为真实 Button；当前项显示「名称 · 当前」和勾，另有 AX 名称/当前值。入口最小 44×44pt、语义字体，菜单项使用系统菜单布局与 Dynamic Type；实际触达、大字及 VoiceOver 尚未运行。
- 外观菜单沿用原 `canOpenPlannedFeatures` 的全部六门：service 就绪、允许书架反馈、未导入、无编码确认、无反馈消息、无 reader。入口禁用，按钮执行时再次 guard；不新增 sheet/alert，不修改原导入或阅读 action。
- `ContentView` 显式传入所选 `AppAppearance`，`LibraryAppearance` 转发共享色板。书架背景、标题/书目、占位封面、已有规划入口和提示表面已使用相同 appearance；导入说明/空书架次文也使用主题次文。只为书架 navigationBar 设局部 `toolbarColorScheme`，保证墨夜导航文字可读；不设根 `preferredColorScheme`，不向 reader 注入 colorScheme。

## 本地记忆与阅读隔离
- 独立键：`dev.yuejing.ui.appAppearance.v1`，仅由 `ContentView` 的 String `@AppStorage` 持有；不复用数据库、ReaderPreferences 或旧设置键。
- 有效值按 rawValue 恢复；未知字符串安全显示柔雾。恢复函数只读，不主动修复/覆盖未知存量值；源码唯一主动赋值点是用户外观按钮，不在 onAppear/onChange/start 写回或调用服务。真实 AppStorage 落盘、重启恢复和跨进程行为未验证。
- `ReaderDomain.ReaderTheme` 仍为 `.paper` / `.light` / `.dark`（现有界面名称纸色 / 白色 / 深色），与上述三种 App 外观无映射、无共享键。正文 UIColor、CoreText、字号、行距、阅读背景、排版/保存和会话代码均未改。
- `ReaderVisualStyle` 只复用原值相同的 44pt 控件、8pt 间距、0.5pt 分隔线及两个语义字体；四个 ReaderTheme 颜色函数和 RGB 实现原样。没有新增 init 参数，阅读调用方无需改变。
- 不添加 EnvironmentKey；纯 `AppAppearance: Sendable` 保持非 actor 隔离，UI 颜色/Font 的 `AppVisualStyle` 和现有外观类型明确 MainActor。未引入 Observation、SwiftData 或 iOS17+/Swift6.2 API；仍以 iOS16.6、Swift语言6.0/compiler6.1.2、Xcode16.4 为待编译目标。

## 实际可达范围与未落地
- 已审读全部 LibraryAppearance 消费者：ContentView、LibraryHeaderView、LibraryBookRow、LibraryCoverPlaceholder、LibraryPlannedEntriesView、LibraryPlannedFeatureView。前五者通过当前书架 appearance 链取所选外观。
- **规划详情 `LibraryPlannedFeatureView` 独立构造 `LibraryAppearance(colorScheme:)`，保留兼容 API 后取默认柔雾，不读取当前选择。** 本批不改此未授权消费者，不用全局单例/广播绕过。因此不是全 App 页面都已切色；诊断页、系统导入/编码弹层也未全面主题化。后续最小接线需另批授权修改该详情消费者，显式传值或消费受限环境值。
- A 阅读/dock 与 B/C 仍是批准设计方向，不是全部已 native 落地。未实现三导航/三 dock、未搬规划入口，原有单目的地导航、目录/排版布局、轻动效、任务附着、禁用/焦点/AX 合同保留。
- 当前真实业务仍为统一 TXT 导入；EPUB、封面提取、漫画、AI 只规划未接入。不安装字体/素材、不联网、不改图标、0.2.0 build 2、依赖或工作流。

## 已执行的离线检查（均非原生）
- 新 checker：34 项源码合同、8 个内存负对照全部通过；覆盖错键、ReaderTheme 映射、preferredColorScheme 污染、丢六门、丢选中值传递、额外写回、服务副作用和阅读颜色漂移。
- `--snapshot-root` 与本批真实 pre-edit 副本反向归一化：ContentView 完整文本、ReaderVisualStyle 完整文本相等；并非拿 HEAD 代替已有未提交结果。
- 导航/布局：107 项源码 + 35 项合成规格通过。
- motion：原 checker 的源码合同 136 项、无历史 hash 输入的负对照 16 项通过。其 CLI 固定前批 214-path/四文件白名单，不冒充适用于本批；未更改旧 checker/baseline。本批用新冻结清单单独做保护比较。
- Task3 离线门控：13 项顶层、40 项日志解析、12 项 App parser 通过；工作流 Bash 仅解析 15 个 run blocks。其嵌入的 launch 120 项与单独 launch 运行的 120 项是同一组，不重复计为独特 case。
- 单独 entry：57 源码 + 64 合成回归；launch：120 合成项；device-build-validation-entry：31 离线项均通过。`git diff --check` 通过。所有 stdout/stderr/exit 原样留在批次 scratch，并复制到 ignored 结果目录。
- 冻结分母：156 tracked、8 原有 untracked（5 成果 + 3 用户私文件只 hash）、48 Skills + lock、13 原型文件、3 个指定 IPA，共 229 个唯一路径。除本批 3 个既有生产文件，其他 226 个路径须 hash 完全一致；HEAD/index 另核对。完整清单及结论见本批 ignored `baseline.json` / `verification.json`，不发布私文件正文。

## 验证界限与后续
- Windows 无 Swift/Xcode/iOS runtime；本批原生编译 0、原生测试 0、AppStorage 运行测试 0、真机验收 0。源码读取、合成门控和 hash 不能证明 Swift6 编译、进程内存隔离、重启恢复、UI 命中或阅读性能通过。
- 后续获单独授权后，需原生编译与真实 App 验证：三外观 × 系统 light/dark、无值/合法值/未知值恢复、切换后进出阅读与重启、导入/编码/反馈忙态、44pt/大字/AX、三种阅读背景不被外观覆盖且不触发保存/重排。三导航/dock 与其余页面接线另批，不在本批续做。
