# 两项 UI 失败的本地修正候选

## 状态与范围

基线为 `e256667fa2d40616ff08be671c29adcbb9a9368b`。用户批准对上轮两项 UI 失败做有界定位与最小修复；本批仅本地修改和检查，**未提交、未推送、未触发 Actions、未安装**。

**本轮原生执行：0，原生构建：0，未生成新 IPA。尚未证明两项失败已在原生环境消除。** 后续提交、云端验证与打包须另行批准。

上轮 [Task3 #40905320329](https://github.com/wan780839395-cyber/YueJing/actions/runs/40905320329) 的真实结果仍为 133 通过、2 失败、3 未执行，实际模拟器为 iPhone SE（第 3 代）/ iOS 18.5 / arm64。它不验证本批未提交修改，也不代表 iPhone 13 / iOS 16.6.1 真机表现。

本批只修改三个既有文件，并新增本说明：

- [ReaderScreen.swift](D:/ai项目/YueJing/App/Reading/ReaderScreen.swift:149)：标题栏纯背景/描边的命中与朗读职责。
- [ReaderFloatingToolsView.swift](D:/ai项目/YueJing/App/Reading/ReaderFloatingToolsView.swift:25)：底部工具纯背景/描边的同类约束。
- [ReadingFlowUITests.swift](D:/ai项目/YueJing/Tests/YueJingUITests/ReadingFlowUITests.swift:154)：大辅助字号退出后等待的具体书目目标。

不修改书架排序/布局、阅读视口、会话、路由、保存、目录、编码、数据库、版本号、图标、出包脚本、测试清单或工作流。

## 1. 大辅助字号：错误的固定书目等待目标

`testAccessibilityFontLeavesExitAndPanelControlsReachable` 打开的是 `UITest-Short-B`。上轮日志显示设置打开/关闭完成，并实际点击了退出按钮；随后失败在退出辅助函数的书架书目等待。

进一步读取 [失败后的完整 AX 层级](D:/ai项目/YueJing/artifacts/release-0.2.0-native-20261029T154541Z/download/12911239936/reading-ui-native/YueJingUITests-attachments/83F5827C-2C0C-44CB-A880-DD48BEAD010D:24)，可确认该次截图/AX 取证时已在 `library.screen`。可见按钮为 `UITest-Short-B`，而固定查询的 `UITest-Long-A` 不在该次 AX 树中。大字号使书架行和头部增高，不能假定另一本文字书目无需滚动就可见，也不能把屏幕外行未出现在 AX 树中误记为未返回书架。

因此本项有明确的测试前提错误：把“正确返回书架”与“特定另一本文字书目立即可点击”混在一起。不能为了让旧查询通过而缩小字号、重排书架或强制滚动生产页面。

修正方式：

- 给现有 `exitReader` 辅助函数增加 `shelfBook` 参数，默认仍为 `UITest-Long-A`，其余调用不变。
- 仅大字号用例明确传入刚阅读的 `UITest-Short-B`。
- 返回后仍用原 `label BEGINSWITH` 精确书目查询和 `waitHittable`，不是只检查任意按钮或仅检查书架标识。
- 退出与设置按钮同时存在且可点击的前置断言、真实按钮点击、返回后可点击断言、错误正文排除以及原有十秒共享总预算均保留。

这修正了有证据支持的等待目标错误；并未在 Windows 上证明新的等待一定通过。

## 2. 滚动后退出：约束纯装饰层不参与命中

`testSettingsCloseThenScrollExitAndReopenSameAndOtherBook` 上轮在双控件就绪条件超时。其 [失败后的顺序观察](D:/ai项目/YueJing/artifacts/release-0.2.0-native-20261029T154541Z/download/12911239936/reading-ui-native/YueJingUITests-attachments/7E350EF7-2AA8-4E09-9010-AF49AD16C062:2) 显示：退出按钮存在但 `isHittable=false`，设置按钮存在且可点击。

早期有效 [命中样本](D:/ai项目/YueJing/artifacts/release-0.2.0-native-20261029T154541Z/download/12911239936/reading-ui-native/YueJingUITests-attachments/CD8B4419-EDAE-4BB3-973E-4E0816F97437) 显示工具为 compact/visible/canInteract，退出中心点的 UIKit 命中链首项是 `_UIShapeHitTestingView`，尺寸 351×52，与标题底面一致。这支持检查装饰层命中职责，但它是早期非原子观察，**不能独立证明是背景还是描边，更不能证明失败时仍命中同一节点**。

失败时及较晚的探针已达到 32 次采样上限，明确返回 unknown；本批不提高上限、不把未知样本伪装成有效结论，也不宣称根因闭环。

产品侧仅做一项按职责约束的修正候选：

- 把标题栏及底部 Dock 的 RoundedRectangle 纯背景/描边显式放在各自 background/overlay 内容中。
- 只对这些形状设置 `allowsHitTesting(false)` 和 `accessibilityHidden(true)`。
- 真实 Button、label 的 `contentShape`、44pt 最小触达尺寸、禁用条件、焦点、工具显隐门控、动作和动效不变。
- 20/18pt 圆角、填充颜色、0.5pt 描边、padding 与 frame 参数保留；不新增占位、安全区调整、坐标点击、等待或手势。

该改动避免纯装饰被当成交互表面，是最小语义修正；其是否消除滚动后的退出命中问题，仍须原生回归确认。

## 3. 已执行的本地检查

1. 以修改前实际工作树冻结基线，核对恰好三个既有源码文件变动及本说明新增；HEAD 和暂存区不变。
2. 200 个范围外保护文件哈希不变，包括用户三个文件、项目 Skills/lock、版本/资源、原有验证脚本及两份旧 IPA。
3. 1828 份上一轮原始下载证据/Actions 日志 ZIP 的尺寸与 SHA256 不变；原失败报告、计数和运行终态记录没有被覆盖。
4. 把两处已知装饰层修改反向归一化后，与基线全文相等，确认所有动作、状态、布局参数、生命周期、保存及调试桥接未夹入其他修改。
5. 对 UI 文件同样反向归一化，仅允许书目参数、对应调用和说明注释的差异；原 `XCTAssert`、双控件就绪条件、通用 `waitHittable` 与十秒预算保持。没有添加 skip、坐标点击、sleep 或失败吞掉逻辑。
6. 逐函数清单仍为 138 项，其中 UI 8 项；没有改名、删除或追加用例来改变验收分母。
7. `git diff --check` 通过。既有离线门控自检 13 组、Swift 日志解析样本 40 组、App 日志解析样本 12 组通过；App runner 的 `--preflight --self-check` 通过，原生执行均为 0。
8. 一次有界模型只读复核未发现本改动的具体源码缺陷；该复核不是 Swift 编译、UI 执行或根因闭环证据。

本批检查脚本和结果只在会话 scratch 的 `freeze_reader_hit_fix.py`、`validate_reader_hit_fix.py`、`reader-hit-target-fix-local/baseline.json`、`verification.json` 与离线日志中，不写入项目工具链或原生结果目录。存在性、哈希和源码断言数量不计作 Swift/iOS 测试通过数。

## 4. 尚未完成的验收

- 尚无本批 Swift/Xcode/actool 编译或 UI 原生重跑；不能用上轮模拟器编译成功证明当前改动可编译。
- 需在原预算和原断言下复核大字号返回书架、关闭设置后滚动/显示工具/退出、快速显隐、横竖屏、VoiceOver 及 Reduce Motion。
- 第二项命中问题的修复效果和完整根因尚未证明；若再次失败，应先读取新证据，不自动叠加补丁或延长等待。
- 只有另行批准的新候选完整原生门通过后，才进入设备 Release 构建和 `YueJing-0.2.0.ipa` 校验。旧 IPA 仍是原 0.1.0（1），本批没有新安装包。
