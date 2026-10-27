# Task 3：TXT 阅读闭环与导入诊断

## 当前：源码会诊与复制导入批次（2026-10-28）

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
