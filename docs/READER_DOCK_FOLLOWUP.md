# 导航与阅读 dock：唯一 C 方案（仅本地）

## 当前结论

- A/B dock 没有帧率或真机对照证据证明卡顿已修复；不能把此前只改 C 的结果归给 A/B。
- 按用户明确选择，最终只保留 **C：侧边栏导航＋右侧展开 dock**。本批实际删除 A/B 的 Swift 运行分支、布局枚举、切换菜单及布局偏好读取，不是隐藏入口后保留多套实现。
- 用户已反馈旧交付包“切屏后再切回来已能正常唤出工具”，并澄清剩余体验是卡顿；未报告按钮或面板失效。本批不臆测新的按钮故障。
- 当前 C-only 候选尚未 Swift 编译、打包或真机运行。上述旧包反馈不等于此候选通过验收。

## 本地修改范围

用户批准原文：`批准9路径本地收敛为唯一C方案并检查`（消息 ID 不可用）。基线 HEAD 为 `a261cee99e6bb5ed956b343d36756dc336c437ff`。仅修改：

1. `App/ContentView.swift`
2. `App/Library/LibraryLayout.swift`
3. `App/Library/LibraryNavigationShell.swift`
4. `App/Library/LibraryShelfContent.swift`
5. `App/Library/LibraryExploreSettings.swift`
6. `App/Reading/ReaderScreen.swift`
7. `App/Reading/ReaderFloatingToolsView.swift`
8. `scripts/check_reader_dock_followup.py`
9. 本文档

旧 layout defaults 不再读取，历史 a/b/未知值不再影响固定 C；不写入或删除用户旧设置，不清书籍、进度或阅读背景。书架、探索、设置仍是同一个侧栏中的页面，不是三套导航方案。历史设计稿和检查证据仅作留档，不是运行时选项。

## 保留的行为

- 书架仍使用原 C 的书籍顺序与稳定身份、导入门控、notice、取消和重试；探索、设置外壳与许可页不变。管理操作的 busy、侧栏关闭及 expected-ID 路由门控保留。
- ReaderScreen 只删除布局属性和 dock 布局参数，并将 padding 固定为原 C 的水平 16／底部 8；其余场景恢复、手势、意图准入、面板、退出和保存代码不变。
- C dock 从 `edgeDock` 至文件末尾与本批前快照完全相同，包括上一轮稳定 ZStack、右下锚点、互补显隐、命中／辅助功能门控、焦点、禁用条件及操作。全组工具仍由原 ReaderToolVisibility 控制显隐；不添加新计时、重试、强制唤出或全局手势。
- Viewport／Controller／ViewModel／Domain／Picker／测试断言／计数／工作流／依赖均不在本批改动内。保持 iOS16.6、Swift语言6.0。

## 本地检查及其含义

唯一现行检查入口：

```text
python -B scripts/check_reader_dock_followup.py --baseline artifacts/c-only-consolidation-local-20261102T082933869036Z/baseline.json --self-check
```

检查真实九路径快照及哈希、七个 Swift 文件的明确转换后全文、App Swift 中旧方案引用、C 的命中／辅助功能／焦点／动画约束、九路径外保护文件，以及 HEAD／index／暂存区／diff。负面对照仅在内存中进行，不改源码。它是源码文本检查，不是 Swift AST、编译、UIKit 测试或性能测试。

本批证据目录：`artifacts/c-only-consolidation-local-20261102T082933869036Z/`。最终执行结果以其中 `REPORT.md`、`verification.json` 和原始命令回执为准。既有 inventory／runner 自检只验证声明与合成解析器，不能当成 146 项原生测试通过。旧三布局 checker 不修改、不借用其固定三布局合同宣称当前通过。

## 尚未验证与阻碍

C 的节点稳定化避免展开时重新插入分支和第二段呈现动画，但隐藏内容仍参与布局；净 CPU／GPU／RSS／FPS 收益、短屏与大字号布局、真实穿透及 VoiceOver 尚未证明。**不能宣布卡顿已消除。**

本机 Windows 无 Swift／Xcode／UIKit；本批只批准本地收敛与检查，未批准 commit、push、Actions、原生执行或新 IPA。旧包不包含这些未提交修改。若后续另行批准原生验证，应针对同一 C-only 候选核验编译、侧栏导航、展开／收起、滚动与切 App 返回、目录／排版／退出恢复，并以同机帧时间实测判断卡顿，而不是继续保留 A/B 或清用户数据。
