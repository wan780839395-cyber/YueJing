# EPUB 打开衔接定向验证与交付：0.2.15 / build17

## 授权与边界

基线 `d5fde953ca544deaecace0434a45b014ebd630b0`，入口 `epub-opening-continuity-24`。用户已明确批准本批候选和必要版本/验证配置的普通提交、推送、定向云验证、整批结束后必要修复/受影响复验及严格合格IPA交付。失败原始证据保留；用户取消、来源漂移及真实公共前置阻塞仍须遵守。不 force，不安装新工具/运行时，不新增凭据/权限/费用。

本地候选13路径：App的route/model/screen和新增opening presentation helper；Domain的ResourceStore/PublicationCache/OpeningTimings/ContentPool；Ready Domain、EPUB Host与UI测试；呈现源码检查脚本和说明。另允许版本工程定义、既有Task3 workflow、runner/checker及本说明。`AppVersion.swift`无需改动，它读取Bundle版本；实际版本仅由project.yml的MARKETING_VERSION与CURRENT_PROJECT_VERSION更新。其他工程设置、依赖、TXT和分页JS、renderer缓存预算及完整校验要求保持。

## 影响与最小原生范围

|目标|声明|展开执行|选择依据|
|---|---:|---:|---|
|ReaderDomainTests|14|15|9项Ready冷暖恢复/损坏/租约/取消/计时＋5项资源复开/符链拒绝/失败清理/TXT隔离；其中Bool参数展开2次|
|YueJingHostTests|7|7|2项新增打开观测/提前任务回归＋真实WebView资源、隔离安全、字体/跨章/旧token、图片页、LRU页面复用|
|YueJingEPUBUITests|3|3|书架与目录跨章、结束进程后精确位置恢复、字号和TXT隔离|
|合计|24|25|五个新增测试全部纳入|

全部精确身份见runner的SELECTED_FILES；每声明独立命令和证据目录。总清单241声明/242展开；本轮选25展开，其余217未选。UI展示全部15项，其中选3/未选12；这是定向验证，不是全量回归。

本批业务源码已变化，不能直接复用旧0.2.14的Host1＋历史36资格。首次validation的25次全部新执行，历史测试复用0。未改的压缩包解析、纯TXT算法与JS布局检查不默认重跑；已有静检只有在相关源码摘要一致时才引用，不伪装本次原生执行。

## 两阶段

1. **validation**：`build_ipa=false`、`prior_validation_run=''`、`allow_unqualified_ipa=false`。执行本批全部24声明/25展开、模拟器链接检查和严格资格核验。每项失败/超时后记录并继续独立项，全部结束并收集后才统一处理。公共前置失败标blocked/not_run，不制造业务失败或通过。失败后按实际改动说明复验范围，不能自动全量重测。
2. **delivery**：`build_ipa=true`、`prior_validation_run`为成功、attempt1、同源码的本批validation。重新核验API来源、archive摘要/大小、ZIP安全/CRC/成员、源码与工具链/依赖、原始命令、逐项log/counts/xcresult和Bool两叶；本次原生执行0，复用25。禁止自引用、递归delivery、错source/attempt、缺失/篡改/失败/跳过证据。完成实际iPhoneOS arm64 Release编译、WebKit/SDK依赖校验与IPA打包。

历史保留xcresult进行原生解析时必须使用临时副本，避免xcresulttool生成database.sqlite3污染固定成员清单；不以忽略多余文件的方式放宽完整性。

## 固定配置与失败语义

固定macOS15、Xcode16.4/16F6、Swift6.1.2（语言6）、XcodeGen2.46.0、GRDB7.0.0、ZIPFoundation0.9.19、最低iOS16.6。保留30秒工具链探测、480秒调用、180秒用例、120秒模拟器启动、60分钟job预算。动态选择已有arm64模拟器，不安装runtime。

实际退出码、调用超时、XCTest用例级超时分开记录。外层timed_out=false不推翻180秒case-timeout；重启后的空套件不是通过。未开始/未结束/无法确认数量的分支必须保留未知，不能用计划数代填。取消后不得继续调度。

继续独立步骤不等于放宽发布资格。默认且本批强制`allow_unqualified_ipa=false`；未经额外显式授权不交付诊断包。原生资格、设备编译、IPA完整性及真机体验分别报告。

## 实际改动与验收重点

- 点击→load→章节ready→当前路由显示帧机会分别观测；无回执为未取得。CADisplayLink不是像素首绘，进程序号不是OS冷盘证明。
- 提前加载与系统呈现并行；首次自动尝试一次。快速失败不能因视图挂载而静默重试，显式重试/既有后台恢复可重新尝试。
- 短等待无大卡片；280ms小进度、1秒详细说明，ready立即撤罩，不人为增加最短加载时间。首次遮罩不干预正常后续翻章/字体重排；旧正文不提前显示，未ready不可交互。
- 主题hint仅为合法枚举外观提示，正式数据库偏好覆盖；不缓存正文截图。已完成打开样本不能被后来后台活动追溯作废。
- 资源计时固定4lane局部数值统计；路径、符链、类型、大小、完整SHA与取消语义不变。lane累计经过时间不能与墙钟相加或称CPU/关键路径；新增时钟读取开销待真机量化。

IPA须核对实际Release编译、版本/build、arm64/iPhoneOS/minOS/unsigned、完整payload、动态依赖与Swift SDK证明、资源/图标/许可证、API archive及ZIP和交付副本SHA。不能用“编译成功”代替这些检查。

## 真机边界

iPhone13/iOS16.6.1用TrollStore覆盖安装，不卸载、清库、重导入或直接降级。旧书一次性Ready迁移另列，不计入普通打开P95。对比同书暖复开、A→B→A、退后台恢复和结束进程后首次点书，核对正确正文可见且立即可交互；同时检查主题、位置、图片与取消/错误恢复。

已有0.2.14反馈：结束进程后545ms、同进程429ms，无迁移/解析/复制，第二次页面复用且全文档加载总数仍1，支持正常进程首次成本；该对照不是本版新呈现效果证明。常规≤300ms/P95≤500ms仍为待真机测量目标，原生/IPA合格不等于已达到。
