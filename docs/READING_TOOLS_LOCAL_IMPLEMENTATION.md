# 阅读工具本地修复与界面验证（2026-10-28，未发布）

本批基线为 `69e4152eb7d39d521e1617b6ab45ab5d4196b3c6`。该基线的121项原生单测、设备App编译和IPA门槛曾通过，但用户在iPhone13/iOS16.6.1拒收界面：隐藏工具后仍留空，设置后返回书架、变色并无法重进书。本地修复批已完成。用户另行批准本次普通提交/push及唯一一次既有Task3 workflow_dispatch、attempt1，保留原121项并接入新增8项；任一步失败即停，不自动修补、追加提交或重跑。发布前静检不代表真机问题已解决。

## 已证实与尚未证实

- 原正文外层始终按工具高度设置上下padding，普通字号各约72pt。隐藏只改变工具透明度，留位不释放；这是源码可证的空白原因。
- 动态内嵌NavigationStack、主题偏好作用范围、临时拆卸触发close均是候选链。尚未复现iOS16.6.1那次触发顺序，不能宣称已定位/修好真机根因。
- 原121项没有覆盖这条真实SwiftUI/UIKit交互链；其历史通过不构成本批验收。

## 本批行为边界

- 正文从开始占据合理安全区内的完整视口；保留UIKit原16/24pt滚动首尾内边距和20pt文本侧边距。工具是叠加层，不再按工具高度缩小或反复改变正文视口。
- 顶部保留书名/返回，底部仅目录/排版。轻微位移和淡变，减弱动态效果下纯淡变；降低透明度下实底。大字工具纵向排列，排版控件可滚动且避免横向溢出。
- 目录/排版用独立原生sheet，背景阅读区不可交互或滑透。关闭、下拉和Escape只关闭面板；字号/行距/三种主题仍即时应用保存，没有取消事务。
- 排版不再内嵌导航Form；诊断与许可在面板自己的辅助sheet中，NavigationStack只属于该独立呈现。阅读主题使用局部environment和显式颜色，不设置子Dock的preferredColorScheme。
- 书架的ReaderRouteOwner是阅读路由唯一owner；每次打开有新UUID与模型。正常返回先完成原保存/关闭流程，再按相同route ID结束呈现；晚回不能清掉更新路由。
- 临时onDisappear及representable拆卸不再关闭书籍。桥接替换前捕获一份有界临时UI恢复点；新控制器apply前仍有可靠锚点，同windowID恢复视觉位置。像素坐标仅用于同一UI窗口重建，绝不持久化或替代版本化文字锚点。
- 新控制器先attach或旧控制器先dismantle均处理；旧回调立即清除，旧update/detach不能改新handle。明确用户跳章优先于旧视口恢复。
- 正常退出过程中不显示“正文不可用/重试”错误占位；保存失败仍保留原显式错误处理。
- 原32项目录分页、定位和迟到任务保护保持；TXTCore、ReaderDomain、派生存储、数据库和位置合同不改。无新增书签、搜索、慢滚、翻页、AI或书架设计。

## 新增实际App验证入口

`project.yml`新增：
- `YueJingHostTests`：真实App-host单元target，2项Swift Testing UIKit桥接集成，覆盖两种重建先后、apply前锚点、同窗口滚后恢复、旧回调隔离。
- `YueJingUITests`：XCTest UI target，6项真实App流程。
- 独立 `YueJingUI` Debug scheme；原scheme保持；本次发布在既有Task3中接入新scheme的两个target，逐项串行执行。

6项UI流程覆盖设置→关闭→滚动→退出→同书/另一书；主题相对书架环境隔离及持久化；32项分页/当前章/设置/重进；工具显隐与面板返回的viewport frame；长短书EOF尾部几何；连续面板和诊断/许可返回；最大辅助字体下关键控件可达。

滚动断言只采样有限、与viewport相交的实际cell/canvas内容和frame，不对所有离屏CoreText静态元素求isHittable。长书经末章和有限滚动检查EOF尾部在viewport内，不只看marker存在。唤出工具helper最多两次点击：可能先停惯性，再明确显示；它不声称已验证惯性初触策略。

测试只在显式Debug UUID环境下，通过原导入/打开管线建立独立临时合成书库。无标志走原书库；非法测试标志失败关闭，不回退用户书库。夹具不读取或清空用户书库。Debug夹具里的可见小标记只读实际书架colorScheme和动态字体，供UI断言，不覆盖它们；Release不含夹具/标记。

## 本地脚本与证据口径

`python -B scripts/run_reading_ui_tests.py --preflight --self-check`仅检查声明清单和12项合成日志计数器正反例，不运行App，不是Swift解析/编译或交互验收。

未来具备固定macOS/Xcode及已准备的锁定依赖后，显式 `--run --destination "platform=iOS Simulator,id=<installed-UUID>"`才运行新2+6项。脚本不安装、解析依赖、重试或打包；逐组保留原始log、退出码、xcresult和源码哈希，任一失败立即停。合成计数器检查不计入原生通过数。

当前Windows无Swift、XcodeGen或Xcode：本批原生执行0；生成/Swift编译、121项原回归、2项宿主、6项UI均未执行。真机设置故障、VoiceOver焦点、惯性初触、动态字体/旋转、真实末行、帧率与动效仍待验证。EOF frame与AX断言也不代替像素绘制/手机观感验收。

本次公开发布/云验证已获单独批准：原121项全部断言保持；既有Task3在原25/89/6/1项之后实际运行2项App-host和6项UI，再验证129项唯一通过、零失败/跳过/未执行，才进入设备App编译与IPA门槛。runner仅追加实时日志、明确超时、来源SHA/运行/选中清单及真实App/Debug隔离夹具设置核对；合成parser不计入原生数。失败原始证据始终上传，IPA仅成功上传。结果只存ignored artifacts，不为结果再提交。

后续新增能力另列计划，本轮不因“可以再加”扩展产品功能。
