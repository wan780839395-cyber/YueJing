# 阅读页顶部退出描边后置：本地最小候选说明

## 1. 范围与确切代码差异

本候选以 `7a5753658e686a9c3ed7886136a79cdb23d99a49` 为唯一基线，唯一生产源码改动位于 `App/Reading/ReaderScreen.swift` 顶部 `titleBar` 装饰块（第 154–155 行），仅调整标题栏描边与填充相对按钮内容的前后层级：

```swift
// 基线（7a5753658e686a9c3ed7886136a79cdb23d99a49，第 153–156 行）
        .padding(.horizontal, 8).frame(minHeight: metrics.titleHeight)
        .background(appearance.fill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(appearance.edge, lineWidth: 0.5) }
        .padding(.horizontal, 12).padding(.top, 6)

// 本候选（第 153–156 行）
        .padding(.horizontal, 8).frame(minHeight: metrics.titleHeight)
        .background { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(appearance.edge, lineWidth: 0.5) }
        .background(appearance.fill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12).padding(.top, 6)
```

层级语义由前到后变为：标题栏 `HStack`（含真实 `reader.exit` 退出 `Button` 与书名）→ 0.5pt 连续圆角描边 `.background` → 填充 `.background`。这里是将 `stroke` 移至 `fill` 之前并由 `.overlay` 改为 `.background`，使描边不被填充遮挡，同时确保纯装饰描边不再处于按钮前景。

本次不添加 `.allowsHitTesting(false)`、`.accessibilityHidden(true)`、`zIndex`、新手势、新容器或新 UIKit 按钮；配色、连续圆角 `20`、线宽 `0.5` 及现有全视口不占位布局参数不变，但未经原生渲染比对，不声称像素逐点完全同图。底部 `App/Reading/ReaderFloatingToolsView.swift` Dock 完全不动。

## 2. 真实原生基线与证据边界

基线 `7a5753658e686a9c3ed7886136a79cdb23d99a49` 的单次云端验证（Actions Run `41019503235`，attempt 1）真实结果为：计划 **138** 项，**134 passed / 1 failed / 3 unexecuted / 0 native skipped**（`YueJingCanvasTests` 3 项因上游步骤失败未执行，非原生跳过）。

- `YueJingUITests` 8 项中 **7 项完整通过、1 项失败**；全部 8 项首次开书 `reader.tools.settings` 功能入口门均通过。
- 大系统辅助字号 `Short-B` 用例（`testAccessibilityFontLeavesExitAndPanelControlsReachable`）实际点击退出并等待返回 `Short-B` 书架通过；反复开关面板与辅助页用例通过。
- 唯一失败为 `testSettingsCloseThenScrollExitAndReopenSameAndOtherBook` 在 `Tests/YueJingUITests/ReadingFlowUITests.swift:468–473` 的双控件就绪等待超时（日志第 1437 行）；第 479 行实际退出点击及后续同书/异书复开尚未执行，不能算作已通过。

已知序列与探针边界：

1. **顺序非原子就绪分叉**：该失败用例滚动前 `probe-baseline` 中 `reader.exit` 与 `reader.tools.settings` 均为 `exists=true, isHittable=true`；慢滚后两者均带隐藏偏移且 `isHittable=false`；正文中心点击 `showTools` 后，两者 AX `frame` 均恢复归位（`exit` 回到 `(20, 30, 44, 44)`，`settings` 回到 `(189.5, 611, 144, 44)`），随后顺序查询中 `settings` 持续 `true/true`，而顶部 `exit` 持续 `exists=true, isHittable=false` 直至 teardown。
2. **晚期真实拦截层仍为 `unknown`**：旧 getter 命中探针存在 `sequence < 32` 硬上限（`ReaderViewController.swift:348`），在基线 AX 遍历阶段即已耗尽，故滚动后、唤出后与失败瞬间的原生 `hitTest` 链及控制器瞬态均为 `unknown`。开书早期 `entryprobe` 中的 `_UIShapeHitTestingView` 仅属启动阶段无触摸预测快照，不能证明失败现场的实际遮挡层。
3. **共享退出预算消耗事实**：`exitReader` 在入口（`ReadingFlowUITests.swift:460`）启动原 10 秒共享预算后，`probe-after-show` 取证消耗了 `1.706976` 秒（进入 `XCTWaiter` 轮询前剩余 `8.292859` 秒，随后 8 次轮询均见 `exit.isHittable == false`）。这是已知测试取证混杂事实，不能据此断言超时唯一原因，更不通过拉长预算或删改断言来掩盖问题。
4. **不重复 `bbc1739` 全装饰被动化组合**：历史 `bbc1739` 同时把两处装饰改为 closure fill 背景并叠加 `.allowsHitTesting(false).accessibilityHidden(true)` 时曾出现 8 项共同首入口失败，而 `7a575365` 恢复原样式背景与描边后 8 项首入口全部恢复；因此本候选不重复该组合，仅独立后置顶部描边。
5. **未发现状态机或退出保存缺陷**：源码审查确认共同门控在稳定状态下对 `settings` 不比 `exit` 宽松，且本次失败发生在退出 `Button` action 调用之前，末尾可靠退出保存链尚未执行，故不改状态机与保存事务。

因此，本改动只是语义清晰、范围最小的**局部可证伪候选**，不是已证实的根因修复；实际 SwiftUI/UIKit/AX 命中行为有待原生验证。

## 3. 原样保留的契约与本地限制

以下内容保持零改动：

- 真实 SwiftUI `Button`、`.buttonStyle(.plain)`、最小 `44×44` 命中尺寸、`contentShape(Rectangle())`、中文无障碍标识/标签/`@AccessibilityFocusState`、父层 `allowsHitTesting(visible && tools.canInteract)` 与 `accessibilityHidden(!visible)`、`ReaderToolVisibility` 与 `ReaderMotion`。
- `Short-B` 测试用例、全部 138 项既有测试源码与断言、20/10/480/900/180 秒预算、所有既有 DEBUG `ReaderHitProbeMarker` / `ReaderEntryProbe` / `ReaderHitProbeEndpoint`（不再堆叠新探针）。
- 可靠锚点与 GRDB 退出保存链、会话所有权、文件导入策略、`project.yml`、版本号/图标、`.github/workflows/task3-validate.yml` 及固定部署约束（iOS 16.6、Swift 6.0 语言模式、Xcode 16.4）。

Windows 本地无 Swift/Xcode 工具链，本阶段**原生测试执行数为 0**；本地精确差异、内存反向归一化、保护文件 SHA-256 及 138 项源码清单检查均属于离线静态核验，不能证明 Swift 编译通过或 UI 退出故障已修复。

## 4. iPhone 13 / iOS 16.6.1 / TrollStore 真机人工验收清单（待授权出包）

**当前暂无本候选对应的 IPA 安装包**；仓库历史遗留的旧 `0.1` 测试包无法验证 `7a575365` 或本候选源码。待后续另行明确授权构建同候选 SHA 设备测试包后，按以下清单在真机执行产品验收：

1. **包身份与数据安全前提**
   - 核对测试包 manifest 记录的候选源码 SHA、`version`（`0.2.0`）/ `build`（`2`）及 IPA 文件 SHA-256 与交付记录一致。
   - **先使用合成/可丢弃 TXT 文件测试**，绝不删除或修改个人原书，不卸载清库或人为清空既有阅读进度。
2. **核心复现与单次退出路径**
   - 打开多屏长合成书 → 打开底部“排版”设置调大字号（如 +1）→ 点击完成关闭面板 → 慢速向上滚动正文并待滚动停稳 → 轻点正文中央唤出顶部与底部工具栏 → **单次轻点顶部可见的返回书架按钮**。
   - 判定标准：首次正常点击即响应保存并正常返回书架（不是靠额外再开一次设置面板、反复连点、固定坐标盲点或强退重启应用解卡），无“暂时无法显示正文”或保存报错。
   - 重新打开同一长合成书，确认刚调大的字号与滚动后的语义阅读位置均已保持；再次正常退出后打开另一本短合成书阅读并退出，确认书籍标题、正文与末行可达且无跨书串位。
3. **重复轮次与环境覆盖**
   - 上述完整链路**重复至少 3 轮**，其中浅色主题与深色主题各至少完整覆盖 1 轮。
   - 开启系统大辅助字号（Accessibility Dynamic Type），执行打开短合成书 → 打开设置 → 关闭设置 → 不滚动直接点击顶部退出返回对应书架，确认顶底控件可达且正文视口不被挤压；测后恢复原系统字号。
   - 全程确认书架上原有书籍与既有阅读进度完整保留。
4. **失败录屏隐私边界**
   - 若真机仍出现工具唤出后首次点击顶部退出无响应，可在合成测试书界面录屏留证，无需暴露任何个人藏书书名、正文或私有路径。

## 5. 发布、CI 门禁与测试包交付边界

当前未获任何新 `git commit`、`git push`、GitHub Actions 触发或设备编译/IPA 打包授权。

- 用户在 `iPhone 13 / iOS 16.6.1` 上的实机测试可作为产品侧人工验收依据，但**不能替代或涂改 CI 原生记录为 `138 pass`**。
- 若后续选择真机人工验收路径，须另行取得明确授权，基于同候选源码 SHA 执行设备 `build-only` 生成测试包，并在包 manifest 与本地证据中明确记录“测试未运行 / 当前 CI 138 联合门未通过”，绝不修改 `.github/workflows/task3-validate.yml` 伪装为完整门禁通过。
