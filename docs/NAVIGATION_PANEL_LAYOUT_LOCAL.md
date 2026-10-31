# 书架规划入口单目的地导航与排版/目录面板布局打磨（仅本地）

## 状态、用户反馈与授权边界

- 源码根：`D:\ai项目\YueJing`；基线 HEAD：`d084dfec49b0c033e4eebf84535959c513676a9a`（`project.yml` 版本 `0.2.0` / build `2`，iOS `16.6` / Swift `6.0` / GRDB `7.0.0`）。
- 用户直接确认：**上一批要求的功能已真机通过，保留正常功能**；当前直接要求修复“漫画聚合 / AI 故事”一次点击进入多层重复页与重复操作叠加、打磨排版设置按钮居中/对齐/间距、重构目录总章节数（四位）与按钮外框包边布局，并将相关 UI 一并优化。
- 用户消息 ID 当前不可得，不编造。**用户功能反馈不等于 CI 全量原生测试通过**；历史 Task3 记录仍按既有事实保留。
- 本批授权范围：**仅本地源码实现与离线检查**。禁止 `git commit`、`git push`、Actions `workflow_dispatch` / `rerun`、任何云端写入、外部会诊或工具安装。
- Windows 环境无 `swiftc`、`xcodebuild`、模拟器或 iOS 渲染运行时：**本批原生编译/测试执行 = 0，UI 触摸执行 = 0，像素渲染执行 = 0**。

## 文件修改与新增白名单

### 修改的已有 Swift 源码（8 个）

1. `App/ContentView.swift`
   - 新增 `@State private var plannedNavigation = LibraryPlannedNavigation()`。
   - 保持原 `canOpenPlannedFeatures` 六项门控表达式逐字不变。
   - 向 `LibraryPlannedEntriesView` 传入显式 `onOpenFeature: openPlannedFeature` 回调。
   - 在已有 `NavigationStack` 内、根 `List` 上（惰性行外）仅挂载一处 iOS 16.6 兼容的 `.navigationDestination(isPresented: plannedFeaturePresentation)`，呈现 `LibraryPlannedFeatureView(feature: plannedNavigation.displayedFeature)`。
   - `plannedFeaturePresentation` 捕获当前 `expectedID = plannedNavigation.activeRoute?.id`，仅当 `isPresented == false` 时按 `expectedID` 调用 `plannedNavigation.end(id:)`；不使用 `onDisappear` 清理路由，避免交互式侧滑返回中途取消被误判为完成返回。
   - 原书架列表、顶部诊断 `NavigationLink`、导入 TXT 按钮、阅读 `fullScreenCover`、文件选择桥接、编码确认 sheet 与提示弹窗保持不变。

2. `App/Library/LibraryPlannedEntriesView.swift`
   - 移除同一 `List` 行内的四个隐式 destination `NavigationLink`（2 个模块入口 + 2 个预留说明入口），全部改为显式 `Button` + `.buttonStyle(.plain)` 转发 `onOpenFeature(feature)`，消除单 `List` 行多 `NavigationLink` 共同激活风险。
   - 保留原有视觉卡片/行样式、最小触达高度（`60pt` / `44pt`）、独立 `contentShape`、辅助字号纵向排列、`.disabled(!canOpenFeatures)` 及全部 `accessibilityLabel` / `accessibilityHint` / `accessibilityIdentifier`（`library.planned.entry.<feature>`）。

3. `App/Reading/ReaderCompactButtonStyle.swift`
   - 保留默认参数 `surfaceInset: CGFloat = 6`、`outlined: Bool = false`，完全保护既有纯图标加减按钮（`44×44` 触达、`32×32` 可见底面）的视觉与命中合同。
   - 新增文字按钮显式 opt-in 能力（`surfaceInset: 0, outlined: true`）：在 `.background` 内同时绘制底色填充与 `0.8pt` `strokeBorder` 描边，包裹调用方 `padding` 后的完整标签尺寸；保持 `pressed`、`isEnabled`（禁用透明度 `0.4`）与 `accessibilityReduceMotion` 合同，不引入全局 `allowsHitTesting` 或 `accessibilityHidden` 修饰。

4. `App/Reading/ReaderSettingsView.swift`
   - 修正实际源码中两处三项网格（`ReaderTypographyPreset.allCases` 共 3 项，且核对 `ReaderPreferences.swift` 确认 `ReaderTheme.allCases` 实际同样为 3 项 `paper/light/dark`，而非旧估算中的 4 项）因 `GridItem(.adaptive(minimum: 76))` 在常规宽度生成 4 列导致右侧留空偏左的问题。
   - 以 `threeOptionLayout` 提供常规宽度下的**三等宽居中列**（`HStack(alignment: .top, spacing: 8)` + 每项 `maxWidth: .infinity`），并在窄容器宽度（`ViewThatFits(in: .horizontal)`）或辅助大字号（`dynamicType.isAccessibilitySize`）下自动切换为全宽纵向 `VStack(spacing: 8)`，完整换行不截字、不缩小字号掩盖。
   - 预设按钮移除标题 `HStack` 内的尾部对勾，改为 `.overlay(alignment: .topTrailing)` 角标（`checkmark.circle.fill`），使标题与数值无论选中与否均严格处于按钮几何中轴线；水平 `14pt`、纵向 `10pt` 内边距置于描边层内部。
   - “恢复默认字号与行距”按钮与面板顶栏“完成”按钮统一 opt-in `ReaderCompactButtonStyle(..., surfaceInset: 0, outlined: true)` 并补齐内边距，居中对齐且外框完整包住文字。
   - 保留字号 `14...36`、行距 `0...20`、三档预设 `17/5`、`20/7`、`24/10`、滑动松手提交、步进即时提交、恢复确认弹窗与背景隔离、全部辅助功能标识与动作。

5. `App/Reading/ReaderSettingAdjustment.swift`
   - 纵向与横向控件间距统一规范为 `8pt`；当前数值槽位采用 `.monospacedDigit()` + 居中 `minWidth: 34` + `fixedSize(horizontal: true, vertical: false)`；纯图标加减按钮继续使用默认 `ReaderCompactButtonStyle(tint: accent)`（`surfaceInset = 6`）。

6. `App/Reading/ReaderDirectorySheet.swift`
   - 顶栏 `ReaderPanelHeader` 保持“目录”标题与带完整包边的“完成”关闭按钮（`reader.panel.close`），不将四位章节数挤入主标题行。
   - 新增独立目录汇总副标题区 `directorySummaryHeader(page:)`（`page.total > 0` 时显示）：左侧为带 `Capsule` 填充与描边包边的等宽数字计数徽章 `共 \(total) 章`（`reader.directory.total`），与右侧当前章/本组范围信息保持 `>= 12pt` 明确间距；窄宽或大系统字号下通过 `ViewThatFits(in: .horizontal)` / `dynamicType.isAccessibilitySize` 自动分行，不挤压标题。
   - 向 `ReaderDirectoryChapterRow` 传入 `totalCount: page.total`；目录状态机、`ownerRevision`、焦点与分页逻辑完全不变。

7. `App/Reading/ReaderDirectoryChapterRow.swift`
   - 移除硬编码 `minWidth: 32` 像素猜测；新增 `ordinalColumnDigits(ordinal:totalCount:)` 按整本书最大章序位数（最少 2 位）统一计算数字列宽度，并以真实 `Text(String(repeating: "8", count: columnDigits)).font(ordinalFont).monospacedDigit().hidden()` 测量占位叠加左对齐真实章序，使 `999`、`1000`、`9999` 等四位章节在同一本书所有行和不同系统字号下保持严格一致的标题起始基准线。
   - 章序与章节标题间距提升至 `16pt`（`columnSpacing = 16`），杜绝四位章序与标题粘连。
   - 5–6 位章序自动采用紧凑 serif 字阶；超过 6 位或处于辅助大字号（`dynamicType.isAccessibilitySize`）时切换为纵向双行堆叠布局，同时保留可见章序与完整全宽章节标题，避免章节标题被压缩至零宽。

8. `App/Reading/ReaderDirectoryFooter.swift`
   - “回到当前章节”“上一组”“下一组”全部先施加充足内边距（水平 `10–14pt`、纵向 `8pt`）与至少 `44pt` 触达高度，再应用 `ReaderCompactButtonStyle(tint: appearance.accent, surfaceInset: 0, outlined: true)` 绘制完整底色和描边，彻底消除原先 `padding(4) - inset(6) = -2pt` 导致的文字骑框溢出。
   - 常规与紧凑纵向尺寸类均提供三级 `ViewThatFits(in: .horizontal)` / 辅助大字号渐进回退（单行 -> 双行 -> 全宽纵向堆叠），四位范围文本与大字号下均不溢出；分页步长、禁用条件与请求回调完全保留。

### 新增文件（3 个）

1. `App/Library/LibraryPlannedNavigation.swift`：纯 Foundation 值类型单目的地路由状态（`idle -> active` 一次门控、重复/竞争请求拒绝、按 `UUID` 精确匹配退出）。
2. `scripts/check_navigation_panel_layout.py`：离线源码合同与独立计数的合成规格边界检查脚本。
3. `docs/NAVIGATION_PANEL_LAYOUT_LOCAL.md`：本批本地实现与验证边界说明。

原 138 项测试文件/清单（`Tests/**`、`scripts/task3_test_inventory.py`）、`Sources/TXTCore`、`Sources/ReaderDomain`、`project.yml`、`.github/workflows/**`、`ReaderScreen.swift`、`ReaderFloatingToolsView.swift`、三个用户文件、Skills/lock 及全部历史 IPA/证据均保持零改动。

## 本地离线验证与原生待验项

### 已执行的本地离线检查（非原生编译/运行）

- `python -B scripts/check_navigation_panel_layout.py`：核对 9 个 Swift 文件括号/字面量平衡、iOS 16.6 API 边界、单目的地路由门控、三等宽居中布局与对勾角标、目录四位总数徽章与真实 `Text` 隐藏占位列宽、按钮包边顺序以及 138 项测试清单完整性；合成规格用例（`999 / 1000 / 9999 / 10000 / 1000000` 边界及单路由竞争点击/过期回调拒绝）单独计数。
- 既有离线脚本回归：`check_task3_validation.py`、`check_reading_entry_diagnostics.py`、`check_reading_launch_diagnostics.py`、`check_device_build_validation_entry.py`。
- `git diff --check`、变更范围白名单校验及 211 项保护基线（扣除 8 个获批修改已有文件后其余 203 项逐字节 SHA256 比对）。

### 尚待获批后执行的原生与真机验证（当前计数 = 0）

1. macOS / Xcode 16.4 / Swift 6.0 / iOS 16.6 目标实际编译与既有 138 项原生测试。
2. 书架“漫画聚合 / AI 故事 / EPUB 格式 / 封面展示”：单次点击仅推进一层对应规划页、一次系统返回直达书架；快速双击、跨入口连点、反复进退 20+ 轮不叠加页面；交互式侧滑返回中途取消后仍保持当前页面且后续进退正常。
3. 目录面板：四位总章节数（`999`、`1000`、`9999`）顶部计数徽章与标题间距、第 `999 -> 1000` 章跨组翻页时标题左边缘对齐与 `16pt` 间距、“回到当前章节 / 上一组 / 下一组 / 完成”外框在不同阅读主题与横竖屏下的完整包裹效果。
4. 排版设置面板：常规竖屏/横屏下“阅读背景”与“快捷排版”三列等宽居中、选中角标不推移标题/数值中心、“恢复默认字号与行距”居中包边与确认恢复逻辑。
5. 大系统字号 / Accessibility XXXL Dynamic Type、VoiceOver 与 Reduce Motion 下的完整换行、焦点顺序与 44pt 触达验证，以及 iPhone 13 / iOS 16.6.1 真机复核。
