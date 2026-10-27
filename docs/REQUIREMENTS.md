# 阅境需求基线：Task 1 验收与 Task 2 本地内核

## 用户已确认

- 目标设备：iPhone 13，iOS 16.6.1。
- 产品可在线也可离线；离线仅能使用离线功能，不是禁止联网。
- 开发方式：Windows 维护源码，GitHub 标准云端 Mac 承担未来的原生构建。
- Task 1 从零空 App 已完成；用户报告在 iPhone 13 / iOS 16.6.1 安装成功，并看到“阅境 / 准备中”。仅该启动范围验收通过，不代表阅读功能。
- Task 2 本地内核/测试完成后，用户已另行批准补充单元测试云配置、发布现有本批源码并执行一次原生云验证。这是 Task 2 新授权，不沿用 Task 1；不得改算法/断言、生成 IPA 或失败后重试。工作规则见 [AGENTS.md](../AGENTS.md)。
- Phase 2、3 当前暂不实现；Task 2 也不包含阅读界面、EPUB、AI 或数据库业务。

## 产品边界：负责人整合，尚未实现

- 产品支持在线与离线使用，无内置小说或漫画源；普通阅读不依赖 AI。离线仅能使用已实现的离线功能，BYOK 及用户配置的远端能力需要网络。
- 断网不应阻塞已具备的本地导入、阅读、目录、进度等能力。这是产品行为要求；App 当前仍是 Task 1 空首屏，Task 2 内核源码尚未接入这些业务或通过原生验证。
- AI 留待后续阶段：用户自配 OpenAI 兼容的 BYOK 接口，并由用户主动发起联网；产品不提供官方 AI 服务、模型额度、代理或后台服务。本批不接入接口或存储密钥。
- 原始 TXT 字节只读保存。AI 修订必须是独立派生版本，保留来源关系，不能覆盖原文。
- 原著静态 canon 与玩家 Timeline 分离：原著事实、AI 派生内容和玩家分支不能混为同一事实，也不能相互覆盖。
- 负责人保留格式范围待后续整合：未来 Phase 1 以 TXT 为先；最新蓝图未明确取消此前长期 EPUB 要求，不据此永久删除其他格式需求，也不在 Task 1 实现任何格式。

## Phase 1 蓝图与当前实施范围

| 职责 | 要求与待验证边界 |
| --- | --- |
| TXT 导入与编码 | Task 2 接收只读 Data，编写严格编码内核，不接入文件导入 UI。标签为 UTF-8、UTF-16LE/BE、CoreFoundation GB18030-2000 / GBK-95；BOM 优先，无 BOM 的不同有效解码返回歧义预览并要求明确选择。“ANSI”不是唯一编码。原生 CF 映射尚待验证，不宣称覆盖所有 GB18030 标准版本。 |
| 正则断章 | Task 2 编写保守整行规则，保留真实原字节范围、前言与未分章正文。字幕需明确分隔符、标题长度受限、句子标点和正文前缀受保护；不是语义模型，可能漏掉不符合规则的标题，后续需真实样本评估。 |
| CoreText 分页 | Task 2 在后台 actor 内编写分页，返回带版本的 UTF-16 范围及映射后的原字节范围；CF 对象不跨隔离。page 边界需完整字素，无法前进时失败，不跳字或强塞字符。CoreText 原生行为尚未运行验证。 |
| 阅读呈现 | 上下滚动与翻页；字号、行距及背景色设置。当前空 App 未实现。 |
| 进度持久化 | 蓝图要求使用 GRDB 保存进度；尚未添加依赖，未设计 schema，也未完成集成、链接或运行验证。 |

后续实际 UI 业务状态遵循用户蓝图：禁止 `@Observable`，采用 `ObservableObject` + `@Published` 与细粒度 ViewModel；由视图持有时使用兼容的 `@StateObject` 等方式。当前空 App 没有业务状态，不为词条创建空 ViewModel。

## Task 2 实现合同与限制：源码已写，未原生验收

- `TXTProcessor` 是非 MainActor 的 actor。调用者 await；解码、分章与 CoreText 都在其执行器内同步处理。返回不可变 Sendable 文档/范围值，不返回 CTFrame、CTFont 或 attributed string，也不使用不安全 Sendable 包装或 detached task。
- 编码按实际字节分块保留不完整标量；UTF-8 拒过长、非法代理与越界，UTF-16 拒奇数字节/错误代理对，GB 序列须按对应 CF 编码无损往返。不插入替换字符；源中本来存在的 U+FFFD 仍保留。
- BOM 仅从正文中排除，原始 Data 完整保留；只将 CRLF 和孤立 CR 规范化为 LF，不做 NFC、裁剪或字符修补。BOM 内部、CRLF 中间、多字节标量中间、UTF-16 代理对中间都无合法映射；组合字符的标量间可映射，但不可作为分页字素切分点。
- `RawByteOffset/Range` 与 `UTF16Offset/Range` 是不同类型。只有 UTF16Range 暴露 NSRange；转换必须使用文档自有的 TXTOffsetMap，拒非法/越界端点。范围局部于该 Map 的 documentVersion；持久化时不能丢弃版本身份。
- 空文件返回空正文、一个内容边界、零章节/页。UTF-16 无 BOM 仅接受显式编码选择；NUL 不在本批 TXT 文本合同内，拒绝而非当乱码恢复。GBK 的 CP936 单字节扩展、GB18030-2022 差异未实现或认证。
- 自动识别只证明候选可严格解码，不证明作者意图；UTF8/GB 双重有效且文本不同会拒绝自动选择。ASCII 选 UTF8；GBK/GB18030 得到相同文本时采用 GB18030 标签并列兼容候选。预览最多 80 个字素。
- 当前是内存型内核：保留原字节、全文与完整映射，并在候选编码间扫描；分块解析不等于内存有界文件流。大文件内存、吞吐和真实小说断章质量尚未验收。

## ID、版本与后续 AI / 叙事边界

TXTDocument 与映射版本已有本批源码，尚待原生验证；其余派生 revision、canon、Timeline 仍只是后续技术边界，没有 AI 或数据库实现：

- 本批 Document ID 为原字节 SHA-256；版本 ID 还绑定编码标签、规范化策略版本和实际规范化 UTF8 内容。修改解码或规范化结果不能让旧定位静默指向新文本。
- 章节、定位和进度引用明确的 DocumentVersion；定位同时注明 byte 或 UTF-16 单位，不使用跨文档、跨版本的无单位 offset。
- 派生 revision 使用独立稳定 ID 并引用来源 DocumentVersion / 父 revision；原始版本保持只读。
- canon 与 Timeline 各自具有独立 ID / 版本归属。未来 AI 只处理用户选择的输入和派生输出；动态叙事仅改变玩家分支，不能把生成内容自动写成原著事实。
- Phase 2、3 暂不实现：不创建空 AI 模块、跑团表、网络后台或预铺数据库 schema；具体合同和实现须在后续任务中确认。

## 工程约束

- 最低部署 iOS 16.6，Swift 6.0 语言模式；采用 SwiftUI，首屏仅显示“阅境 / 准备中”。
- Task 2 增加独立 TXTCore framework 和无 App host / 无 UI 自动化的 TXTCoreTests unit-test target；尚未生成工程核验有效 host 设置。测试只用 Xcode 16.4 / Swift 6.1 可用的 Swift Testing 基础 API，不使用技能的 6.2+ 新特性。
- 禁止 `@Observable`；后续状态约束见上，本批仍不创建业务状态。
- 根 `project.yml` 为唯一工程定义，固定 XcodeGen 版本，macOS 生成工程；不保存生成的 `.xcodeproj`。
- 工作流仅手动触发，单个标准 macOS job，固定 Xcode 路径、XcodeGen 官方 release 与 SHA-256、Actions 完整提交 SHA。
- 原 Task 1 构建输出未签名 App/IPA；本次 Task 2 只构建独立 TXTCore/TXTCoreTests 并运行原生单元测试，无 App/UI/IPA，不需要 Apple 证书或新 secrets。
- 用户安装的 Skills / lock 仅留本地，不发布；不恢复旧源码、仓库历史或回收站内容。

## Runner 决定：保留明确工具版本

用户蓝图曾写 `macos-latest`，随后明确授权负责人选择较稳定的配置。当前采用 macos-15、DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer（Xcode16.4 build16F6）和 XcodeGen2.46.0。新增单元工作流沿用该配置，现有 ios-build 保持不变，不采用 macos-latest。标准 runner 镜像并非不可变镜像；job 检查实际版本及模拟器/架构，不匹配即停，不安装或更换 runtime。

## 验收与当前边界

| 层次 | Task 1 已有证据 | Task 2 当前状态 |
| --- | --- | --- |
| 本地静态检查 | 原空 App 及脚本已审 | 仅源码/文件/配置静检；不是 Swift 编译 |
| 工程生成与编译 | eb0165e9… / [run 40466969784](https://github.com/wan780839395-cyber/YueJing/actions/runs/40466969784) 成功 | 本次已批准唯一原生 run，以实际阶段结果为准 |
| 单元测试 | 空首屏未增加测试套件 | 15 项仅为声明；实际执行/通过数由新 run 原生日志记录，不预先宣布通过 |
| IPA | Task 1 unsigned 包通过校验 | 本批无 IPA，不改 ios-build / 打包脚本 |
| 真机 | 用户报告 iPhone13/iOS16.6.1 安装并看到空首屏 | 无内核或阅读验收，不能沿用 Task 1 通过结论 |

本次只发布现有 Task 2 白名单和独立手动测试配置，普通 push 后确认无同 commit 的测试 run，再 dispatch txt-core-tests 一次。保留原始日志、退出码、xcresult 与实际设备/工具信息；任一步失败即停，不补丁、重推或重跑。Windows 不安装工具、不改系统/凭据；单元测试或模拟器结果不替代大文件性能/真机阅读验收，验证结束不进入 Task 3。
