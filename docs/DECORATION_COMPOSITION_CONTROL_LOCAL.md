# 阅读装饰组合：本地单因素对照包

## 范围与目的

本包以 `38bb9aad0129d47647bbc17f6cbd0b046748a5bb` 为当前基线，仅在两个位置恢复 `e256667fa2d40616ff08be671c29adcbb9a9368b` 的旧装饰组合，精确反向恢复 `bbc173969f27d2b1ac7ba0bff0f6db8124182a95` 对这两个装饰块的改动；不是整文件、整版本回滚，也不是已证明的功能修复。

- `App/Reading/ReaderScreen.swift` 标题栏：连续圆角 20。
- `App/Reading/ReaderFloatingToolsView.swift` Dock：连续圆角 18。
- 两处均恢复 `.background(appearance.fill, in: RoundedRectangle(...))` 与 `.overlay { RoundedRectangle(...).stroke(appearance.edge, lineWidth: 0.5) }`，替换 closure fill 背景及背景、描边装饰各自的 `.allowsHitTesting(false).accessibilityHidden(true)`。

实验的一个因素是“两处旧装饰组合整体”。两个位置同时恢复，不能独立区分标题栏与 Dock，也不能区分背景重载、描边组合、hit-testing 或 AX modifier 中哪个细项产生影响。

## 保持不变

两处父层 `visible/canInteract` 命中门控与 `accessibilityHidden(!visible)` 保留；所有按钮动作、尺寸、焦点、状态、动画、颜色、viewport、保存逻辑，以及 DEBUG marker、新旧 probe 节点均保留。不新增探针、不坐标强点、不修改断言、不延长超时。

Short-B 修正、全部 Swift 测试、诊断 Swift/Python、workflow、版本、图标、`project.yml`、138 项清单，以及既有 20/10/480/900/180 预算一律不变。固定 iOS 16.6、Swift 6.0 语言模式、Xcode 16.4；不采用技能文档中较新平台的默认要求。

最新诊断仍然保留，诊断节点本身可能影响 SwiftUI/AX 组合。因此本包与历史 `e256667` 不是严格同环境 A/B；只能在当前基线上观察整体装饰组合变化，不能据此单独证明历史根因。

## 证据边界与待观察结果

历史原生结果从 6 pass / 2 fail 变为 8 项共同入口 fail，与 `bbc1739` 的变化存在关联，但当前因果未定。恢复旧组合本身不能证明入口恢复，更不能证明最初两项失败已修复。

Short-B 修正候选在后续共同入口失败后尚未走到，不得说该候选失败或已通过。后续若另获原生验证批准，应先观察共同入口是否恢复、原两项失败路径是否能够走到，再根据实际执行结果判断；不预设通过结果。

完整 138 项逐项真实通过，才具备进入条件 IPA 阶段的前提，并仍须遵守获批的设备构建及同提交产物校验门。本包没有提交、push、Actions、原生验证或发布授权；上述后续行为需另行批准。

## 本地实施检查

本地只做 `git diff --check`、两块替换的精准反向归一化全文对照、保护文件 SHA-256 核对及现有 138 项源码 inventory 离线检查。反向对照是在内存中把两个新块换回当前基线块，要求各自整个文件与冻结基线逐字节一致；不会回写源码。

完整现有离线回归留给随后独立验证员，本实施阶段不重复运行。源码清单、哈希及任何合成检查均不等于原生测试；Windows 没有 Swift/Xcode，本包不声称 Swift 编译、UIKit、SwiftUI/AX 行为、真机功能或 IPA 通过。

冻结基线、校验工具和本地结果仅留在会话 scratch，完成报告仅存 ignored artifacts；历史报告、附件、原两份 IPA、Skills/lock 与三个用户本地文件保持原样。公开源码范围仅为上述两个装饰块和本说明。
