# 阅读 UI 稳定与紧凑反馈（本地修复）

## 基准与范围

后续以 `fd9d9aa163cf9546bfe3b6f47e3bc8a82371d91a` / Task3 `41593488155/1` 为基准：146 项原生测试通过，设备 Release 编译与 IPA 八类检查通过。对应 IPA SHA256 为 `d8a033697a1a295882cdb34c37db1fbb8ecfaaa46e40952b2ed9dbc7e58eb5de`。用户本次反馈“当前包未发现异常，主要功能正常可用”，同时提出三处 UI 问题；这是主要功能可用反馈，不推断为此前所有手机步骤逐项完成或全面视觉验收。

本批仅本地修改、检查与说明，不包含新的 commit/push、Actions/native 执行或 IPA；旧包仍是已验证基准，不含本次未提交修改。

## 修复

### 1. dock 对齐、尺寸与正文稳定

原收起按钮没有展开外壳的四周 4pt 留白，正常字号时外壳高度存在 8pt 差异；显示时还存在 6pt 位移过渡。原工具 VStack 作为主 ZStack 子项参与尺寸提议。

- 收起与展开都使用同一个 `dockSurface(cornerRadius: 24)`，共用 4pt 内边距与原控制高度。
- dock 作为 `.overlay(alignment: .bottomTrailing)` 的次级布局，不再参与正文主布局尺寸；原水平16pt、底部8pt设计间距不变，不另加安全区补偿。
- dock 显示仅淡入淡出，没有 offset/scale 位移。按钮内部尺寸继续隔离动画。
- 展开增加目录/排版/收起按钮，**宽度按内容变化是有意行为**；稳定的是右边缘、底边、正常字号下控制高度和正文视口，不把展开的三个操作压成与一个操作同宽。
- 大号辅助字体/窄屏仍保留 `ViewThatFits` 与竖向工具滚动。必要的适配高度不强行锁死，不裁字、不缩小字体、不缩减44pt点击区。
- 原 focus、visible/canInteract、保存失败、目录/设置准入、中央点击/惯性/VoiceOver/scene身份与退出保存逻辑不改。

### 2. 紧凑导入结果提示

原结果为独立 Section，标题、说明、文字关闭按钮纵向排列。现在使用单行容器中的紧凑双行文本 + 右侧44×44关闭按钮，行内边距减小，取消独立结果段占位。普通短成功说明因此更紧凑。

原 `notice.title/detail` 完整保留，长的停止后已提交/准备暂缓/重复书位置说明仍可换行；不隐藏失败，不将已提交改成取消，不自动定时消失。大字号下高度按完整文字增长是必要适配，不承诺所有状态固定高度。导入进度、停止请求、编码选择、picker、异常提示、入架与保存状态机不变。

### 3. 诊断标签默认关闭

已确认原 UIKit 控制器在 Debug 和 Release 都无条件创建、安装黑底 `DIAG` UILabel；它虽然不接收触摸且不进入AX树，仍会视觉常驻正文。这不是手动“诊断与耗时”页面本身常驻。

- 标签改为可选、按需创建。Release 的 `interactionDiagnosticsOverlayEnabled` 始终返回 false，不能靠环境变量开启。
- Debug 默认也不创建；仅显式 `YUEJING_READER_DIAGNOSTICS=1` 时创建，且仍不接收触摸/不进入AX。
- 无标签时不进行标签布局/绘制。原有有界被动 recorder 和交互/scene 回调保留，不把它们当作问题根因而删除。
- 侧栏及阅读设置里的手动诊断页、许可证入口保持。

## 验证

本地：`python -B scripts/check_reader_ui_stability.py --self-check`；原 `run_reading_ui_tests.py --preflight --self-check`；冻结 inventory 检查；Git差异/未改文件/用户文件/Skills/锁/旧证据哈希保护。

检查器将声明为 source-only，并验证原97条UI断言和原Host测试行仍保留、严格App返回与退出查询辅助代码不变、三处最小修改区域以外的代码不变；负对照必须拒绝错误偏移、减小点击区、删提示详情、默认开启诊断和删除新增断言。共享 padding 算术不是 SwiftUI 布局仿真或实测。

原生回归已补充但**本批尚未编译/执行**：
- 现有 `testRepeatedPanelsAndAuxiliarySheetsReturnOnlyToReading` 增加常规字体 dock 右边/底边/控制高度0.5pt稳定与再次展开同框断言；保留原viewport不变/反复开关/诊断许可证返回断言。
- 现有 `ReaderThemeUpdateTests.sameThemeUpdatesAreIdempotentAndRealChangesStillApply` 增加诊断默认关闭、Debug显式开/Release不允许开与默认不安装标签断言；原颜色、窗口、锚点/offset断言保留。
- 原147声明/146选择、Host9/UI9/Canvas3、97原UI断言和Host480s/UI900s/case180s/open20s/exit10s预算不变。新增断言不等于新增测试身份或原生通过。

Windows无Xcode/UIKit运行环境。本批静检通过不能替代Swift编译、SwiftUI几何、辅助字体、VoiceOver或手机视觉验收。需要另行批准发布/单轮原生验证及同源IPA后，才可在手机核验本次修复。

## 新包后必要手工验收（当前未执行）

仅合成TXT，不卸载、不清库、不删原书/进度。首个异常即停。
1. 正常字号下反复收起/展开dock：右下锚点及按钮高度稳定，展开宽度合理改变，正文/章节不跳；目录/排版开关返回也不漂移。
2. 辅助大字号、浅深色、窄屏检查：按钮可达、44pt目标保留；工具过高时只滚工具，正文位置不变。
3. 导入成功/重复/取消/准备暂缓说明：普通成功提示紧凑，长说明完整换行且可关闭；书架和原进度不受影响。
4. 正常Release阅读没有黑底DIAG，手动打开诊断页并关闭仍可回正文；滚动、中央点按、退出复开、其他App返回与进程重启恢复仍正常。
