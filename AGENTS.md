# YueJing：当前源码会诊与复制导入批次（2026-10-28）

- 用户新增批准在本地融合 ask_architect.py 的 idea/review 两模式，保留原配置与 idea 记录；review 仅发送指定问题和两份明确 Swift 源码，不自动附带看板或历史。先离线验证，再一次真实会诊。脚本、记录、看板、Skills 和私有评审证据均不公开提交。
- 基线 8f5d5db 已有 25+19=44 项原生测试、App 编译与 IPA 通过，真机仍未通过。会诊完成后，唯一生产改动为 DocumentPickerBridge 使用 [.item]、asCopy=true，保持单选及现有 session/Coordinator 强持有、一次路由和退出交接；后续 fileURL/txt/普通文件非符链准入、安全域配对、协调私有复制、严格解码、GRDB 和排版保持。
- Gemini 建议属于待审资料，不直接执行。未提供真机/系统回调证据，不能宣布根因或真机修复；复制模式也可能在云端物化时失败。保留安全诊断，不盲改 plist、不扩大权限或读取旧项目。
- 保留原44项断言与工具链；普通提交/push，仅一次现有 task3-validate workflow_dispatch、attempt1，全部44项及真实设备目标编译、资源/依赖/arm64/iOS16.6/未签名 IPA 校验通过才交付同提交 IPA。任一步失败即停，不自动补丁重推或重跑；结果仅存 ignored artifacts。成功后停止等待真机，不关机。

## 历史：类型过滤单因素批次（2026-10-27）

- 用户已批准本批单因素过滤、必要准入回归/计数与说明、公开push和一次完整验证IPA。唯一根为本仓库，基线d0d44cd已有43项及桥接IPA通过；真机导入根因仍未证实，本批不再读取或迁移旧项目。
- 唯一生产改动为DocumentPickerBridge构造器plainText改data；asCopy=false、单选、plist/entitlements、delegate/session/route/呈现和后续LibraryService安全域/协调复制/解码/GRDB/排版完全不动。选后仍须fileURL与txt扩展名、普通文件/非符链、严格解码，不扩大到任意文件业务。
- 原43项测试保持，新增1项选后准入回归覆盖非TXT和非file URL在源访问前拒绝且不入架；总计25+19=44项。固定工具链与依赖保持，唯一workflow_dispatch attempt1；任一步失败停止，不修补重推/重跑，不擅自追加asCopy/plist实验，结果仅存ignored artifacts。
- 同一iPhone13/iOS16.6.1、同9.5MB TXT、同路径收到delegate选中才支持过滤因素；单元测试/编译/出包均不代表已复现或修好真机。固定无隐私诊断保留，不上传遥测。三个用户本地文件与Skills保持，不执行脚本、不安装/扩权/新增费用、不force、不触发旧CI、不关机。

## 历史：文件选择入口桥接批次

- 用户已批准本批显式UIDocumentPicker入口、必要路由回归/计数与范围文档、普通push及一次完整验证打包。唯一根为本仓库，不新建任务/替代目录。基线cb1ce89已有38项与诊断IPA通过，真机仍反馈点TXT无反应；旧可选attempt捕获有丢记录路径，不能据无记录推断系统没回调或iCloud无权限。
- 仅替换文件选择入口：稳定非空不可变UUID、UIDocumentPickerDelegate选中/空结果/取消、明确owner确认dismiss后交接；关闭与delegate先后均处理，旧/重复回调不能覆盖或重复导入。不用onDisappear推断结果。
- 固定plainText单选，asCopy=false打开外部安全作用域URL，仍交LibraryService原有安全域/协调复制链落到私有目录，不增加下载/账号权限/entitlement，不改编码、GRDB、排版或取消策略。不记录书名/URL/路径/正文/私有错误，不上传遥测。
- 原38项测试文件保持；新增5项纯入口路由回归，总计25+18=43项。纯路由测试不是UIKit/iCloud实际复现。原工具链、设备构建及打包门保持，唯一workflow_dispatch attempt1；任一步失败即停，不修补重推/重跑，日志产物仅存ignored artifacts。本包成功也只用于验证入口，不能宣布真机导入已修好。
- 保留用户未跟踪PROJECT_STATE.md、ask_architect.py、.architect_memory.json，本批不改、不执行、不发布；不改Skills、不新工具/凭据/权限/费用、不force、不触发旧Task1/性能工作流、不访问其他项目/私人书籍/回收内容、不关机。

## 历史：导入诊断批次（以下保留当时规则）

- 当前唯一工作根仍是本仓库。用户已批准最小导入诊断开发、必要测试/文档/计数配置、向既有公开仓库普通提交推送和一次完整验证打包；此前独立只读诊断已结束，不是本批限制。不新建任务/替代目录，不访问用户小说、其他项目、旧工程或系统/凭据。
- 基线 `b8fa29ff8fd80c3eb82c9bd24f715a43ff529d44` 的原33项测试、设备目标编译与IPA校验已通过；iPhone13/iOS16.6.1反馈选择iCloud TXT无反应，根因未定、未复现。新增可见阶段不是已修复声明。
- 本批只观测原导入链：书架保留本轮选择回调事实与有限阶段记录；选择器关闭且无回调不能推断取消。两种关闭/成功顺序和旧轮事件均须覆盖。只使用固定阶段、允许的错误类别/域与数值code，不存书名、URL/路径、正文、localizedDescription/userInfo，不上传遥测。
- 不改 `.plainText` 白名单、编码/数据库/排版、iCloud读取策略或取消机制。后台观察不新增同步等待UI或业务await；按本轮ID过滤并按序消费阶段，结果/弹层请求前排空观察事件。保留全部原33项断言与性能口径。
- 工具版本及部署目标保持：macos-15、Xcode16.4/16F6、Swift6.1.2（语言6.0）、XcodeGen2.46.0、iOS16.6、官方GRDB7.0.0。复用 `task3-validate.yml`，本批25+13=38项逐项真实通过，再实际设备App编译及依赖/资源/unsigned校验，全部成功才交付同提交IPA。仅一次workflow_dispatch attempt1；任一步失败停，不自动修复、额外推送或重跑。结果仅存ignored artifacts及云artifact，不为结果再推送，不进入下一批，不关机。
- Skills/lock、artifacts、用户文件、内部会话与私人路径不得发布；旧Task1/内核/性能工作流不触发。不安装工具，不新增秘密/权限/付费规格、不force。

## 历史 Task 3 单次云验证规则（以下保留当时原文）

- 当前工作根为本仓库根目录。本批用户已批准 TXT 导入/书架/目录/上下滚动阅读/字号行距背景、GRDB 位置持久化及必要业务回归的本地开发；详见 [Task 3 本地实现](docs/TASK3_LOCAL_IMPLEMENTATION.md)。
- 用户已另行明确批准：补必要云验证配置，提交并普通推送现有 Task 3 白名单文件至既有公开仓库，手动执行一次完整验证；原25项和新增8项真实测试及实际 App 编译全通过后，才生成同提交未签名 IPA。此前“只读报告目录”仅针对当时检查，不限制本批。当前源码仍待首次原生验证，不构成阅读验收。
- 本批只新增 `.github/workflows/task3-validate.yml` 和必要验证 helper，并同步范围文档；不改已完成业务源码或测试断言。固定 macos-15 / Xcode16.4 build16F6 / Swift6.1.2（语言6.0）/ XcodeGen2.46.0 / iOS16.6 / 官方GRDB7.0.0。单个 workflow_dispatch、attempt1，先解析依赖，再顺序运行25+8测试，最后编译 iPhoneOS arm64 App；仅全部通过才校验框架/资源/签名状态并打包。实际安装的 arm64 模拟器动态发现，不安装运行时。
- 任一生成、依赖、编译、断言、测试计数或打包失败立即停止，不自动修复、追加推送或重跑；成功也停止等待真机验收。证据与结果仅保存在 ignored artifacts 和云 artifact，不为结果再推送。不得触发旧工作流、不新建替代任务/仓库、不 force push、不安装 Windows 工具、不新增凭据/权限/费用；只用既有登录，不关机。
- Task 2 内核已在基线 `0886cfe9ff7e0955183ca56a16500be808853690` 的 iOS18.5 模拟器实际通过 25 项功能回归，随后同提交完成一次原口径性能测试；不代表 Task 3 UI/存储或 iPhone13 真机通过。
- 保留已验证 TXTCore、原25项断言、性能样本/计时/脚本、现有 CI 工作流和本地 Skills。不得恢复旧工程、回收内容或访问其他项目；不关机。
- 仍固定 iOS16.6、Swift语言6.0、Xcode16.4。使用 ObservableObject + Published，禁止 Observation/Observable/SwiftData 与 Swift6.2+ 专属语法。UIKit/CoreText 有界阅读桥接已获授权，重解码/分章/排版在后台 actor。
- GRDB 仅官方 SPM 固定 7.0.0，保留官方 MIT 许可正文；不追最新版、不选择自有项目许可证。原文件只读，安全作用域及时释放；仅管理应用自有副本。位置须带书籍/版本/偏移单位，不能用页码代替。
- 当前范围不含左右翻页、EPUB、AI、漫画、联网书源或 Task4。故障验证只用合成/可丢弃测试文件，绝不删改个人原书或要求用户操作系统/应用目录。

## 历史 Task 2 规则（以下保留当时原文）

以下“尚未原生验证”“不做 GRDB/UI/Task3”等仅描述当时阶段，不是当前状态，也不覆盖上面的本批直接用户授权；历史外部操作许可不得自动沿用。


- 工作根为当前仓库根目录。保留本地 `.agents/skills` 与 `skills-lock.json`，但不发布它们；不修改技能包，不恢复旧工程、旧 Git 历史或回收站内容，不访问其他项目。
- Task 1 已完成云构建与用户 iPhone 13 / iOS 16.6.1 安装、空首屏验收；该结果不代表阅读功能通过。
- Task 2 本地 TXT 内核与单元测试已写入：严格编码识别/解码、分章、原始 byte 与 UTF-16 映射、后台 actor 内的 CoreText 分页。当前新增授权仅补独立手动单元测试工作流、同步本批授权文档，并发布现有内核/测试和 project.yml；不改内核算法或测试断言。App、原 ios-build 工作流、打包脚本、.gitignore 和 Skills 保持不变。
- 历史 Task 1 仅发布 9 个白名单文件。本次 Task 2 只提交其既有 13 个内核/测试/配置/文档改动及新增 txt-core-tests 工作流，详见 [README](README.md)；不发布本地 Skills / lock、个人文件、凭据或内部原始记录。
- 设备目标固定为 iPhone 13 / iOS 16.6.1；最低部署版本为 iOS 16.6，Swift 语言模式为 6.0。技能中的较新系统或语言默认不能覆盖此约束。禁用 `@Observable`、Observation、SwiftData 及 Swift 6.2+ 专属语法。后续实际业务状态采用 `ObservableObject` + `@Published` 和细粒度 ViewModel，视图持有时使用兼容的 `@StateObject` 等方式；当前空 App 不凭空增加状态或空 ViewModel。
- 根 `project.yml` 是唯一工程定义，由固定版本 XcodeGen 在 macOS 生成。禁止手改生成的 `.xcodeproj`，不引入其他工程生成器；生成工程和构建产物不纳入源码。
- SwiftUI 与并发技能按实际部署目标和工具链应用；UI 类型可明确主 actor 隔离，不把 `@MainActor` 当作所有并发问题的统一修复。没有异步工作时不添加 Task、actor 或并发框架。
- Phase 1 中，本批只实现 TXT 编码/分章/坐标/分页内核源码和对应测试；不做文件导入 UI、滚动/翻页 UI、设置或 GRDB，不安装依赖。Phase 2、3 暂不实现，不铺空 AI 模块或跑团表。TXT 优先不等于永久取消长期 EPUB 等需求。
- 后续 TXT 原始字节只读；“ANSI”不得当作唯一编码，不确定编码必须有预览/选择并保留原字节。断章原始 byte offset 与解码/规范化文本的 CoreText UTF-16 `NSRange` 必须显式映射，带 DocumentVersion 与单位；不能混用字符数、字节和 UTF-16 长度。
- 后续稳定 ID / DocumentVersion / 派生 revision 的来源与映射版本必须清楚；AI 修订只能成为独立派生版本。原著静态 canon 与玩家 Timeline 的 ID、版本及事实职责分离，不覆盖原文、不将分支混为原著事实。
- 产品可在线也可离线；离线仅能使用已实现的离线功能，不得解释为全面禁止联网。BYOK 与用户配置的远端能力需要网络；断网不应阻塞已具备的本地能力。App 当前仍保留 Task 1 空首屏，Task 2 内核尚未接入界面或通过原生验证。
- 不内置小说/漫画源，普通阅读不依赖 AI。未来 AI 仅由用户主动使用自配 OpenAI 兼容 BYOK 接口；不提供官方 AI 服务、额度、代理或后台。本批不接入 AI 或处理密钥。
- Task 1 的授权不沿用。用户已单独批准本次 Task 2 配置修改、白名单 Git 提交/普通推送及一次手动云端单元验证。不建新仓、不 force push、不安装依赖或 Windows 工具、不改系统/凭据、不新建执行器、不关机；只用已有认证，不登录、刷新或扩权。
- 只触发独立 txt-core-tests 工作流一次，保持 ios-build 原样且不触发它；只运行 TXTCore scheme / TXTCoreTests，不生成 IPA、不跑 UI。使用已有可用 iOS 模拟器，记录其实际 OS / UDID / 架构；不假设 iOS16.6 runtime 存在或安装 runtime。失败保存原始日志、真实退出码和 xcresult 后立即停，不补丁重推或重跑，不使用证书、secrets 或付费规格。
- 用户授权负责人选择较稳定的配置，已决定保留 `macos-15` + Xcode 16.4 build 16F6 + XcodeGen 2.46.0，不采用移动的 `macos-latest`。这是工具版本约束，不是不可变 runner 镜像；job 必须核对实际工具版本，不匹配即停。
- 分别报告本地静检、XcodeGen 生成、Swift/Xcode 编译、IPA 打包和真机验收。Windows 静检不能代替任何原生结果；未签名 IPA 也不代表用户已安装或验收。
- 本次唯一原生验证到终态后停在 Task 2，不进入 Task 3；不加入阅读 UI、EPUB、AI、数据库业务或无意义测试框架。不把 15 项测试声明、Windows 静检、其他语言模型或源码存在说成实际 Swift / CoreText 测试通过。
- 用户确认、负责人整合建议、源码、静检、原生测试和真机结果分别标注。Task 1 的 run 与用户空首屏反馈不能作为 Task 2 内核通过证据；不得以其他语言重写模型或源码存在代替 Swift 测试。
