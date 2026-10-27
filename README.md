# 阅境 · Task 1

从零建立的 SwiftUI 空 App，首屏仅显示“阅境 / 准备中”。本批交付本地源码与构建入口；没有阅读、导入、书架、数据库或分页功能。

目标为 iPhone 13 / iOS 16.6.1，最低部署版本固定 iOS 16.6，Swift 语言模式固定 6.0。App 无业务状态、无异步任务、无第三方依赖；两个 SwiftUI 类型显式位于 MainActor。未使用 `@Observable` 或 Swift 6.2+ 特性。

## 文件入口

- `README.md`：本页，说明范围、工具链及验证方式。
- `docs/REQUIREMENTS.md`：用户确认、工程约束和分层验收边界。
- `AGENTS.md`：本目录工作与授权规则。
- `project.yml`：唯一工程定义；生成的 `YueJing.xcodeproj` 被忽略，不手工维护。
- `App/YueJingApp.swift`、`App/ContentView.swift`：最小 App 入口和首屏。
- `.github/workflows/ios-build.yml`：只允许手动触发的一次云构建入口。
- `scripts/package_ipa.py`：验证真实 App 后打包未签名 IPA，不签名或安装。
- `.gitignore`：排除生成工程、构建产物与本地技能。

公开源码仅上述 9 个 Task 1 文件。本地可存在用户自装的 `.agents/skills` 和 `skills-lock.json`，它们保持原样且不入库。

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

## 已批准的单次云验证流程

用户已批准从零新建公开仓库、发布本批白名单源码，并手动触发一次构建。负责人选择保留当前固定工具版本，降低漂移；标准 runner 镜像仍会更新，并非不可变镜像。Windows 不安装工具，XcodeGen 仅在该次 macOS job 内下载、校验和使用。工作流按以下顺序运行，失败后报告，不自动补丁重推或重试：

1. 核对 Xcode 版本与 build，记录源码 SHA 和工具链。
2. 下载并校验固定 XcodeGen，在 job 内生成工程。
3. 一次 `xcodebuild build`，输出未签名 iPhoneOS arm64 App；不使用证书、Apple 账号或用户 secrets。
4. 校验 App 的 Info.plist、bundle ID `dev.yuejing.app`、iPhoneOS 平台、arm64 架构、元数据与 Mach-O 的最低系统，以及实际未签名状态。
5. 用 `Payload/YueJing.app` 打包 IPA，检查 ZIP 完整性及包内可执行文件、Info.plist 的 SHA，随后生成 manifest 与 SHA256SUMS。

未来成功产物为 `YueJing-unsigned.ipa`、`manifest.json`、`SHA256SUMS`，附原始构建日志和 xcresult。未通过 ZIP 校验的临时 IPA 不以最终文件名交付；已有打包结果也不会被脚本覆盖。单 job 超时 20 分钟，仓库权限仅 `contents: read`，没有付费规格或自动触发器。

未签名 IPA 需要用户后续采用自己的安装方式；这里不提供签名配置，不把打包成功当作真机安装或验收。

## 验证边界

Windows 本地只能完成源码审查、可用的语法与配置静检。本机未提供 Xcode、Swift 编译器或 XcodeGen；未安装 YAML 解析依赖，YAML 的实际解析与工程生成仍须由未来固定版本 XcodeGen 验证。

公开源不包含生成工程、App、IPA 或虚构的成功记录。云验证结果以对应源码 SHA、run、原始日志和 manifest 为准，真机测试仍由用户完成。空首屏没有可独立验证的业务逻辑，因此没有加入测试 target、Swift Testing 套件或 UI 测试框架。

Task 1 的完整验收要求工程生成、原生编译和 IPA 校验均有真实成功证据；一次云验证的授权不延伸为 Task 2。
