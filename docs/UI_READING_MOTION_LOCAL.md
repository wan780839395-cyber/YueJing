# 第四批：阅读轻动效、版本与 AppIcon（仅本地）

## 状态与边界

本批按已确认的第三版视觉方向实施，不重做已冻结页面。用户确认的发布目标为 **0.2.0（2）**，未来真实构建的短文件名为 **`YueJing-0.2.0.ipa`**。桌面名称“阅境”、产品/可执行文件 `YueJing`、Bundle ID `dev.yuejing.app` 不变。

- 本批仅修改本地源码、配置、资源与说明；未提交、未推送、未触发 Actions、未安装。
- **原生测试：0；原生构建：0；未生成新 IPA。** Windows 离线检查不代表 Swift 编译、actool 编译或真机验收。
- 旧 IPA 未重命名、未覆盖，仍为 0.1.0（1）。不能把旧二进制改名后当作 0.2.0 交付。
- 后续公开发布、原生构建/测试、打包和安装仍需另行批准；本批不沿用历史云端授权。

## 1. 阅读工具轻动效

新增 `ReaderMotion.swift` 和 `ReaderToolVisibility.swift`：

- 标题栏与底部工具栏统一使用 0.12 秒 ease-out；只改变透明度和最多 6pt 的绘制偏移，不改变阅读视口、布局尺寸或安全区域。
- 调用页继续持有可见性、焦点、点击/无障碍门控和全部动作。工具隐藏后原有 `allowsHitTesting` / `accessibilityHidden` 条件不变。
- 子内容事务清除继承动画，避免文字、内部框架和布局跟着显隐动画插值。
- Reduce Motion 开启时不增加位移或过渡动画，并清除相关事务动画。

`ReaderCompactButtonStyle.swift`：

- 仅背景色透明度使用 0.10 秒反馈，不缩放文字、改变点击范围或延迟执行动作。
- 保留原有 10pt 圆角、6pt 可见底面内缩、0.18/0.08 背景透明度和禁用时 0.4 整体透明度。
- 禁用或 Reduce Motion 时取消新增的按压动画；禁用状态不产生按压高亮。

没有新增计时器、异步等待、动画完成回调、手势或状态机。原有退出/保存等待不属于本批改动，保持原样。动效时长是设计参数，不是设备实测延迟。

## 2. 版本与短包名

`project.yml` 的 App 目标更新：

| 项目 | 原值 | 新值 |
| --- | --- | --- |
| `MARKETING_VERSION` | `0.1.0` | `0.2.0` |
| `CURRENT_PROJECT_VERSION` | `1` | `2` |
| `ASSETCATALOG_COMPILER_APPICON_NAME` | 缺失 | `AppIcon` |

其余工具链、iOS 16.6 最低部署、iPhone 设备族、GRDB 7.0.0、标识、名称和目标/scheme 配置不变。

`scripts/package_ipa.py`：

- 从工程定义读取唯一版本、数字构建号和 AppIcon 名称；要求真实已构建 `Info.plist` 的版本/构建号与源码一致。旧 0.1.0（1）或错误构建号不能被重新标成新版本。
- 从已校验的构建版本生成 `YueJing-{version}.ipa`，使用 `.ipa.partial` 暂存；拒绝不安全版本和已有输出，不覆盖或自动重试。
- 保留 macOS、源 SHA、真实 iPhoneOS/arm64、iOS 16.6、未签名状态、签名材料排除、ZIP 和原始构建字节一致性检查。
- 增加已构建的 `CFBundleIcons` / `CFBundlePrimaryIcon` / `CFBundleIconName`、引用 PNG 和非空 `Assets.car` 检查；清单记录图标名、实际 PNG 文件及 `Assets.car` 哈希。
- PNG 检查只验证有界头部：签名、13 字节 IHDR、非零尺寸，并兼容 Apple 优化图像在 IHDR 前放置 CgBI 块。它不是完整图像解码或 actool 验收。

`scripts/validate_task3.py` 与两份既有工作流同步从 `manifest.json` 的 `ipa_file` 取实际文件名，核对版本/构建、单一 IPA、大小/哈希、ZIP 文件集合和字节。上传步骤使用该派生路径，不再追加长文件名后缀。

短文件名不隐藏验证状态：build-only 工作流仍在清单、状态文件和 artifact 描述中明确 **TESTS NOT RUN、原生执行 0**；完整测试工作流的既有测试步骤、选择及门控未改。本批没有将历史失败改写为通过，也没有把准备的测试声明当作真实结果。

## 3. 缺失图标审计与补齐

修改前，本地 `App/Resources` 只有 GRDB 许可资源，无 AppIcon 资源目录和编译绑定。对已交付旧 IPA 的只读 ZIP/plist 检查也确认：没有 `CFBundleIcons`、`CFBundleIconName`、`CFBundleIconFiles`、AppIcon PNG 或 `Assets.car`。

已新增 `App/Resources/Assets.xcassets` 和 `AppIcon.appiconset`，包含两份目录 JSON 及九张完整方形、不透明 RGB PNG：

| 槽位 | 像素 |
| --- | --- |
| iPhone 20pt @2x / @3x | 40 / 60 |
| iPhone 29pt @2x / @3x | 58 / 87 |
| iPhone 40pt @2x / @3x | 80 / 120 |
| iPhone 60pt @2x / @3x | 120 / 180 |
| iOS marketing 1024pt @1x | 1024 |

图案沿用“开卷成境”的门形/展开书页标识、陶土色与柔和浅底，无文字，不预裁系统圆角。通过已配置的桌面图像工具生成 **一张** 原图，没有额外变体或重试；工具报告模型为 `gpt-image-2.5`。生成请求强调简洁粗线、居中标识、不透明方形、无纹理/阴影/渐变/水印/外层圆角底牌。

原图实际为 1254×1254 RGB，使用环境已有 Pillow 转为不透明 RGB，以 Lanczos 导出 1024 母版及各槽位；未安装依赖。原图与导出记录保存在本次会话 scratch，不将临时检查页面放入项目。

- 原图 SHA256：`495c29fa28561680b9f449e124ccc71491cd79088169c1dcf527d0878144cedc`
- 1024 母版 SHA256：`0728b11f4d92bb9c5149b51c8615b889f209e8abf9e3d5e160ed8404991b2688`

## 4. 已执行验证

以下均为离线源码/资源或合成样本检查，不是 Swift/iOS 测试：

1. 以本批开始前的**实际工作树**为基线：精确限定 8 个既有文件修改、14 个新增文件；176 个保护文件哈希不变，包括前几批未提交改动、测试准备、用户文件、项目 Skills/lock 和两份旧 IPA。HEAD 不变。
2. 对两处工具显隐调用做已知修改反向归一化，和基线源码相等；按钮样式同样只允许新增按压/Reduce Motion 反馈。确认动作、状态、布局、生命周期、退出/保存和调试代码未随本批改动。
3. 九张 PNG 使用 Pillow 校验/解码；槽位、文件集合、实际尺寸、RGB、不透明属性及导出哈希全部匹配；工程版本/名称/图标绑定检查通过。
4. 最终版本离线回归 25 组通过：Python AST、两工作流内嵌 Python、7+15 个 shell 块的 `bash -n` 仅解析、源/构建版本冲突、缺失图标和错误包名等反例，以及 manifest 派生文件名/TESTS NOT RUN 状态保留。合成 App/ZIP 仅在 scratch 创建后清理，从未运行打包 `main()`。
5. PNG 头部专项合成检查：普通头部和 CgBI 在前的头部 2 例接收；坏签名、零宽、错 IHDR 长度、超长/截断/缺 IHDR/重复 CgBI 共 7 例拒绝。这不证明 CgBI 像素内容可解码。
6. 运行既有 `python -B scripts/check_task3_validation.py`：13 组 gate/workflow 检查、40 组 Swift 日志解析样本、12 组 App 日志解析样本通过；报告原生执行 0。

离线脚本及结果分别保存在会话 scratch 的 `validate_ui_motion_release.py`、`offline_release_identity_checks.py`、`ui-motion-release-identity-fourth-batch/verification.json` 和两份 final 日志；没有向项目写入临时脚本或构建产物。

两份旧 IPA 均保持 2,524,064 字节、0.1.0（1）及 SHA256 `4549a61f7a062ae6350681f21d6bcaf4295a8074bfdaf883e0d84fce2db75150`，不是本批新版本产物。

## 5. 尚未验证

- 无本地 Swift/Xcode/actool/iOS 环境；未验证 Swift 编译、资源编译、构建后的 plist/Assets.car、真实 IPA 或安装。
- 未验证实际动画流畅性、快速连续切换、运行时 Reduce Motion 切换、VoiceOver 和真机点击反馈。
- 浏览器检查只确认检查页四张图像成功载入且自然尺寸正确；截图工具超时/断连，截图视觉检查未完成，不记作视觉 QA 通过。iPhone 桌面小尺寸外观、系统遮罩和图标缓存也未验收。
- 历史完整测试仍有 128 通过 / 1 失败的记录；本批没有原生重跑，不得宣称完整测试验收通过。

本地实现已完成，停在未提交状态；下一步仅在另行批准后执行真实原生验证和新 IPA 出包。
