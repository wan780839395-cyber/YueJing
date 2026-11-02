# 唯一 C：dock 与侧栏本地优化

## 范围与现状

基线 `71887645d3612c2f7298099d7ff99897c15fc71f`。用户确认只有 C 布局、工具唤出/隐藏和右侧展开/收起均显得低帧，目前没有其他已发现功能异常；截图显示侧栏与上方导航栏割裂。用户另行批准8路径本地优化与检查，不提交、不推送、不改工作流、不触发构建。

本次仅改5个既有Swift文件，新增一个纯展示侧栏、一个检查器和本说明。App身份/最低iOS16.6/Swift语言6.0/Xcode16.4/GRDB7.0.0不变，不引入框架。保留现有全部Tests、历史失败和旧检查器，不把旧三布局检查器改成宽松判据。

## 性能：已确认事实与未确认根因

源码可确认：

1. 旧dock除ReaderScreen外再次以ObservedObject订阅整个ReaderViewModel；现改为传入目录可用、排版可用、保存失败三个展示值，避免子视图独立接收整个模型的发布。父视图仍观察真实模型，不缓存正文、路由或业务状态；不保证父视图更新时子视图body绝不重算。
2. 旧收展在共同祖先禁用了动画，两个opacity直接切换。现只为两个稳定控件组的opacity各设置现有160ms过渡，子文本/尺寸/布局仍禁止继承动画。不是改大面积frame、缩放或模糊；整体工具显隐继续沿用原ReaderToolVisibility。
3. 生产交互诊断在触摸链中多次调用paint，原来每次都写UILabel.text。现仅在最终完整字符串不同的情况下赋值，所有事实、事件、顺序和64条上限不变，无延迟、定时器或丢样。字符串组装仍会发生，本次不能宣称消除了全部诊断计算成本。
4. 已有ReaderViewport在窗口ID相同时跳过apply/reloadData，setTheme已有相同主题短路。不能把这条已存在的保护说成这次修复，更不能无证据归因为每次开dock都重排正文。

尚未取得iPhone13/iOS16.6.1的帧时间、主线程采样、提交/渲染卡顿或GPU数据，因此以上是有依据的局部优化，不是已测得的唯一掉帧根因。增加opacity过渡主要解决硬切换观感；是否改善实际帧率必须重新测量。ViewThatFits及大字号滚动回退保留，隐藏组仍参与布局，不声称相关成本已归零。

参考：实际读取了Apple [Demystify SwiftUI performance / WWDC23](https://developer.apple.com/videos/play/wwdc2023/10160/) 的文字稿：0:52测量、1:33优化后重新测量、依赖更新、11分钟后慢更新与字符串插值成本。采用其诊断原则，不移植新SDK或Observation。当前工作区未找到名为仙侠的项目，没有读取其他目录或声称已完成仙侠代码对照；仍需明确路径才能对照。

## 侧栏方案：完整覆盖式抽屉

原抽屉在LibraryNavigationShell正文的ZStack内，故覆盖正文但不覆盖导航栏，导致顶部书架/导入与下方菜单形成两套头部。新LibrarySidebarView挂在原NavigationStack外的overlay，避免以zIndex、缩放主界面或移动书架补救。

- **打开**：全局遮罩同时覆盖导航栏与主内容；面板表面延伸上下安全区，内容仍避开系统区域。标题改为紧凑“阅境/阅读与书库”，关闭按钮同排；导航与辅助入口分层，保留书架/探索/设置/诊断/许可全部入口。
- **比例**：宽度 `min(304, max(0, availableWidth - 64))`；常见390pt宽度下304pt面板、86pt遮罩区；窄屏收窄，始终不超过可用宽度，不挤压主内容。
- **关闭**：遮罩和抽屉不接收触摸；底层NavigationStack、列表宽度与书籍位置不变，没有新的主页面owner或重新装载。
- **适配**：菜单可滚动，语义字体随系统文字大小变化；明确的关闭、遮罩关闭、Escape与VoiceOver焦点转移保留；Reduce Motion禁用位移动画。实际安全区、横屏、大字体和VoiceOver仍待原生确认。

## 功能保护

ReaderScreen只改变dock参数传递；工具state、中央20–80%触摸准入、惯性先停后唤出、native scene authority、route/owner/binding/revision、退出保存、窗口/锚点/排版和异步取消门控不改。ReaderViewController仅变更paint赋值，不改手势、表格、布局或回调。ContentView保留唯一StateObject、NavigationStack、fullScreenCover、`.id(route.id)`、Picker、目的地及全部busy/expected-ID门控；侧栏仍调用原父级动作。

## 本地检查与验收边界

检查器必须使用本批真实preimage，不用旧HEAD臆造改前内容：

```text
python -B scripts/check_c_dock_sidebar_polish.py --baseline artifacts/<本批冻结目录> --self-check
```

检查五个既有文件的精确允许变换、新侧栏合同、Swift词法括号、16个内存负例、12组宽度公式、HEAD/index与白名单外文件哈希。宽度演算不是SwiftUI实际布局，词法检查不是Swift编译，负例不是原生测试；任何数值不代表FPS。

### 后续原生/同机验收（本次尚未执行）

1. 经另行批准后才提交、云端原生验证和打新IPA；不能把上个7188764的IPA当本次优化包。原九项UI历史失败不因此消失。
2. 同一iPhone13/iOS16.6.1、同一合成长书、相同字体/主题/竖屏、相近温度与电量状态，分别对比工具显隐、dock收展，冷首次和后续稳定操作分开记录；低电量模式状态保持一致。
3. 手机原生录屏可用于前后可见流畅度和功能比对，但不能直接代替渲染帧率或Instruments的hitch测量。若可获得原生性能轨迹，分别核对主线程、commit/render hitch与实际显示帧时间；60Hz单帧预算约16.67ms，不以平均FPS或缩短动画时长冒充验收。
4. 普通/最大辅助字体、Reduce Motion、深浅外观、侧栏开关/切栏目/辅助页/关闭区域，确认无导航栏割裂、正文挤压或触摸穿透。维持原工具召回、排版、目录、退出保存、重启恢复功能；不卸载、不清库、不使用私人正文。

当前本地Windows没有Swift/UIKit/Xcode运行时。未做Swift编译、原生UI/功能/帧率/真机视觉验收，没有生成优化版IPA；本地检查结果另存ignored artifacts，不覆盖历史失败。
