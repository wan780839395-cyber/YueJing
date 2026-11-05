# EPUB 短章/目录修复发布（0.2.5 / build 7）

基线 `d0e195e829c84376f6061f6d98df8d1fcfb8aaff`。用户批准发布、定向验证、编译 IPA 供真机测验；范围内失败可诊断后修复、普通推送并重新编译。保留原始失败，不默认全量回归，不反复修补未知根因。

## 产品范围

- `EPUBLocationScript`：普通导航的 ready 只采样请求章；实际滚动仍报告真实可见章。解决窗口末尾短章因上一章仍可见而发错 ready 路径的问题，不放宽会话/epoch/路径校验。
- `EPUBContentsView`：当前目录索引每次 body 计算一次，行与摘要复用；移除枚举数组分配。匹配规则、选择与关闭权限不变。
- 两份直接回归：连续 DOM 浏览器脚本及既有 Host 测试；原生测试身份、原断言保留。
- `project.yml` 只改 0.2.4/6 → 0.2.5/7。原书、解析/资源哈希、CSP、缓存、进度/数据库、TXT、依赖和最低 iOS16.6 不改。

## 发布入口与证据

现有 Task3 工作流增加互斥 `epub_freeze` 作业，其他作业跳过。固定 macOS15 / Xcode16.4 / Swift6.1.2 / XcodeGen2.46.0，沿用既有 GRDB7.0.0、ZIPFoundation0.9.19 和真实设备依赖、未签名 arm64、资源许可、IPA 逐文件字节校验。

### `validation_scope=epub-freeze-3`

只执行既有测试：

1. Host `epubWebKitLoadsValidatedLocalResourcesAndRestoresTextNodeUTF16Position`（含1633条目录匹配回归）。
2. Host `epubCompatibilityWebKitLoadsStaticImagePageAndRestoresAnchor`（含两章、两张本地PNG、末尾短章的原生ready/滚动回归）。
3. UI `testEPUBShelfCoverAndDirectoryCrossChapterNavigation`。

Host/UI各480秒组预算，单用例原180秒，模拟器准备原120秒；不提高原时限。必须逐项一次开始、一次通过，无失败/跳过/未完成，退出0且有成功汇总；超过180秒的迟到通过也不能取得资格。其余211项不执行、不声称通过。

`EPUB_FREEZE_3_TARGETED_NATIVE / EPUB_TARGETED_NOT_FULL` 仅表示本次选定3项通过。现有UI样本不是1633条目录UI耗时测量；不能据此声称真机原书卡点已全部消失或给出未测量的性能数字。

### `validation_scope=epub-freeze-diagnostic`

仅在依既定停止原则转交真机诊断时选择；不自动从失败测试转绿。新运行不准备模拟器、不执行测试。相同批准范围和真实设备打包门仍强制执行；输出 `DEVICE_DIAGNOSTIC_ONLY / UI_NOT_QUALIFIED`、本轮原生执行0、通过0、完整回归false。此前失败与已通过证据另行说明，不伪装成本轮通过。

两个模式均核对main/repository/commit/run/attempt1、基线祖先与精确10文件变化边界，重新解析保存的资格证据。后续修复使用新提交及新run，不覆盖旧结果。

## 离线检查

```powershell
python -B scripts/check_epub_freeze_validation.py
node scripts/check_epub_horizontal_script.cjs
node scripts/check_epub_continuous_script.cjs
```

入口自检是合成门禁测试；Node/Chromium结果不是Swift/WKWebView/真机验收。产品脚本未变时可核对哈希复用同候选的本地通过记录，不机械重复运行。

## 交付

下载后核对GitHub artifact摘要/大小、ZIP CRC及安全路径、源码/run身份、IPA摘要/元数据、真实Release二进制与依赖证明。交付 `YueJing-0.2.5.ipa` 并说明实际验证模式、编译结果及修复轮次。

iPhone使用覆盖安装，保留原书与进度，不卸载、清库或强制重导入。重点复验原卡点向下滚动、打开/关闭目录及选章是否持续可交互。交付后停止追加构建，等待真机反馈。
