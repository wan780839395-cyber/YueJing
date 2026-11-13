# 当前：0.2.21/build23 完整定向验证后的真机测试包

用户本批直接要求完整执行定向范围，验证中失败只记录继续、整轮结束后统一修复，最后编译打包IPA供真机测试。已先处理已知的重复UI测试路径并完成25项实际验证；全程未中途修补或重复启动。

冻结产品/测试/工程来源为 `a0fbb605514759286e61cdeb5cd14f85d595697d`。run `43427854507/attempt1` 的25项均开始并结束：21 Host＋3 UI通过，跨章UI在首次开书等待预期正文可见时失败。与此前180秒长流程超时不同；该首次打开失败根因仍未知，统一排查后不猜改产品、不加时或改断言。原始失败及24项通过证据均保留。

设备专用入口为 `validation_scope=epub-diagnostic-a0fbb60`，显式 `allow_unqualified_ipa=true`、`build_ipa=true`、prior为空。只执行epub_diagnostic，不启动模拟器或Domain/Host/UI。新打包轮原生执行0，回执仍为 `DEVICE_DIAGNOSTIC_ONLY` / `UI_NOT_QUALIFIED`；独立验证引用不是打包轮原生资格，不把24项旧观察填成当前全绿。

仅允许本说明、`.github/workflows/task3-validate.yml`、`scripts/epub_diagnostic_package.py`、`scripts/validate_task3.py` 四个发布路径变化，且为冻结产品的直接子提交。App/Sources/Tests/project/resources与冻结来源相同。设备Release、源码/run身份、依赖、资源/许可/图标、arm64/iOS16.6、unsigned及IPA逐文件字节门全部保留；正式原生资格门不变。

验证引用：artifact14040301098，SHA256 `c049599ff0bd06d5f4fc672c5ea3ffa16af0f00e823130f0f6617d13c6b4e08e`；本地已独立核验归档、256源码指纹、24项通过事件和保存的xcresult导出、1项真实失败。手机无闪、偶发初次打开及完整体验仍待用户验收，不能称所有失败已根治。

下载核验后交付0.2.21诊断IPA及验证/修复说明。使用现有TrollStore覆盖安装，先核对原书架/旧位置，再测首次打开、目录所有操作、长短/图片章跳转、前后台、冷暖重开。不得卸载、清库、删原书或强制重导。交付后停止追加构建，等待真实反馈。

---

以下保留历史发布说明，不是本批来源或验证结论。

# 历史：0.2.19/build21 真机诊断交付

用户本次明确要求：先排查并尝试修复；若无法查明根因且无法修复，则编译可供真机测试的IPA并提供产物位置。本轮有界核查未确认剩余两项打开等待失败的唯一根因，不再猜测性修改产品或重复模拟器回归。

产品/测试冻结于 `47ec79d5c7c79e2cd173b66a60e45c4605e82c9f`（与a493a37产品字节一致），版本0.2.19/build21。已修复的目录ready早报、字号漂移及精确锚点保留通过定向原生检查；尚未完成成功复验的两项为 `epubOpeningRouteStartsOnceAndObservesMountedPresentation`、`epubWebKitLoadsValidatedLocalResourcesAndRestoresTextNodeUTF16Position`。前两轮逐项10通过/3失败、11通过/2失败；第三轮工具查询超时，原生0。

复用现有设备专用入口 `validation_scope=epub-diagnostic-47ec79d`，要求显式 `allow_unqualified_ipa=true`、`build_ipa=true`、prior为空。只执行epub_diagnostic，不启动模拟器或Domain/Host/UI。回执写 `DEVICE_DIAGNOSTIC_ONLY`、`UI_NOT_QUALIFIED`、新原生执行0，不将旧11项观察填成当前资格；这些标签表示整体尚未完整验收，不抹掉前轮3项UI通过事实。

仅允许 `.github/workflows/task3-validate.yml`、`scripts/epub_diagnostic_package.py`、`scripts/validate_task3.py`、本说明四个发布文件相对父提交变化。App/Sources/Tests/project/resources保持原字节，不读取/上传用户原书，不改旧库和已保存位置。普通白名单提交/push，不发布用户状态、私有文件或内部证据。

固定原macOS15、Xcode16.4/16F6、Swift6.1.2、XcodeGen2.46.0及其摘要、GRDB7.0.0、ZIPFoundation0.9.19、iOS16.6。XcodeGen使用既有成功分支的同一官方API资产与摘要，不换版本或镜像。设备Release、依赖图、资源/许可/图标、arm64、最低系统、unsigned及IPA对实际App逐文件字节校验全部保留；正式测试资格门不变。

下载后核对artifact SHA/CRC、源码/run/attempt与IPA字节再交付，文件名和说明标记诊断用途。用TrollStore覆盖安装，不卸载清库；先检查版本、原书架与旧位置，再测作者字号、目录、跨章、退出/重开。若卡住，记录步骤、等待时长、错误和本地诊断摘要，不必上传私人正文。交付完成即停止追加构建，等待用户真机反馈。

---

以下为历史批次说明，不是本轮构建身份或通过证据。

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
