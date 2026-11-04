# 书签UI长流程超时：独立场景拆分

## 范围与批准

基线：`82ff8437f8ff477544788961555c5201702ad713`。用户明确批准 **“批准五文件修复及一次原生验证”**。

仅改：`Tests/YueJingUITests/ReadingFlowUITests.swift`、`scripts/task3_test_inventory.py`、`.github/workflows/task3-validate.yml`（两处步骤显示名称），新增 `scripts/check_bookmark_ui_timeout_split.py` 和本文。

不改App/Sources、其他测试、公共交互helper、runner/parser、依赖或超时。一次普通commit/push、既有Task3 full workflow_dispatch attempt1；完整167项真实通过后才设备Release编译和IPA校验/交付。失败停止，不自动修补重推或原生重跑。

## 原因证据

同产品/同测试源码的run41767851984及run41781787985均选中166项，162通过、1个书签长流程超时失败、3项Canvas未执行。单例180秒，UI整体1200秒未触发。日志中动作连续推进，不以may-have-hung模板认定App卡死。

| 阶段 | run41767851984 | run41781787985 |
|---|---:|---:|
| 重启后bookmarks-restored证据完成 | 123.12s | 129.41s |
| 80pt短距离拖动开始 | 125.26s | 131.57s |
| 第一次回跳原书签 | 165.24s | 170.26s |
| 第二书签回跳动作（已过180秒，非通过证据） | 182.77s | 189.02s |
| 最终证据完成后终止App | 203.53s | 210.37s |
| UI Actions步骤总时长 | 1089s | 1136s |

单例累积了两个可独立验证的场景，正常操作总量已超预算。Actions步骤还包括准备/导出，并不等于native1200秒预算。拆分有额外fixture启动/初始书签准备成本，不保证总耗时一定下降，是否达标须原生实测。

## 覆盖与断言映射

| 原长用例阶段 | 修复后归属 | 保持项 |
|---|---|---|
| 新增取消、添加时命名、精确位置去重、重命名 | 原 `testBookmarksPersistIsolateAndJumpAfterRelaunch` | 全部原动作和断言 |
| 跨章移动、B书空列表、进程终止/重启、A书名称持久化与回跳 | 原用例 | 同fixture UUID/数据库的真实relaunch不移除；恢复后仍验证名称、数量、正文及去重 |
| 同章80pt移动、第二书签创建/改名、双目标独立精确跳转及列表 | 新 `testNearbyBookmarksKeepIndependentNamesAndExactJumps` | 原后半段逐字保留；首次<2pt、第二<=44pt且离开首位置>2pt，绝不降低几何精度 |
| 大字体/关闭/取消删除/确认删除 | 既有大字体用例 | 完全不变 |

新用例通过自己的 `withFixture` 创建独立UUID/数据库，在真实UI中添加首书签，确认名称/数量/去重后进入原后半段；不继承其他用例状态，不使用mock/数据库直写代替操作。新setup有独立截图/AX证据。除插入旧方法结束与新方法setup外，原UI文件所有字节都保留，可反向还原到基线SHA256。

原11项UI身份全部保留、新增1个场景身份：UI12、完整167、声明168（原独立性能基线仍排除）。这是测试组织拆分，不宣称新增产品能力。其余组保持Core25/Domain107/Block6/measurement1/Host13/Canvas3。

## 预算与执行链

- 单case180秒、UI1200秒、Host480秒；workflow60分钟、UI step23分钟不变。
- 同一UI target、原串行选择、原计数/来源/失败门、原设备编译与打包顺序不变；工作流仅更新两处步骤名称。
- 不添加重试、补点、睡眠或绕过ready的接口；不因拆分而把历史失败改成通过。

## 本地检查

`python -B scripts/check_bookmark_ui_timeout_split.py --self-check`

检查固定基线反向还原、原断言文本/次数、独立fixture、原UI身份、完整清单与工作流两处显示差异；固定runner/parser hash确保预算未变。负向控制破坏几何、数量、隔离、relaunch、helper、计数或预算时必须拒绝。

另跑inventory自检、runner preflight/self-check、bookmarks离线检查、Python AST、YAML、Shell语法、精确五文件/index/保护哈希检查。Windows检查不是Swift编译或XCTest运行；结果存ignored artifacts。

## 原生验收与降级边界

本实现冻结时未执行修复后原生验证，不能提前宣布超时已修复。实际须两个独立场景均通过、UI12和全167逐项完成、零跳过/失败/未完成，并核验原始退出码、证据与同源IPA。

若失败，保留真实首错，不直接扩大预算或重跑。用户希望尝试诊断编译，但旧出包scope均锁定历史源码；必要时根据实际失败另行界定新的最小出包范围。不得把旧IPA冒充新包；未签名包仍需已有安装通道，先备份、不卸载清库。
