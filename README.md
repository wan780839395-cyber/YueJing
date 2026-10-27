# 阅境 · Task 2 本地 TXT 内核

Task 1 的 SwiftUI 空 App、云构建和安装已完成；用户报告 iPhone 13 / iOS 16.6.1 成功安装并看到“阅境 / 准备中”。这仅是空首屏验收，不代表阅读功能通过。

当前 Task 2 仅增加本地 TXT 编码、分章、坐标映射、CoreText 分页内核及单元测试源码，尚未原生编译或运行。App 界面保持空首屏，未接入内核；不做阅读界面、EPUB、AI 或数据库。

最低部署固定 iOS 16.6，Swift 语言模式 6.0，选用 Xcode 16.4 / Swift 6.1 工具链。禁用 `@Observable` 和 Swift 6.2+ 专属特性；没有新增依赖、空 ViewModel 或 UI 测试框架。

## 文件入口

- `README.md`：本页，说明范围、工具链及验证方式。
- `docs/REQUIREMENTS.md`：用户确认、工程约束和分层验收边界。
- `AGENTS.md`：本目录工作与授权规则。
- `project.yml`：唯一工程定义；生成的 `YueJing.xcodeproj` 被忽略，不手工维护。
- `App/YueJingApp.swift`、`App/ContentView.swift`：最小 App 入口和首屏。
- `Sources/TXTCore/`：类型与映射、严格分块解码、整行分章、CoreText 分页、唯一公开 actor 入口 `TXTProcessor`。
- `Tests/TXTCoreTests/`：编码、坐标、分章、分页四组 Swift Testing 单元测试，调用实际生产内核。
- `.github/workflows/ios-build.yml`：只允许手动触发的一次云构建入口。
- `.github/workflows/txt-core-tests.yml`：独立手动 TXTCore 单元验证，不构建 App 或 IPA。
- `scripts/package_ipa.py`：验证真实 App 后打包未签名 IPA，不签名或安装。
- `.gitignore`：排除生成工程、构建产物与本地技能。

Task 1 根提交 `eb0165e9eba3ee5fc2bc5284ffb55e5897072435` 只包含原 9 个白名单文件。用户已另行批准本次 Task 2 配置修改、发布既有内核/测试/必要文档及一次原生云单元验证；不借此修改算法、断言或扩功能。用户自装的 `.agents/skills` 和 `skills-lock.json` 保持原样且不入库。

## TXT 内核合同

- 输入 Data 原字节保持不变；UTF8/UTF16 严格按标量解析，GB18030-2000 / GBK-95 使用公开 CoreFoundation 编码并要求无损往返。BOM 优先；无 BOM 多候选产生不同文本时抛出带预览的歧义错误，调用者可显式选择编码。自动可解码不等于已证明作者原始编码。
- 只移除正文开头的 BOM，并将 CRLF / 孤立 CR 规范化为 LF；不做 NFC、替换或文本修补。原文中的 U+FFFD 仍保留，解码器不插入恢复字符。
- RawByteOffset/Range 与 UTF16Offset/Range 不能隐式互换。转换须通过文档自有的 TXTOffsetMap；BOM、CRLF、多字节标量及代理对的内部位置拒绝映射。组合字符标量边界可映射，分页还要求完整字素。
- 文档原字节 SHA-256 提供稳定 ID；版本 ID 同时绑定编码、规范化策略与实际规范化内容。章节/页返回版本及两种范围，不发明正文或标题，前言/未分章文本的标题为 nil。
- TXTProcessor 为非 MainActor 的 actor；CoreText 对象只在同步分页调用内创建和使用，返回 Sendable 值，不以不安全包装跨隔离传递。每页必须前进并完整覆盖；框太小无法前进时抛错，不强塞字符。
- 分章是保守整行规则，副标题须有空白/冒号分隔，不保证所有小说标题均能命中。分块解析仍保留全文件、正文和完整映射在内存，未做大文件性能验收。NUL、CP936 单字节扩展和 GB18030 新标准差异不在本批已认证支持范围内；详情见需求基线。

## 固定工具链

| 项目 | 固定值与依据 |
| --- | --- |
| 标准 runner | `macos-15`；[官方镜像清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md)当前列出所选 Xcode。镜像会更新，job 运行时若不匹配即失败，不自动替换。 |
| Xcode | `/Applications/Xcode_16.4.app/Contents/Developer`，版本 16.4、build 16F6。Apple [系统要求表](https://developer.apple.com/xcode/system-requirements/)列出其 Swift 6 语言模式和覆盖 iOS 16.6 的部署范围。 |
| XcodeGen | [官方 release 2.46.0](https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0)，只在未来 job 的 `_tooling` 内使用，不全局安装。 |
| XcodeGen ZIP SHA-256 | `4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806`，来自[官方 release API](https://api.github.com/repos/yonaskolb/XcodeGen/releases/tags/2.46.0)资产 digest。 |
| checkout | v7.0.1，固定 `3d3c42e5aac5ba805825da76410c181273ba90b1`；`persist-credentials: false`。 |
| upload-artifact | v7.0.2，固定 `cf430e030ddbb5b0abf93d22962f4752f3646cd9`；保留 3 天。 |

ZIP 中 `xcodegen/bin/xcodegen` 及相邻预设资源的布局由该版本的[官方 archive.sh](https://github.com/yonaskolb/XcodeGen/blob/2.46.0/scripts/archive.sh)确认；工作流先校验 SHA，再核对可执行文件和版本。没有使用移动的 `latest` 工具版本。

## 历史 Task 1 构建入口

Task 1 的唯一已批准构建 [run 40466969784](https://github.com/wan780839395-cyber/YueJing/actions/runs/40466969784) 已成功。现有 ios-build 工作流保持原样，只构建 YueJing 空 App scheme，不自动运行新 TXTCoreTests。以下步骤描述已有 Task 1 入口，不构成 Task 2 外部操作授权：

1. 核对 Xcode 版本与 build，记录源码 SHA 和工具链。
2. 下载并校验固定 XcodeGen，在 job 内生成工程。
3. 一次 `xcodebuild build`，输出未签名 iPhoneOS arm64 App；不使用证书、Apple 账号或用户 secrets。
4. 校验 App 的 Info.plist、bundle ID `dev.yuejing.app`、iPhoneOS 平台、arm64 架构、元数据与 Mach-O 的最低系统，以及实际未签名状态。
5. 用 `Payload/YueJing.app` 打包 IPA，检查 ZIP 完整性及包内可执行文件、Info.plist 的 SHA，随后生成 manifest 与 SHA256SUMS。

Task 1 成功产物为 `YueJing-unsigned.ipa`、`manifest.json`、`SHA256SUMS`，附原始构建日志和 xcresult。该 IPA 为 10,304 bytes，SHA-256 `67737af8168ad36853c4cf07335601f2b8d3242c259c3907106bd83626561b4b`。既有 job 超时 20 分钟，仓库权限仅 contents:read，产物保留 3 天；本批不改 ios-build.yml 或打包脚本，也不生成新 IPA。

用户已采用自己的方式安装 Task 1 并确认空首屏；这里不提供签名配置，也不把这个反馈延伸为 TXT 内核或阅读真机验收。

## 验证边界

Windows 本地只做本轮可运行的源码、文件和配置静检。本机没有 Swift/Xcode/CoreText 原生执行能力；本轮未安装解析依赖，也未用 Python 重写内核来假称 Swift 测试通过。

本地新增测试覆盖分块跨字节/GB18030 四字节、UTF16 BOM/代理、emoji/组合字符、换行、空文件、损坏与歧义、非法映射、章节边界、CoreText 页前进/无缺无重/全覆盖。它们是测试源码，尚未执行；不是已通过的测试结果。

## 本次已批准的单次原生验证

新 txt-core-tests 工作流仅 workflow_dispatch，单个标准 macos-15 job，15 分钟超时，contents:read，产物保留 3 天，无自动重试/matrix/push 触发。它沿用已验证的固定 Xcode、XcodeGen ZIP/SHA 和 Actions 完整 SHA，不新增 secrets 或账号配置。

工作流记录 Xcode/Swift、OS 和 runner 架构，从 simctl 实际可用 runtime/device 中选取受当前 SDK 支持的 iPhone 模拟器，使用对应 host 架构，并核对普通 unit-test 的有效 host / 语言 / 最低部署设置。它只调用一次下述 test；不安装 runtime、不跑 UI 或 IPA。UDID 由实际选择记录替换，而不是假设 iOS16.6 镜像存在：

```bash
export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer
_tooling/xcodegen/bin/xcodegen generate --spec project.yml --project .
xcodebuild -project YueJing.xcodeproj -scheme TXTCore -configuration Debug \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,id=<installed-UDID>' \
  -derivedDataPath build/Task2DerivedData -resultBundlePath artifacts/task2-tests.xcresult \
  -parallel-testing-enabled NO -only-testing:TXTCoreTests CODE_SIGNING_ALLOWED=NO test
```

原始 xcodebuild 输出实时 tee，实际退出码单独保留，失败也上传已有日志和 xcresult。成功路径另外记录 Swift Testing 原生日志的执行数，与源中 15 项声明分开核对；不能把 XCTest 外层的零用例摘要当作真实 Swift Testing 结果。

Task 2 原生结果以该次新源码 SHA/run/artifact 为准，本文不预先宣布成功。任一步失败立即报告并停止，不修补重推或重跑；成功也停在 Task 2，不进入 Task 3，不代表大文件性能或 iOS16.6.1 真机阅读通过。
