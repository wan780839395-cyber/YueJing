# WebKit Swift overlay 启动兼容修复

## 已观察的问题

Xcode16.4/Swift6.1.2 构建出的 App 在 arm64 iOS18.5 模拟器启动时，dyld 要求加载 `/usr/lib/swift/libswiftWebKit.dylib`，但运行时及 App 中均不存在该库。引用方是 `YueJing.debug.dylib`。Host/Canvas 在测试执行前SIGABRT；两组UI同样有缺库输出，随后无进程/初始书架等待失败并超时。原来的主actor常量编译错误已经另批修复，不是此次启动错误。

## 修正后的最小修复

- 第一轮显式 `-Wl,-weak-lswiftWebKit` 在实际链接时返回 `library 'swiftWebKit' not found`，35项App用例未执行。不能声称该方案修复启动。
- 先前“现有API由客户端内联”的注释没有成立依据。Swift6.1.2接口声明中的隔离世界 `evaluateJavaScript` 是外部overlay方法；改用公开 `NS_REFINED_FOR_SWIFT` Objective-C入口 `__evaluateJavaScript(_:inFrame:in:completionHandler:)`，直接调用系统WebKit。同一内容世界、错误优先、会话/epoch/path校验不变；不转到page world，不开启书籍JavaScript。
- `project.yml` 仅在App、Host及Canvas目标以 `-Wl,-dead_strip_dylibs` 替换失败的弱链接选项，删除真正未使用的动态库依赖。仍须实际二进制证明没有overlay符号导入，并以真实WebKit测试证明运行正常。
- 不修改SDK、不使用私有API、不复制第三方运行库、不弱化系统WebKit.framework、不提升iOS16.6或更换工具链。公开SDK镜像只提供诊断线索，不作为构建输入；最终以固定Xcode实际编译、二进制和运行结果为准。
- 新增 `scripts/check_webkit_linkage.py`：检查实际App及其嵌入framework/test bundle的arm64 Mach-O；该overlay若仍为强依赖，或者有任何指向该库的未定义符号（包括弱导入），检查失败。另运行 `xcrun nm -m -u`交叉检查并保存实际二进制与输出。没有库加载命令且无该库导入也可接受。
- 工作流在所有独立测试组完成后检查两套模拟器App；全部测试通过后的设备Release产物在打包前再检查一次。检查不重建、不启动额外测试、不修改产物。

## 验证要求

- 本地检查器包含弱而未使用/强依赖/弱但仍调用/其他库符号/损坏文件的正反例。Windows静检不是原生启动证明。
- 原205项唯一测试不删减、不改变断言；独立组继续执行，原Host480/TXTUI1200/EPUBUI480秒和单UI用例180秒预算不变。
- 需查看Host中的真实WebKit资源加载、定位、安全隔离和重排测试，以及TXT/EPUB UI的书架打开、阅读、目录、设置、退出/进程重启。只有完整开始/结束和通过证据才计为通过，崩溃/超时/重复事件不算通过。
- 保留每次失败证据。用户本批授权遇到未启动、启动失败或崩溃后继续最小修复并重新验证；这不允许放宽测试或扩展无关功能。
- 设备IPA仍须原完整回归、依赖和产物门禁通过；模拟器运行不代替iPhone13/iOS16.6.1真机验收。

结果仅保存于ignored artifacts；本文件描述修复和验收合同，不预先宣称启动/运行成功。
