# YueJing：Task 2 与单次原生验证规则

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
