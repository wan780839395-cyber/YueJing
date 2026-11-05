# EPUB 0.2.4/build6 真机诊断包

用户明确要求在多次 UI 修复失败后停止重复修复和测试，直接编译 IPA 供真机测验。本批只增加诊断发布入口，产品与测试源码冻结于 e8112fb89a5704efcd4e09d15341264e22c5c9b5。

## 根因结论与依据

整体 UI 失败根因尚未确定。已确认的一个缺陷是 WebView 初始化重入：赋值前访问控制器 view.bounds，经 viewDidLoad 再次进入初始化，生成两个同级 reader.viewport。运行42025162555的失败界面证据及源码顺序相互印证。

修复提交d5df2c7的运行42029073843中，8 Domain、4 Host通过；新增的先应用主题再挂载、重复初始化保持同一实例的断言通过，UI快照也只剩一个阅读WebView。但进度用例首次打开仍停留在空白正文/正在打开章节，其原因未定。跨章用例完成正文、分页、单次连续跨章和文档复用断言后，退出测试进程耗时约39秒，总计213.775秒超过180秒，不能用其后的passed行覆盖超时。

最新UI等待优化未获原生验证：42032796900在测试前xcodebuild -version查询30秒超时，原生执行0项，不是Swift编译错误。

## 本批入口

Task3 workflow_dispatch，validation_scope=epub-diagnostic-e8112fb，仅epub_diagnostic作业执行，其余作业跳过。不启动模拟器，不运行Domain/Host/UI，不声称复用历史通过资格。0项新原生测试，UI_NOT_QUALIFIED，DEVICE_DIAGNOSTIC_ONLY。

保留固定macOS15/Xcode16.4/Swift6.1.2/XcodeGen2.46.0、GRDB7.0.0/ZIPFoundation0.9.19、iOS16.6、真实arm64 Release编译、依赖/资源/许可证/图标/未签名及IPA与实际App逐文件字节核验。产品版本0.2.4/build6。旧正式验证门不变。

只允许四个发布路径变化：本说明、scripts/epub_diagnostic_package.py、scripts/validate_task3.py及.github/workflows/task3-validate.yml。所有App/Sources/Tests/project/resources保持基线。

## 持续停止原则

根因仍未定位，或多次修复没有实质进展时，停止反复修改和重复测试。明确区分确定缺陷、尚未证实的推测、测试/基础设施问题；按用户授权交付标注未通过UI的真机诊断包，等待真实反馈再决定下一步。不得为追求绿色无限循环、扩大测试、削弱断言或隐瞒失败。产物完整性和设备编译仍须通过；若无法编译，说明真实阻塞，不伪造包。

## 真机操作

使用现有TrollStore覆盖安装，不卸载、不清库、不删书、不强制重导入。先核对0.2.4/build6及书架/旧进度，再测首次打开、上下滚动跨章、左右分页、工具栏唤出、目录跳转、退出重开和杀进程重开位置。发现卡住时记录发生步骤、等待时长及屏幕状态；不要求上传私人正文或应用存储。该包不是UI验收合格或真机性能通过声明。
