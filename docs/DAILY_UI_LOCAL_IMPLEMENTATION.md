# 日常阅读界面：本地候选（2026-10-28）

基线 `3f60524f1fa30ec0c10956d9313c31fd33b43ef1`。用户批准本地展示、必要有界目录定位适配、回归与说明；本批没有提交、推送、CI、IPA、安装或外部会诊授权。原98项原生通过属于基线，不覆盖以下改动。Windows无Swift/Xcode，本批Swift编译、原生测试、App构建及视觉/无障碍验收均为0。

## 展示与状态

- 书架保留原Store的最近阅读/加入顺序，书名可多行，次要行仅显示阅读日期或尚未阅读；编码和大小不再占用书架主列表。导入安全诊断从常驻顶部移到明确的“诊断与耗时”导航入口，仍保留本轮回调事实、当前阶段、安全错误、阶段记录和原计时摘要。阅读页移除clock入口，设置的“更多”区保留同名诊断入口。诊断不接收书名、路径、正文或书籍hash，不新增遥测。
- 纯值LibraryImportPresentation由实际ImportStage驱动。界面使用“处理文字”“保存书籍”等用户语言，无百分比或系统下载推断。停止只表示请求已发出，按钮防重复，等待LibraryService.cancelImport的权威结果；提交前停止与提交后仍已保存分别展示。成功、重复、选择取消及停止结果为持久可手动关闭的提示，失败仍为需确认的安全错误Alert，没有定时toast。
- 正常导入仍等待既有派生准备，未改原调用顺序、事务、选择器或取消实现。派生延后只显示原件已保存、可打开重试；晚停止不伪报没有入架。阅读页没有新增猜测式“正在建包”状态：保留正在打开标题，辅以“首次打开旧书或需要重新准备时可能稍等”的条件说明。没有新增LibraryService事件或调度。
- 设置仍即时应用并按原方式保存，“完成”只关闭；说明中不承诺取消事务。字号/行距范围和背景枚举不变，控件补44pt最小高度、名称/值/hint，背景改为菜单避免横向分段挤压。正文排版字号与系统Dynamic Type没有被合并或自动更改。

## 目录定位与所有权

新增ReadingDirectory及OpenedReader扩展，不修改原OpenedReader/Source/PackReader实现。先验证book/version及源的精确raw边界，再通过既有chapterPage进行上界二分：每次仅取1项，找到章后只取所在页最多32项。手动分页仍≤32，无全目录数组、全书String、解码、全源hash或新session。查询沿用当前单代租约、块校验与raw/UTF16坐标；不保存位置或设置，不改变派生格式。

边界合同：

- 章节起点归新章，EOF归最后一个非空范围。BOM内部、其他书/版本、负数或越界锚点拒绝；0章返回明确空页，不显示1–0。
- 正常TXTChapters.split逐行识别非空标题，章节起点严格推进，最后到正文尾；基线已有“连续/末尾标题无空幽灵章节”回归。新查询对意外的零长度、缺项、错版本元数据明确拒绝并保留旧页，不向前后遍历全目录补洞，不用假的开头替换位置。
- ReaderDirectoryViewModel独立拥有目录请求与展示值。排队前生成请求ID并捕获reader/ownerRevision/displayRevision，执行前及每次异步返回后检查；新分页、关闭、换owner和取消撤销旧意图。每次目录弹层另有独立ID，延后的旧onDisappear、选章及scroll/focus回调先核对当前弹层，不关闭或改变新弹层/导航。重复在途同请求、已加载同页不重复读取。失败保留上一有效页，提供重试和关闭。
- 初次打开和明确“回到当前章节”生成一次reveal，使用稳定章节ID通过ScrollViewReader滚动到行。新请求或关闭会撤销reveal，延后scroll/focus执行前再核对ID和取消状态。VoiceOver焦点仅随这两个显式意图设置，不随正文滚动或自动重排反复夺焦。
- 当前目录锚点来自已应用的viewport语义位置，pending导航目标不会预先成为当前章。ReaderViewModel只在原windowApplied门控通过后通知目录。自动显示位置变化不抢手动分页；位置已变化的旧查询结果可显示页，但不得恢复旧高亮或触发旧焦点。
- 挂起取消目录首查后，恢复时即使语义锚点相同，也仅在目录仍展开、未手动分页、尚无页面且没有在途请求时恢复初次定位。已有页面或手动分页不重复查询、滚动或夺焦；纯值回归覆盖取消保留弹层所有权及相同请求重新取得新ID，SwiftUI实际挂起/恢复仍待真机核对。

## 文件边界

现有App文件：ContentView、LibraryViewModel、ReaderViewModel、ReaderScreen、ReaderSettingsView。

新增App文件：ReaderDiagnosticsView、ReaderDirectoryViewModel、ReaderDirectorySheet。

新增Domain文件：LibraryPresentation（展示值）、ReadingDirectory（有界只读查询及目录展示请求合同）。

新增回归：LibraryPresentationTests、ReadingDirectoryPresentationTests；本说明为唯一新增项目文档。共13个源码/测试/文档文件。

TXTCore、LibraryService、LibraryStore/Schema、派生格式/导出/读页内核、Picker [.item]/asCopy:true、安全域/协调复制、严格编码、完整源SHA、位置与设置事务、原98测试文件、构建/依赖/CI配置保持。刚升级的脚本及其工具测试/说明/记录、真实历史/看板和Skills保持。无新翻页、EPUB、AI、漫画、账户或书源。

## 回归与交接门

新增13项声明：展示4项，目录9项。实际使用生产展示值/请求门，以及OpenedReader新查询：真实合成包/BOM/97章分页与EOF、百万项虚拟目录的有界探测、0/1/31/32/33/64/65边界、缺项/错版本/零长度拒绝、探测后取消、排队旧定位不能覆盖新分页/owner、重复请求、失败保留页、reveal撤销及过期显示高亮、错误锚点与关闭句柄。所有mutating状态调用均先求值，再进入Swift Testing断言宏。

上述仅为测试声明，当前原生执行0。没有新增UI测试host或截图框架；纯值请求门和API回归不能替代SwiftUI任务调度、ScrollViewReader实际滚动、VoiceOver焦点和真机视觉验收。

本地静检/文件哈希/差异证据仅存ignored artifacts/daily-ui-local-20261028。词法分隔符检查不是Swift语法解析或类型检查，不能证明Swift6隔离和ViewBuilder编译成功。

收尾文本/保护审计共24项通过，完整13文件行数、增删行与SHA记录在该目录的closure证据中。起始158文件快照仅5个授权App文件变化，其余153个保持原字节；其中原有21个测试文件、28个既有Sources文件、8个构建/验证配置、Picker桥接、3个用户本地文件、48个Skills文件与lock、11个工具产物和15个私有评审记录均保持。新增13项测试声明使后续唯一测试总数为111，不等于已执行；HEAD保持基线且无暂存、提交、推送、云调用或新IPA。

后续如另获发布与一次完整验证授权，最小配置调整为原Task3保持25 Core Debug +79 Domain Debug +6 Block Release +1原串行测量Release =111项唯一测试，逐项无跳过，再验证真实设备App编译。当前workflow/helper仍为98，未修改或触发；产包/交付须在后续明确授权范围内执行。

原生成功后仍需iPhone13/iOS16.6.1核对：清爽书架与手动关闭结果、导入停止的前后两种权威结果、目录末组当前章实际可见/分页不拉回/快速关闭重开/首查挂起恢复、设置即时重排和保存失败返回，以及长标题、大字、深色、VoiceOver焦点。真实进程重启/长读验收仍单独记录；本批不重新测性能，不据本地源码宣称视觉、无障碍、首绘或RSS已通过。
