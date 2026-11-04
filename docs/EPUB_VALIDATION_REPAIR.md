# EPUB 原生验证阻塞的最小修复

## 授权与范围

基线 `d6eb3ad612e40da69f831df56c359be7661efb15`；用户批准三文件修复及一次完整原生验证。仅修改 `App/EPUB/EPUBResourceHandler.swift`、`Tests/ReaderDomainTests/EPUBArchiveTests.swift` 和本说明。验证计数、工具链、依赖和超时预算不变。

## 已知问题与处理

### 不可变 scheme 常量的 actor 隔离

上轮四组 App 相关原生命令均报告 `EPUBResourceHandler.swift:29:49`：非隔离的 URL 构造方法读取了主 actor 隔离的 `scheme`。处理器类型需要 `@MainActor` 来保护 WebKit 与可变会话状态，但 `scheme` 是固定的不可变 `String`，不依赖这些状态。

只将该常量声明为 `nonisolated static let`，保留值 `yjepub`、处理器 `@MainActor`、CSP、会话/代号检查及所有其他成员原样。不使用 `nonisolated(unsafe)`、`@unchecked Sendable` 或 `@preconcurrency` 逃避校验，也不把纯 URL 构造整体移到主 actor。

### 相对 href 与原始 ZIP 条目边界混淆

从 `OPS/Text/ch1.xhtml` 出发，`../../escape.xhtml` 解析为压缩包根目录内的 `escape.xhtml`，并未越出归档。原拒绝用例错误地要求这个合法 href 抛错。

修正同一测试身份中的对照：
- 合法 href：`../../escape.xhtml` 应解析为 `escape.xhtml`，无 fragment。
- 真正越界 href：`../../../escape.xhtml`、`../../../../escape.xhtml` 必须抛出 `unsafePath`。
- 原始 ZIP 条目不同于 href：把 `../../escape.xhtml` 同时加入原始条目拒绝集合，仍需在解压前拒绝并清理目的目录。
- 保留绝对路径、URL协议、编码分隔符/点、非法fragment等原有负向断言；失败注释标明当前 href。

`EPUBResourcePath`、解压器、manifest资源白名单、资源目录符链/大小/哈希检查均不修改。不能为了让错误测试变绿而收窄合法包内相对引用或放宽真正越界校验。

## 验证与判定

- 本地运行现有验证链/事件解析/库存/EPUB正反例，并核对生产文件仅发生常量隔离修改。
- 一次普通提交/推送、一次现有 Task3 full attempt1。205项身份不增减（206声明，独立性能基线仍排除）。
- 使用已有“独立组失败后继续、末尾统一汇总”逻辑。不得因首个失败跳过其他满足准备条件的组。
- 特别逐项核对上轮未执行的35项：Host17、TXT UI12、EPUB UI3、Canvas3。记录通过/失败/未启动/超时及对应原因。
- 编译失败时无法执行尚未生成的测试二进制，不把静态检查、测试声明或命令启动当作用例运行；仍保留其他组的实际结果。
- 全部205及出包门通过才允许同源设备Release/IPA；有失败不自动修补、追加推送、重跑或绕过门禁。

本文描述修复依据与验证合同，不预先宣称原生编译或35项运行通过。实际结果保存在本批 ignored artifacts。A06及EPUB真机验收仍须用户执行，不从模拟器结果外推。
