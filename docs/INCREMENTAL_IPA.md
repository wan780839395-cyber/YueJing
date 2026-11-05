# 按改动影响复用测试证据的设备打包

## 本批范围与用户规则

执行测试前说明范围、用例与选择依据；未受改动影响且已通过的用例不重跑。已有入口的强制全量门槛不是重复业务回归的理由。

本批只改 Task3 工作流、`validate_task3.py`，新增复用证据脚本、定向检查与本文。App、Sources、Tests、project.yml、依赖版本、测试清单/解析器、原生预算和断言不改；旧 `ios-build.yml` 不改。

## 历史事实与隔离边界

- `d2110a99f689d11f4afb2fb34a4cbecf54c7d0ae` / run `41843348986` / attempt1：205项原生逐项完成并通过，随后打包依赖门失败，不能声称整条工作流成功。
- 原始artifact `13331969479`，58796132B，SHA256 `a9890310c8f31c1e726766da3829c3414e19d5f0d36b91a5568210d89d299ab3`。
- 后续 `d6289e1` 只修正系统Swift运行库打包校验及检查/说明，产品和测试输入不变。
- run `41943152123` 实际204项通过，最后TXT UI字号预设场景在1200秒整组期限到达时未完成。这次不改写其结果，也不称已修好超时；复用的是输入相同的前轮205项完整通过证据。

## 执行范围

| 本轮执行 | 依据 |
|---|---|
| 证据来源/摘要、源码变更边界、逐项原始事件回执、异常ZIP与复用门拒绝检查 | 新增复用入口的直接影响 |
| 系统Swift解析正反例 | 打包校验改动 |
| 固定工具链下真实iPhoneOS arm64 Release编译 | 新产物生成 |
| 实际二进制加载/导入、SDK系统库证明、资源/许可证/签名及IPA逐文件字节检查 | 本次新产物资格 |

不启动模拟器、不执行`xcodebuild test`；复用205项业务回归，不重复内核、阅读UI、Host、Canvas或性能路径。

## 新入口与证据链

在既有Task3工作流手动选择 `validation_scope=reuse-native-205-d2110a9`。独立 `package_reused` 作业与旧 `validate` 作业互斥，默认full模式保持原逻辑。新作业固定macos-15、Xcode16.4/16F6、Swift6.1.2、XcodeGen2.46.0、最低iOS16.6。

门禁检查固定基线run/attempt/source、原artifact摘要、Git祖先与整个树差异白名单、工作区与提交blob一致、未变受测源码指纹、205项原始日志与原生回执一致以及当前解析依赖与历史两包完全一致。任何产品/资源/测试/project/清单/解析器输入改变即拒绝本模式，需重新做影响分析。原生证据过期/缺失/损坏也拒绝，不自动转全量重测。

`package-gate-reused` 只替换“测试资格来源”，保留同套实际设备依赖、资源与签名门；`verify-ipa-reused` 仍把每个IPA文件与真实built App逐字节哈希比对。

回执明确 `native_tests_executed_this_run=0`、`reused_native_passed=205`，记录 `tested_source_commit` / `tested_run_id`，本轮source/run另列。不会将旧日志伪装成本轮事件，不在新回执填写误导性的同轮 `tests_passed=205`。

## 本地定向命令

```powershell
python -B scripts/check_reuse_native_evidence.py
```

可加`--evidence <既有原始证据目录>`做只读事件重解析；这是证据校验，不是重新执行Swift测试。除此之外只检查修改Python语法、工作流结构、shell语法及diff。

## 交付与待测边界

成功产物仍为unsigned `YueJing-0.2.0.ipa`（build2、dev.yuejing.app），不冒充App Store/TestFlight签名包。实际路径/摘要/本轮结果随产物报告交付。

真机由用户在iPhone13/iOS16.6.1通过已有TrollStore覆盖安装，保留原书/进度/书签，不卸载或清数据。待测：覆盖安装与冷启动、旧TXT数据保留、TXT/EPUB导入阅读、目录及跨章、字号行距主题、首次退出、进程重启位置、TXT书签、EPUB封面回退和非法文件拒绝。预期分别为不闪退/不丢数据、正文可读、跳转正确、重排锚点保持、首次退出有效、进度与设置持久化、书签不串书、坏封面不影响正文、不支持文件明确拒绝。全部真机结果在用户反馈前仍是未执行。
