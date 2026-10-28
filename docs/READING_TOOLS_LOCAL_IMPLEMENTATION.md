# 阅读工具浮岛：本地候选（2026-10-28）

基线为`1eaaaddae8b34f9101be8b15099db57108a8e8be`。本批只实现用户选定的“同色系浮岛＋沉浸显隐＋连续展开”，不照搬模型B提案；不提交、推送、调用Gemini、触发Actions、构建或安装。此前111项原生通过属于基线，本批新增源码不继承该验收。

## 范围与状态

- 阅读页用暖白同色系工具面板、相近炭黑暗色面板与弱赤陶强调，实际明暗由阅读主题控制；不增加主题枚举、不改纸色/白色/深色背景设置语义，没有深绿强对比或光晕。
- 顶部标题胶囊保留退出。底部紧凑Dock只有目录、设置。中央轻点显示/再点隐藏，开始主动滚动隐藏，停滚不自动出现；显隐时工具与装饰边线一起隐藏。
- 目录与设置共用一个持续存在的浮动容器，正常动画只改变工具容器几何与透明度。关闭/完成回紧凑Dock，选章回沉浸；两个面板可直接切换。同面板重复点击不分配新会话。
- ReadingToolsPresentation仅持有UI意图、面板UUID、挂起与退出状态，不持有阅读器/文档/位置/设置快照。每次新意图撤销旧触摸令牌；关闭、选章与退出完成都检查身份。没有延时动画完成回调重新写状态。挂起撤销面板，恢复不自动展开；读取/退出错误保留显式退出入口。
- 目录保持原32项分页、真实当前语义锚点、已有reveal/request/owner/presentation门控。旧目录同步dismiss，迟到onDisappear仍按旧UUID关闭；行点击额外核对ownerRevision。设置仍即时应用并按原方式保存，旧面板的Binding写入/changed/关闭回调均需当前会话，完成不表示撤销。

## 手势与视口边界

- UIKit只新增中央单击桥：不取消既有触摸，等待原pan失败，不注册边缘上滑或Dock拖动，保留原正文滚动与已有选择/触摸处理。目录列表的滚动仍由自己的List处理。
- 在shouldReceive及识别器touchesBegan阶段锁存减速/拖动状态，tap结束再判断时仍保留起始快照；减速中的第一次触摸只让UIKit原生停滚，不切换工具。桥接不setContentOffset，也不生成位置保存事件。真实UIKit事件顺序及选择竞争仍须原生验证。
- touch.location(in: table)包含滚动bounds原点，生产helper先减originX/originY再判断中央区；新增非零offset回归。VoiceOver不走普通单击判定，正文可访问元素提供“显示阅读工具”“退出阅读”自定义动作。
- 正文上下边距由几何、字体和紧凑工具所需空间决定，不依赖工具visible/panel状态；显隐、面板动画不会反复改viewport高度、contentInset、排版宽度或锚点。没有84pt固定padding，没有首帧/零白闪保证。目录/设置展开是工具覆盖层，覆盖区暂不交互，关闭后回到同一稳定阅读视口；不承诺展开面板时背景所有行都可见。
- 大字模式可纵排两个Dock按钮，矮屏保留带无障碍名称的图标按钮，标题最多两行且完整书名可朗读。旋转/系统字体变化可按新几何重新布局，这不同于工具显隐；原宽度变化与位置恢复路径不改。正文末行、短/长章、横屏与最大辅助字号的可达性仍待原生/真机核对。

## 无障碍与动效

Reduce Motion时容器内部transaction清除尺寸/位置动画，只有外层工具透明度淡变；普通模式仅工具层使用iOS16已有interactiveSpring，不传播到正文。不使用iOS17动画API。Reduce Transparency时工具底色为实底，默认仅轻微透明、无动态模糊。目录打开可先聚焦关闭，reveal到达后聚焦当前章；设置聚焦完成，关闭回工具退出入口。设置的嵌套NavigationStack显式请求显示导航栏，保留完成、诊断/许可导航与返回；父阅读页只隐藏自己的工具栏，真实嵌套导航可发现性仍需原生验收。每个迟到焦点任务都检查取消与当前会话/意图。真实VoiceOver焦点顺序、系统提示竞争与动态效果表现未验收。

## 文件白名单与保护

修改6份既有UI文件：App/Reading/ReaderScreen.swift、ReaderViewport.swift、ReaderViewController.swift、ReadingCell.swift、ReaderDirectorySheet.swift、ReaderSettingsView.swift。

新增5份：App/Reading/ReaderToolAppearance.swift、App/Reading/ReaderFloatingToolsView.swift、Sources/ReaderDomain/ReadingToolsPresentation.swift、Tests/ReaderDomainTests/ReadingToolsPresentationTests.swift、本说明。共11份。

ReaderViewModel、ReaderDirectoryViewModel、既有ReadingDirectory、ReaderPreferences、TXTCore、派生格式/缓存/数据库/位置契约、书架、全部原111测试文件、工程/依赖/CI均保持。ask_architect.py保留已获准的timeout改动，三个用户本地文件、Skills/lock、私有会诊与工具记录保持，不执行脚本或读取小说。

## 回归与验证口径

新增10项Swift Testing声明，覆盖：触摸令牌、主动滚动与恢复不自动显示、关闭/选章语义、连点跨面板与迟到回调、挂起取消、退出单飞/失败/迟到、非零bounds坐标、触摸起始减速锁存、重复同面板意图。不新增App host、UI测试框架或截图依赖。

声明计数为25 Core Debug＋89 Domain Debug＋6 Block Release＋1原测量Release＝121唯一测试。后续若另获一次原生验证授权，需同步`.github/workflows/task3-validate.yml`的Domain79→89，以及`scripts/validate_task3.py`的Domain79→89、Domain合集80→90、总数/产物报告111→121。当前这两配置仍按111，未修改、未运行，不能直接据此候选触发旧计数CI。

Windows本轮只执行文本、词法、计数、范围及文件保护检查。Swift/Xcode编译、121项原生测试、模拟器、iPhone13/iOS16.6.1真机、帧率与实际手势/VoiceOver验收均not-run。词法检查不是Swift解析或类型检查，纯状态测试声明不能替代UIKit事件顺序、滚动/选择手势、短长章末行、动态字体和位置恢复的真实验收。静检证据仅存ignored artifacts/reading-tools-local-20261028，完成后本地idle，等待下一批发布批准。
