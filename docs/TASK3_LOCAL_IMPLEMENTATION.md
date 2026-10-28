# Task 3：TXT 阅读闭环与导入诊断

## 当前批次：派生阅读第二批接入，单次验证冻结说明（2026-10-28）

本批基线 `3de2758` 的第一批派生存储历史 78 项原生测试及设备 App/IPA 校验通过。本批新增 20 项接入测试声明，冻结时 Swift 编译/原生执行/App 构建/真机验证均为 0。用户现已另行批准白名单普通提交/push、一次现有 Task3 workflow_dispatch attempt1，配置同步为 25+66+6+1=98 项唯一测试；全部实际通过及设备 App/同 SHA IPA 校验成功才交付，任一步失败立即停止，不自动修补重推或重跑。

具体文件职责、缓存预算与出口、任务/会话/关闭/租约、原件与进度保护、分页目录、计时口径及剩余真机门见 [第二批接入说明](DERIVED_READING_INTEGRATION.md)。结果仅存 ignored artifacts，不再提交结果，不外部会诊/安装；唯一运行到终态即停止。下面保留此前批次说明，不自动继承历史发布许可。

## 历史：严格分块解码候选（2026-10-28）

本轮仅批准一次隔离源码会诊和本地实现/回归准备/静检。公开提交、push、GitHub写入、Actions及IPA构建暂停；不沿用历史云端授权。所有改动未提交，未运行Swift/Foundation或云端对照，不能称等价/性能已通过。

**会诊与采用范围。** 仅外发指定问题和TXTDecoder/TXTTypes真实内容，未附带看板、idea历史或其他源码；原脚本/配置/记录保持。采用有界批次和异常块定位方向，未照搬全文件替换、CFStringNoCopy、改变原单标量转换器或“100%等价”的说法。闭源Foundation在目标系统上的实际行为仍必须原生差分验证，不能用Python codec或模拟计时替代。

**批量候选。** 共享的字节语法检查仍区分GBK和GB18030：ASCII NUL拒绝；GBK不接收GB18030四字节；双/四字节范围不变，编码ID保持CP936与0x0632。原始块目标min(max(chunkSize,4),65536)，停在完整token边界，极小chunk仍可容纳一个四字节token。原始NUL在前置语法检查时拒绝；快路径只在内部给每个token插入NUL分隔符，它不是正文。

Foundation依然使用原String(data:encoding:)/data(using:allowLossyConversion:false)接口。先确认每个分隔段恰好一个Unicode标量及一个NUL，再严格回验整个带分隔符的缓冲。由于原token不含NUL，内部标记明确区分单元，避免仅凭标量总数一致推断逐单元对应；剥离标记后按原token宽度送入原Normalizer。任何检查失败都清空临时标量，使用保留的旧Foundation单标量检查处理该块前缀，正常生产不跑两套全书解码。

若预扫在较晚位置发现结构错误/截断，先暂存；前面的完整token先完成映射与无损回验。失败时旧路径从前缀首token按序定位，才能保留更早的非规范/映射错误及绝对byteOffset。所有快路径验证通过之前不提交Normalizer状态，避免部分消费后降级重复追加。最后才报告暂存结构错误。GBK/GB18030是无状态字节编码，但平台实现的分块行为、内部NUL支持与所有映射的实际等价不能由本地静检证明，必须通过旧新原生差分；未满足时不交付该候选。

**内存与未拆分路径。** 原始输入每块最多64KiB；内部标记Data最多128KiB，回验Data同量级；宽度数组最多64Ki个UInt8，标量数组最多64Ki个Unicode.Scalar（约256KiB），通过快路径的文本逻辑存储另计。正常逻辑缓冲总量约数百KiB至1MiB量级，Swift/Foundation容量、桥接与分配器额外开销未测，不能说临时内存只64KiB。正文及精确索引仍是原有全书结果，不新建整书UTF8数组。UTF8/UTF16保留原inline消费，不为拆计时增加中间标量数组。

**聚合计时。** TXTProcessor仅在提供observer时记录内核总时长；GB按块累计扫描/转换与Normalizer/索引时间，UTF直接扫描与构建合并标“未拆分”；另记内核原始SHA、正文版本SHA、实际编码枚举、调用量及块上界。只在一次decode结束时发聚合值，不逐标量读时钟/发事件。LibraryService wrapper原计时保留，差值还包含actor等待、返回调度和观测开销，不是纯队列时间；内部项不能再加进外层总时长。不会记录原书hash、内容或路径；window应用仍非首绘。

**回归准备与缺口。** 测试专用LegacyTXTDecoderReference从a84811a原文冻结，仅改类型名/导入，不用于生产。新增6项内核回归对比输出UTF8字节、encoding/compatible encodings、原字节、BOM、所有坐标边界、document/version ID和首个TXTError；覆盖GB双/四字节、emoji/组合字符、CRLF/孤立CR、UTF8/UTF16/BOM、chunkSize=1/2/3与Int.max、非法截断、保留映射范围及较早映射错误优先。平台相关非规范别名只比较真实旧决定，不假定特定系统必须存在某个别名；若原生样本没有触发回验拒绝，还需补该系统实际案例，不能宣称覆盖充分。

调用量测试用8192个合成“中”字：旧源码应每字转换，新实现要求批次调用显著少、无标量降级，且输出/所有边界/版本相等；这只是待跑断言，并非本轮已测数据。打印的旧reference同步耗时、新wrapper耗时与新内核时间口径不同，只有将来同平台Release/-O、同字节/同编码、明确预热顺序后才可分析，不能直接算提速倍率。另1项摘要回归核对实际UTF8标签、Unicode未拆分和不重复相加提示。

原51项不改，当前声明31+26+1=58项。Windows无swiftc，没有Swift编译、原生Foundation差分、非规范映射覆盖或实际性能结果；本轮不触发云测试。最小后续门为：正确接入58项计数，在固定工具链先完成原生功能差分，再单独Release串行对照实际编码的合成数据及调用量/内存；最后同iPhone13/iOS16.6.1、同书核对实际编码、首次内部阶段、复开、目录和保存锚点。实际用户书编码仍未知，不能预先承诺GB优化能解释或解决10.241s。

若后续明确批准同一次CI，最小选择方案为：Debug TXTCore选30项（仅排除新增的canonicalBlocksReduceConverterCallsWithoutChangingAnyCoordinateOrVersion），Debug ReaderDomain选26项并继续排除原串行测量suite；原Release复用测量1项保持，再单独Release仅选上述内核对照1项。合计30+26+1+1=58个唯一用例，各执行一次。计数helper须显式核对完整声明31项与所选/排除名单，不能把排除当跳过断言；所有Release对照核实实际-O/ENABLE_TESTABILITY=YES、串行且无其他suite并跑。此处只是待批准配置建议，本轮未修改工作流或执行它。

## 历史：有界处理结果复用（2026-10-28）

用户已确认 d63041b 真机功能正常，粗估导入二十多秒、同进程复开十几秒。源码确认导入的解码结果提交后未保留；每次打开重新解码、建索引和全书分章后才排局部窗口。本批已获批准开发及一次完整验证，但此提交冻结时尚无本批原生结果。

**所有权与预算。** LibraryService actor 持有一个 ProcessedBookCache，仅含不可变 TXTDocument 和可选目录；无 reading session、位置或设置快照。64MiB 是估算阈值，按原字节2倍、UTF16长度4倍、实际索引数组容量2倍及固定开销，再计目录数组容量和标题/ID/版本字符串估算。TXTTypes 仅添加只读估算属性，不调用会物化全边界数组的兼容 getter，不改解码/坐标算法。超限回原正确路径；估算不是实际分配或进程 RSS 上限，活动阅读器/临时解码/系统分配器另计。

**发布和失效。** 导入非重复提交成功后保留已验证文档，首开生成目录后保留完整条目；未提交、失败/取消及重复导入不发布新结果。每次 openBook 仍从私有文件创建 Data 并计算真实 SHA，比对内容 ID 后按书籍 ID/版本/编码命中，绝不凭 size/mtime。缺文件/读取失败/内容变化/版本或编码不符、换书、导入/修复、取消和内存警告清除条目并更新代号；跨 await 捕获的旧代号不能回填或清除新条目。内存警告不改变阅读业务，不能保证释放仍被活动 engine 引用的文档。

每次仍由原 store.beginReading 创建新 session、读最新位置，由 ReaderViewModel 读最新设置并重建局部窗口；退出的进度屏障及取消提交唯一结果不改。Picker [.item]/asCopy=true、安全域/协调复制、原文件只读、严格编码/精确 byte↔UTF16 和数据库架构保持。TXTProcessor 仍负责原处理算法，计数在生产调用点递增，命中时确实不调用解码/分章。

**回归与计时。** 原44项文件/断言保持，新6项覆盖导入/复开复用、新 session/最新位置、同大小改字节、缺文件与错误版本/编码、取消/未提交结果、内存释放、超预算、换书/重复修复和过期发布代号。另1项测试在现有 ReaderDomainTests bundle 内、单独 Release/-O 串行执行（ENABLE_TESTABILITY=YES），10MiB chinese-chapters-v1 合成数据生成/写入不计时，顺序测真实 import→first open/window ready→同 service reopen/window ready→new service cold cache/window ready；不是新基准体系，也不修改旧 TXTCore 性能测试。

记录私有复制（含元数据/协调等待）、Data创建、服务层完整 SHA、decode（含内核自有内容/版本 hash）、chapters 和 window layout。Data 映射触页成本可能落在后续 hash/decode；不能当作物理磁盘 I/O 独立计时。每段及总耗时来自生产调用，计数证明复用；内存仅测试宿主进程边界 RSS，含 fixture/分配器保留，不是采样峰值或缓存增量。新 service 与原 service 同进程/同 store，不能称为 App 重启或冷启动。

App 书架显示选中回调→完成书架刷新（含可能的编码选择等待）及有限阶段摘要，阅读页“处理耗时”显示打开→UIKit应用首个窗口。摘要每次完成后更新，不逐帧刷新；没有首绘测量，不把 window ready/applied 当作屏幕已显示。系统 asCopy 在 delegate 前的云端下载/选择阶段、真机阶段耗时和 App 真冷启动均未测。不持久记录书名/URL/路径/正文/用户书hash，不上传遥测。

本批只一次现有 Task3 run attempt1，期望25 TXTCore+25 ReaderDomain+1串行测量=51项真实通过，随后实际 iPhoneOS arm64 App 编译、资源/依赖/unsigned/iOS16.6 IPA 门验证。失败即停，不自动重推/重跑；结果仅保存在 ignored artifacts。成功后仍需同 iPhone13/iOS16.6.1、同9.5MB TXT 的导入/初开/同进程复开分段对照，内存压力/文件变更/设置与位置也须验收，不能据模拟器承诺秒开。

## 历史：源码会诊与复制导入批次（2026-10-28）

基线 `8f5d5db` / run `40533187004` 已有 25+19=44 项原生测试与真实 App/IPA 验证，真机导入仍未通过。本批先完成本地脚本双模式融合及离线边界验证，再仅向现有兼容接口发送指定问题、DocumentPickerBridge 和 LibraryService 的真实源码，获得一次实际会诊响应。未发送看板或 idea 历史；脚本、配置、记录与脱敏评审证据均不在公开提交范围。

独立审查确认 session 强持有唯一 Coordinator，ViewModel 保留 session，原 route 对退出先后、旧/重复/冲突回调和一次消费已有回归。LibraryService 先作 URL/txt 准入，在源元数据与协调复制期间持有安全域，仅成功申请才释放；false 不直接报失败。Gemini 对协调前元数据检查的云端风险推断并非已证实根因，也不能证明选择器未回调的原因。本批不移除源非符链检查、不删除已有目标、不改变 delegate 或后续生产链路。

唯一生产修改为 `UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)`。系统先交付导入副本，应用仍经原服务取得自己的持久副本；选后只接受 file URL、txt 扩展名、普通非符链文件并严格解码。此语义依据 Apple 的 [初始化接口](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller/init(foropeningcontenttypes:ascopy:)) 和 [文档导入说明](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/DocumentPickerProgrammingGuide/AccessingDocuments/AccessingDocuments.html)。复制模式不保证云端物化成功，不新增下载、账号权限或 plist 声明。

本批不新增重复的纯路由测试，原44项声明与断言完整保留，包含本地 TXT 导入、非TXT/非file拒绝、目录/符链、编码/取消/持久化与路由先后。它们不覆盖 UIKit/FileProvider 真机行为。保留固定工具链及 workflow，仅一次 dispatch attempt1，44项全部真实通过、实际 iPhoneOS App 编译与现有 IPA 门通过后才交付。失败即停，不自动修复或重跑；此提交冻结时尚未验证，本地静检不代表编译/出包/真机验收。

## 历史：类型过滤单因素批次

基线d0d44cd / run40524966144已有43项及真实App/IPA验证。真机同TXT在iCloud与本地均无法选中，根因未知。本批只将DocumentPickerBridge构造器的plainText改为data；asCopy=false、单选、所有plist/entitlements、delegate持有、Session/Route、呈现和后续生产链路均不改，不迁移或重读旧项目。

现有LibraryService先检查fileURL及txt扩展名，再申请安全域/检查普通文件与符链/协调复制，随后只对应用副本严格解码。本批保留这些边界。原43项覆盖空/损坏、目录和符链，但没有非TXT选后拒绝的直接回归，因此仅新增1项合成测试，确认缺失bin及非file的txt URL均精确抛notTXT、没有源访问阶段、没有书架或暂存/Books文件。原断言保持，总计25+19=44项，最小同步现有手动workflow/helper。

一次验证全部测试、真实App编译与IPA门通过才交付；任一步失败停，不修补重推/重跑，不同批改变copy/open模式或plist。此提交冻结时本批尚未原生验证；纯合成准入测试不代表真实FileProvider或iCloud选择成功。用户三个本地文件与Skills不改不发布，诊断不新增私有字段或遥测。

真机仅安装新包后，在同手机同路径选同一9.5MB TXT；收到delegate选中才支持过滤因素，仍失败则关闭回书架反馈delegate/最后阶段，不提供书籍。此包用于单因素验证，不提前宣布修复。

## 历史：文件选择入口桥接批次

基线cb1ce89 / run40518279736已通过38项及诊断IPA；用户仍在真机点TXT无反应，截图只记录等待与关闭。旧ContentView的可选attempt捕获可跳过记录，故不能确定OS未回调或指认权限根因。本批只修入口与诊断交接。

- `DocumentPickerBridge.swift` 使用官方 [init(forOpeningContentTypes:asCopy:)](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller/init(foropeningcontenttypes:ascopy:))，plainText单选、asCopy=false；保持“取得外部安全作用域URL→原LibraryService协调复制到私有目录”的语义，不改成由picker预先提供另一份复制品。官方 [UIDocumentPickerDelegate](https://developer.apple.com/documentation/uikit/uidocumentpickerdelegate) 区分选中与取消。本批不假定delegate与dismiss只有一种先后顺序。
- `FileSelectionSession` 是单轮呈现和短暂pending URL的owner，ID不可变且非可选；它强持有coordinator，coordinator回调只弱持有LibraryViewModel，不形成循环。纯关闭后session仍保留，可接收晚到delegate；下一轮更换session，旧ID被拒绝。交接后立即清空pending URL，不持久化外部URL。
- 每轮独立host使用同一session绑定sheet，按官方 [sheet onDismiss](https://developer.apple.com/documentation/swiftui/view/sheet(ispresented:ondismiss:content:)) 确认退出。onDisappear不推断成功/取消。仅结果与退出均到达才消费一次，因而两种顺序都可接续；代理先留下固定诊断，编码sheet/结果alert在确认退出后请求，其他书架alert也在picker期间门控。
- `ImportPickerRoute` 只存ID、固定结果、退出及消费事实，不含URL/正文。新5项回归覆盖成功先于/晚于dismiss、空结果、取消两种顺序、纯关闭、旧/重复/冲突回调及一次消费。所有mutating调用均先执行到局部变量再断言。原38项文件保持，总计25+18=43项，精确同步原手动流程与helper。
- LibraryService、安全作用域、NSFileCoordinator复制、GRDB、编码和排版代码均不改。诊断只用固定词汇，不记录书名、完整/片段路径、URL、正文或私有错误详情；不上传遥测，不新增权限/entitlement。
- 一次手动完整验证，全部43项、真实设备App编译与IPA校验全过才交付；失败停，不追加修复/推送/重跑。现有用户看板/脚本/配置不改不发布。此提交冻结时本批仍待原生验证，路由单元测试不模拟真实UIKit/FileProvider/iCloud设备行为。

下一次真机仅重新点选TXT；如仍停选择器，关闭回书架查看“收到delegate选中/取消”与最后阶段；无需提供书籍。没有实际设备反馈前不宣布症状已修复。

## 历史：导入诊断批次

首批提交 `b8fa29ff8fd80c3eb82c9bd24f715a43ff529d44` / run `40505713251` 已通过33项原生测试、设备目标编译及未签名IPA验证；它不等于iPhone阅读/系统选择器/iCloud验收。真机反馈点击iCloud TXT无反应，根因未定。本批只提供下一次试用所需的可见诊断，不先更改过滤类型、读取策略或业务算法。

- 改动入口为 `App/ContentView.swift`、`App/Library/LibraryViewModel.swift`；`Sources/ReaderDomain/ImportDiagnostics.swift` 只承载有限固定阶段、安全错误与本轮状态。`LibraryService.swift` 仅在原步骤前后发送观察事件，未向协调读取内部增加await、下载或取消操作。
- 书架保留选中回调是否到达、最后阶段、错误前阶段和最多64条固定事件。成功选中、空成功结果、明确失败/取消错误、关闭却未收到回调分开；isPresented=false本身不代表取消。晚到成功可更新已关闭状态，晚到关闭不覆盖已开始读取的阶段；旧轮ID不能覆盖新轮。
- 观察通过每操作一个最多32条缓冲的AsyncStream单消费者顺序到达；结果/错误/编码sheet发布前排空。`makeStream`为可回部署的标准库API，不增加iOS17最低要求。业务取消仍按原权威裁决，诊断不承诺中断同步协调。
- 诊断字段没有书名、URL/路径、正文、原始错误description/userInfo或任意域。安全错误仅保留固定类别、白名单域和数值code；未知域显示Other。导入入口及书架错误提示不再拼接localizedDescription。没有控制台记录或网络遥测。
- 原25项TXTCore和8项ReaderDomain回归文件原样保留；新增5项覆盖两种picker关闭/成功顺序、旧轮事件与空结果、安全错误/明确取消区分、真实合成本地导入的阶段顺序及原字节不变。它们不模拟真实iCloud/FileProvider或证明系统picker正常。
- 仅最小同步现有手动工作流与helper的ReaderDomain实际期望为13，总计38。原工具链、依赖、设备编译与打包校验保持；本批一次attempt1，任一步失败停，不修复重推/重跑。结果只存ignored artifacts与云artifact。

下一次真机操作只需：打开导入→点选文件→若仍停在选择器，关闭回书架→查看“有无选中文件回调”和“最后阶段/阶段记录”。无需提供书籍或改名；不操作原书/应用目录。此提交冻结时本批待原生验证，真机问题没有被宣布修复。

## 历史：首批实现与首次云验证前说明（以下保留当时状态）

本批基线 `0886cfe9ff7e0955183ca56a16500be808853690`。Task 3 本地实现的25个文件已保存并核对哈希。用户随后明确批准必要云配置、提交推送至既有公开仓库及一次手动完整验证；原25+新增8项真实测试和实际 App 编译全通过后才打同提交未签名 IPA。此前目录只读检查不限制本批；任何失败停止，不自动修复/重跑。本批不改已完成业务源码或断言，旧 TXTCore、25项回归、性能样本/脚本/工作流保持原样。此前模拟器成绩不代表本批阅读 UI、GRDB 或真机成绩。

## 文件与层次

- `App/ContentView.swift`、`App/Library/`：SwiftUI 书架、文件选择、同段编码确认；细粒度 MainActor ObservableObject/Published，不使用 Observation。
- `Sources/ReaderDomain/LibraryStore.swift`、`LibrarySchema.swift`：GRDB 迁移、书籍/实际编码/版本、原始字节锚点和设置；同步事务只在独立存储 actor 内执行。
- `LibraryService.swift`：只读安全作用域与协调复制、严格解码/歧义预览、去重和打开。通过既有 TXTProcessor actor 工作，不改内核接口。
- `ReadingLayoutEngine.swift`、`ReadingWindow.swift`：后台 actor 仅为当前锚点生成最多 7 段，目标每段 512 个 UTF-16 单元，使用最多 1024 单元的有界 look-ahead，以真实完整排版行结尾（实际段长不超过1024），不把缓冲末尾强制当作换行，也不在切片间新增间距/缩进；边界对齐字素。CoreText 负责断行/几何，跨 actor 只返回 String、数值与类型化范围，不返回 CF 对象。
- `App/Reading/`：可复用 UITableView 单元绘制有限预断行文字；目录、上下滚动、字号/行距/背景。UI 线程仅绘制有限行，没有整书/整章 SwiftUI Text，也不预建全部视图。
- `Tests/ReaderDomainTests/LibraryWorkflowTests.swift`：8 项非 UI 回归声明，独立 ReaderDomain scheme/target；原 TXTCore scheme 不塞入应用测试。

## 固定依赖与兼容性

仅官方 SPM `https://github.com/groue/GRDB.swift.git`，`exactVersion: 7.0.0`，未在 Windows 解析依赖。该版本官方 Package.swift 声明 Swift tools 6.0、语言 v6、最低 iOS13，符合当前 Xcode16.4 / Swift6.1.2、语言6.0、最低iOS16.6声明约束；这不是编译实测。官方未修改 MIT 正文在 `App/Resources/GRDB-LICENSE.txt`，明确加入资源构建阶段，设置页可查看。未给自有项目新增许可证。

## 导入与提交约定

文件选择后只协调读取并复制到 Application Support/YueJing/Imports；安全作用域覆盖输入、协调 URL 和复制后副本的普通文件检查，目录/符号链接明确拒绝，不把外部链接当永久副本。在复制完成/失败时立即释放安全作用域，不持久化外部 URL。解码只读应用副本。自动识别明确时直接处理；歧义时完整验证候选，定位首个差异附近的共同原始字节区间，同段展示可读预览和取消，确认后记录实际编码与文档版本。

文件以原始 SHA-256 命名存入 Books，SQLite 存书架。提交与取消在存储 actor 串行裁决；取消先赢不提交，SQLite 提交先赢则 UI 显示已完成，不谎报取消。文件先移入、数据库事务失败则移除本次文件；意外进程退出产生的可识别孤立副本在下次数据库成功打开后清理。系统文件与原文件不删改。空/损坏/不支持输入不生成书架行，取消清理临时副本。

重复原字节只返回既有书籍，保留既有编码/版本/进度。若应用副本缺失，同一原文件重导入会补回副本。已存在但损坏的副本只检测/阻止读取并保留记录，不承诺当前已实现覆盖修复、书籍删除或文件管理界面。

## 位置、竞态与保存

锚点为书籍 ID + 文档版本 + `raw-byte-v1` 原始 byte offset + 行内可见比例，不保存页码/百分比。打开先显式按已确认编码解码并核对原始 ID/版本；恢复还需通过 TXTCore 精确边界检查。旧版本/单位不匹配的位置不会应用或立即用零位置覆盖。

滚动位置来自当前 viewport 与实际行的交集，不来自 willDisplay/预取/下一章。频繁滚动只改阅读 VM 私有值，700ms 合并保存；设置350ms合并。返回及场景 inactive/background 尽量及时 flush，不承诺系统强杀前未落盘的最后瞬间。重复字号/宽度重排保留语义原始锚点，未再次手动滚动时不改写为新换行的更早行首。

存储检查会话 UUID、版本和单调序号，旧回调不能覆盖新序号或新会话。关闭先在 actor 内撤销旧会话后续写权限，即使最终锚点非法或数据库失败也不恢复权限；最终保存错误会显示，允许重试或明确保留已保存位置退出，不假装保存成功。旧 close 不关闭新会话。

后台窗口结果同时核对请求 generation、可见位置 revision 和当前交互状态；滚动/目录等新意图使旧结果失效，交互结束按最新锚点重请求。界面真正移除时关闭会话，正常设置/目录 sheet 不触发关闭。

## 边界与验证

本地只能做范围/保护哈希/语法文本与小型 SQL 约定核验；没有 Swift/Xcode 原生编译、8 项业务测试执行或界面验收。正文暂不支持选字/全文搜索/左右翻页；极长单个字素无法装入有界段时明确报错，不拆坏字符。保留整本文本/精确索引和一个后台 NSString 视图，不宣称 UI 已具备常量内存或继承内核性能成绩。

本批新增 `.github/workflows/task3-validate.yml` 与 `scripts/validate_task3.py`，复用既有 `scripts/package_ipa.py`，不改旧工作流或打包脚本。单次 attempt1 顺序：核对固定工具链和生成工程→解析官方 GRDB7.0.0 并记录实际 revision→发现已安装 arm64 iPhone 模拟器→原25项和新增8项分别运行且逐项核对实际通过记录/总数/未跳过→编译真实 Release iPhoneOS arm64 App→检查动态框架及 rpath 可达性、GRDB实际资源/许可与未签名状态→同提交 IPA 并逐文件比较打包字节。任何一步失败均不继续打包或重跑。原始日志、原始退出码、xcresult 和依赖记录以独立证据 artifact 保留；成功 IPA 单独 artifact，均保留3天。结果仅保存 ignored artifacts 与云端，不追加结果提交。

随后用户沿既有签名安装流程在 iPhone13/iOS16.6.1 进行普通导入、滚动、目录、设置和重开验收。来源移除/撤销访问后的稳定副本验证只使用自造可丢弃测试TXT或临时副本，绝不删改个人原书。缺失应用副本、SQLite写入失败等故障由合成非UI测试或另行授权的受控验证覆盖，不要求用户操作应用目录或系统文件。只有设备实际结果能作为阅读闭环验收。

## 本批完整文件清单

- `.github/workflows/task3-validate.yml`
- `scripts/validate_task3.py`
- `AGENTS.md`
- `App/ContentView.swift`
- `App/Library/EncodingChoiceView.swift`
- `App/Library/LibraryViewModel.swift`
- `App/Reading/ReaderScreen.swift`
- `App/Reading/ReaderSettingsView.swift`
- `App/Reading/ReaderViewController.swift`
- `App/Reading/ReaderViewModel.swift`
- `App/Reading/ReaderViewport.swift`
- `App/Reading/ReadingCell.swift`
- `App/Resources/GRDB-LICENSE.txt`
- `README.md`
- `Sources/ReaderDomain/ImportModels.swift`
- `Sources/ReaderDomain/LibraryBook.swift`
- `Sources/ReaderDomain/LibraryError.swift`
- `Sources/ReaderDomain/LibrarySchema.swift`
- `Sources/ReaderDomain/LibraryService.swift`
- `Sources/ReaderDomain/LibraryStore.swift`
- `Sources/ReaderDomain/ReaderPreferences.swift`
- `Sources/ReaderDomain/ReadingLayoutEngine.swift`
- `Sources/ReaderDomain/ReadingPosition.swift`
- `Sources/ReaderDomain/ReadingWindow.swift`
- `Tests/ReaderDomainTests/LibraryWorkflowTests.swift`
- `docs/TASK3_LOCAL_IMPLEMENTATION.md`
- `project.yml`
