# WebKit Swift overlay 启动兼容修复

## 已观察的问题

Xcode16.4/Swift6.1.2 构建出的 App 在 arm64 iOS18.5 模拟器启动时，dyld 要求加载 `/usr/lib/swift/libswiftWebKit.dylib`，但运行时及 App 中均不存在该库。引用方是 `YueJing.debug.dylib`。Host/Canvas 在测试执行前SIGABRT；两组UI同样有缺库输出，随后无进程/初始书架等待失败并超时。原来的主actor常量编译错误已经另批修复，不是此次启动错误。

## 最小修复

- `project.yml` 只在 App、App-host测试和Canvas测试目标加入继承原标志的 `-Wl,-weak-lswiftWebKit`。不弱化系统 `WebKit.framework`，不嵌入来源不明的动态库，不提升iOS16.6部署目标或更换固定工具链。
- 兼容前提是现有WebKit调用代码不需要从该Swift overlay导入符号，而由客户端实现调用系统Objective-C WebKit API。**不能只凭弱链接或启动成功认定这个前提成立。**
- 新增 `scripts/check_webkit_linkage.py`：检查实际App及其嵌入framework/test bundle的arm64 Mach-O；该overlay若仍为强依赖，或者有任何指向该库的未定义符号（包括弱导入），检查失败。另运行 `xcrun nm -m -u`交叉检查并保存实际二进制与输出。没有库加载命令且无该库导入也可接受。
- 工作流在所有独立测试组完成后检查两套模拟器App；全部测试通过后的设备Release产物在打包前再检查一次。检查不重建、不启动额外测试、不修改产物。

## 验证要求

- 本地检查器包含弱而未使用/强依赖/弱但仍调用/其他库符号/损坏文件的正反例。Windows静检不是原生启动证明。
- 原205项唯一测试不删减、不改变断言；独立组继续执行，原Host480/TXTUI1200/EPUBUI480秒和单UI用例180秒预算不变。
- 需查看Host中的真实WebKit资源加载、定位、安全隔离和重排测试，以及TXT/EPUB UI的书架打开、阅读、目录、设置、退出/进程重启。只有完整开始/结束和通过证据才计为通过，崩溃/超时/重复事件不算通过。
- 保留每次失败证据。用户本批授权遇到未启动、启动失败或崩溃后继续最小修复并重新验证；这不允许放宽测试或扩展无关功能。
- 设备IPA仍须原完整回归、依赖和产物门禁通过；模拟器运行不代替iPhone13/iOS16.6.1真机验收。

结果仅保存于ignored artifacts；本文件描述修复和验收合同，不预先宣称启动/运行成功。
