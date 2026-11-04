# A06 + EPUB／内嵌封面合批实现

## 状态与单次验证合同

基线 `54cccb5177668bd2f74179e1b226e844d0a9f1f9` 的167项原生测试及同源设备Release／unsigned IPA已经通过。本文描述新的本地候选，不将基线结果外推为EPUB通过。当前候选尚待统一Swift/WebKit原生验证；Windows脚本、SQL及源码检查不是编译结果。

用户批准54路径上限（19现有＋35新增）、官方ZIPFoundation0.9.19、追加v6迁移，以及原167＋新增38＝205 selected／206 declared。只进行一次普通提交／push、一次既有Task3 full workflow_dispatch attempt1。全部205项逐项真实通过、零跳过后才实际设备Release编译和同SHA未签名IPA；任何编译／执行／计数／打包失败立即停止，不自动修补补推、重跑或复用旧诊断scope。结果仅存ignored artifacts，不为结果二次提交。

## 支持范围

- 本地非DRM可重排EPUB2/3：保留原始归档，OPF、spine、nav／NCX目录，章节及fragment跳转，离线WebKit正文，基本字号／行距／纸白暗主题，文本锚点进度和复开恢复。
- XHTML常见段落、标题、强调、列表及本地JPEG／PNG插图；出版物CSS不原样执行，采用可信阅读样式。不静默转换为TXT。
- OPF声明的JPEG／PNG内嵌封面，最长边512像素缩略图。缺少／损坏可选封面回退现有文字占位；CRC、路径、正文及资源完整性错误不被回退吞掉。
- TXT既有导入、编码、派生包、目录、进度、设置及全部书签行为保持；一个格式路由包装选择现有TXT阅读器或新EPUB阅读器，不增加竞争的全屏呈现入口。

不包含：EPUB书签／批注／搜索／同步／完整CFI／左右翻页、DRM或加密、固定版式、联网内容、出版物脚本、音视频、漫画及AI。不保证任意CSS、SVG、复杂MathML或嵌入字体；依赖不支持能力的正文应明确拒绝。EPUB不显示可点击但无功能的书签入口。A07 Dock动画继续延期，50MiB由10MiB真机结果决定。

## 存储、兼容和生命周期

- Picker保持`[.item]`／`asCopy:true`／单选及现有交接。仅`prepareReadingImport`显式分流`.txt`／`.epub`；底层TXT `prepareImport`继续拒绝EPUB。
- 延续安全作用域、文件协调、普通文件／非符链准入、应用私有复制与取消票据。EPUB解析、封面和有效元数据完成后，存储actor执行无await的提交决策／文件改名／SQLite事务；失败只清理本次暂存，提交后的取消返回实际提交结果。
- 原包以完整SHA身份保存在Books；每次打开重新校验完整原包并在本会话的新工作目录解析，比较持久化元数据。资源白名单绑定路径、MIME、大小和SHA。派生目录可丢弃，不覆盖原包。
- v1–v5迁移文本、原TXT表和Codable字段保持。v6新增独立`bookFormats`（旧行回填默认TXT）、`epubPackages`、`epubProgress`。不增加旧`books`列，避免改变原迁移测试对全部列的对照；EPUB的`encodingRaw="epub"`是非文本编码判别值，不冒充TXT编码。EPUB提交和打开同时验证格式记录及元数据。
- EPUB位置单位`epub-text-node-utf16-v1`，包含原包SHA／解析版本、规范spine路径、确定性DOM文本节点和Swift Character合法边界的UTF-16偏移。不是ZIP字节偏移、页码或百分比。
- session、递增sequence与导航UUID epoch共同限制写入；恢复和排版就绪前不保存默认位置，旧章／旧会话／关闭后的回调不能写入。并发关闭等待同一个最终事务；未呈现的取消只撤销会话，不覆盖偏好。
- 退出／后台保存须完成可靠提交或向用户报告失败。真机后台终止时机不由领域测试替代。

## 安全与预算

| 限制 | 上限 |
|---|---:|
| 原始压缩包 | 100MiB |
| ZIP条目 | 4096 |
| 实际解压总输出 | 256MiB |
| 单XHTML／图片／元数据XML | 8MiB／16MiB／2MiB |
| spine条目 | 2048 |
| 封面预解码 | 单边16384、4000万像素 |
| 封面结果／缓存 | 512像素最长边、结果2MiB；8项且合计4MiB |

ZIP使用官方ZIPFoundation，检查完整目录／头部范围、实际流式输出和返回CRC；拒绝路径穿越、绝对／盘符／反斜杠、符链、规范化冲突、损坏截断、加密或未知压缩。XML不加载DTD／外部实体，拒绝实体声明与膨胀。正文安全处理后为每个可定位文本节点生成稳定`yj-tN`，保留合法fragment ID并拒绝冲突。

WebKit使用非持久化数据存储、自定义本地scheme、当前session／epoch能力和验证资源白名单；不授予任意file URL读取。出版物JS、表单、弹窗、外部导航和网络子资源禁用，结合CSP、内容规则及导航策略。可信定位脚本运行于隔离WKContentWorld。关键安全路径需真实WebKit Host测试，不能只凭字符串检查称通过。

## 固定依赖与工具链

- macOS15、Xcode16.4 build16F6、Swift6.1.2／语言6、XcodeGen2.46.0、最低iOS16.6。
- 官方GRDB7.0.0：`4de97e6903d29697caae1179cdef8479c64c2639`，manifest SHA256 `8140971be34f0cc80ef71e96a2b709ff98358a5c7412fe2e2a1687a4cb21867a`。
- 官方ZIPFoundation0.9.19：`02b6abe5f6eef7e3cbd5f247c5cc24e246efcfe0`，manifest SHA256 `2dd90c2f70b1f3d17a4d73bd32ac97e5fc002eecd5797586edaf170def789fff`。
- ZIPFoundation MIT原文SHA256 `5d9ecf59967651f9483b87ddd8d89b0cff66ad0f4c67d8658cb24a7610b70222`，随App资源及许可页展示。
- 精确验证这两项pin的URL／版本／revision／manifest，拒绝额外依赖。最终核验实际App／IPA中的Mach-O、资源、许可、unsigned状态和built-App字节一致性，不沿用旧12文件数量假设。

## 统一测试覆盖

| 组 | 数量 | 合同 |
|---|---:|---|
| TXTCore Debug | 25 | 原身份和断言不变 |
| ReaderDomain Debug | 138 | 原107＋Archive10＋Package8＋Library8＋Progress4＋A06 1 |
| Block Release | 6 | 原边界与差分不变 |
| 串行测量 Release | 1 | 原口径不变，不冒充A06手机结果 |
| App Host | 17 | 原13＋EPUB真实WebKit／定位／隔离／显示4 |
| 原TXT UI | 12 | 原身份、断言、180秒单例及1200秒组预算不变 |
| Canvas | 3 | 原断言不变 |
| 独立EPUB UI | 3 | 导入封面目录；退出与进程重启；设置／无封面／TXT隔离 |
| **合计** | **205** | 声明206，原独立性能基线仍不选 |

新增Library覆盖原包保留、去重修复缺失副本、解析后提交前取消、提交后真实结果、坏包及SQL失败回滚清理、v5→v6旧TXT数据、封面边界回退、跨书／跨格式隔离。Progress覆盖版本／单位／字素边界、未就绪／非递增序号、旧导航／关闭回调、设置恢复合同。具体身份由`task3_test_inventory.py`精确登记并逐项对照源声明。

同一次工作流串行使用相同已安装模拟器。Host仍480秒、原UI仍1200秒、XCTest单例180秒、job60分钟；新EPUB UI独立480秒／10分钟步骤。两种UI class显式解析，各自证据目录，要求start／finish／exit0／同源收据及每例PNG和完整App AX。未知／重复／跳过／未完成事件不得忽略。

## A06剩余真机验收

固定样本`YueJing-A06-10MiB-UTF8.txt`：10485760 bytes、128章、34944段；SHA256 `d7491190dee070c3229bd782fac4ef73a56c55ab8a0d3440f13559af22252cf8`。本轮领域测试复现精确生成规则，真实导入、检查目录和跨章、保存后新store／service复开；不等于App真实进程重启、可见首绘、FPS或RSS测量。

现有L01–L08记录均未执行、耗时空白：导入、首次打开、同进程复开、App进程重启复开、跨章、持续10分钟阅读、退出位置恢复、工具操作。用户在同一iPhone13／iOS16.6.1记录实际结果及测量方法后才可判定A06完成；不要求上传私人小说，不卸载／清库。

## EPUB手机样本与步骤

`python3 -B scripts/make_epub_acceptance_samples.py --out <新的输出目录>`生成可丢弃合成样本：EPUB3封面、EPUB2 NCX封面、无封面、损坏可选封面，以及固定版式／路径穿越拒绝样本；含清单和初始未执行CSV。ZIP生成检查不是原生解析通过证明。

取得同源验证包后，用既有签名／安装方式保留应用数据：
1. 分别导入EPUB2／3，核对格式标识、内嵌封面及原有TXT仍在。
2. 检查目录顺序、跨章和章内fragment，滚动到可识别段落。
3. 退出书架复开，再保存后结束App进程并重开，核对同一文本位置。
4. 调整字号／行距／主题，核对重排后的锚点及恢复。
5. 无封面和坏可选封面应显示占位且可读；不支持／不安全样本应明确拒绝，不影响已有书和进度。
6. 返回TXT核对进度／书签与EPUB不串书。记录后台／前台以及连续阅读异常。

**未完成项：**本批原生执行与设备编译／IPA尚待实际结果；A06和EPUB手机观察需用户提供。不得把样本存在、静检或模拟器通过写成手机全部验收通过。
