# 柔和书卷：本地展示层落地

本批仅本地源码与离线合同检查，基线 `7d55aa5795abcb692af50f37c54c3a51bd841ac3`。批准原文「批准本地UI落地与检查」（messageID unavailable）；不提交/推送/Actions/构建/出包，不复用历史1/1/1额度。原生编译、原生测试与实际视觉/命中验证均0；旧7d55设备包成功不是本批dirty源码通过。

## 唯一设计与落地
目标为 `artifacts/ui-soft-editorial-design-20261031-163731/`（用户已接受的柔和分层），不是161133完全去装饰稿。两稿各7文件及原accepted prototype13文件均冻结原字节，不更新网页或重做设计。

- A：更多/菜单为安静44pt图标入口，导入单一低饱和填色胶囊，不画永久轮廓。页头保留开卷标、真实本数与「书架/标语」主次；A纯书录采用16pt节奏，原书名/日期/TXT元数据。**省略A装饰编号**：保留原 `ForEach(books)` 身份与原序，不构造数组拷贝/索引身份，不为显示序号逐行firstIndex导致O(n²)，也不赋假业务ordinal。
- B/C：B原三底部分区与C侧栏IA不变；文字封面仅取真实书名首字，48×66低饱和书脊，不生成假作者/进度。B/C用标语作内容页头，原导航标题仍为书架，避免重复大标题。书名语义字体、可换行，保持原lastReadAt/新加入文案。
- 设置：外观与入口仍为原两个Menu，原选择动作和顺序不变。共享系统insetGrouped一层组面，title-left/current-right/向下指示；窄/大字可纵排。解释在Section footer，不每项“当前+勾+框”。显式自定义buttonStyle消除List自动整行合并语义，目标/按下反馈限于行内，label padding在frame/contentShape前；外部空间没有相邻动作。
- C drawer仅当前项淡明度带，其他透明；关闭安静但44pt；原遮罩、root inert、focus返回、禁用与ReduceMotion不变。探索/规划/诊断/license原入口和未接入说明不变；规划模块共一层柔和组面，不单项填框。
- Reader A双按钮浮层/B贴边两端且中央真空/C收合胶囊与展开托盘不变。只用ReaderTheme派生工具色：前景单色、外层soft surface/静态极轻阴影，内部quiet action无永久填/边。C收合胶囊用28圆角同形paint/hit，展开24圆角托盘。正文viewport不预留空间；adaptive/compact滚动分支与控件高度保持。
- Reader顶titleBar仅将20圆角描边+背景换为16圆角单背景；button/frames/字体/AX/focus/task/宽度与退出保存链逐字保护。网页书名字阶没有强行覆盖本次受保护native title字体/行数。
- 共用面板：去重复accent短条与“字色式”badge，标题/说明留白建立层级。完成用.primary轻fill，普通目录/排版/翻组为.quiet；Restore保持原确认与动作，仅低强调。Preview真实固定样本文字/实际fontSize/lineSpacing/ReaderTheme绑定不变，仅样张padding/静态阴影。
- 排版：加减与数值合一底组，按钮各>=44pt且不外扩，数值居中42pt最小槽；原slider松手提交、辅助输入/步进即时提交保持。Preset共享一层组面、选中仅淡surface+字重（无勾/描边叠加）；theme小色样+单勾，整选项轻选中/同形焦点，保留原AX value/selected trait与3主题/3预设/范围。
- 目录：真实digit Text测量/超6位和大字纵排保持；当前章仅淡组带+必要原check/AX，去accent侧条与框。总章节数/真实组范围保留。Footer一组轻actions、真实hourglass固定16pt及对侧槽、禁用条件/current动作与原sheet兄弟/task附着位置保持。

## 样式职责与边界
`ReaderCompactButtonStyle`区分.quiet/.primary，只提供44pt几何和局部pressed fill；不再保留无效surfaceInset/outlined参数，全部caller同步。选中由option自己的整形paint负责。press沿原ReaderMotion100ms，只动画背景fill，不动画label/frame/blur/shadow，ReduceMotion与disabled取消动画。管理同样采用局部AppControlButtonStyle，原AppAppearance三家族/Light/Dark值保持；reader仅工具surface有纸/浅/深展示差异，正文主题枚举值/颜色/存储不改。

## 检查与复跑
六个既有UI checker普通CLI验证当前soft-editorial语义及真实负例，职责仍分别为管理导航、dock/D1、目录排版、motion、外观持久化、控件几何/精确paint范围。没有新全能checker/生产文件。`check_ui_control_cohesion.py`历史fdbdca/53片段与旧保护函数仍保留，仅显式`--historical-baseline`进入；motion/dock/navigation显式历史freeze参数仍严格比旧hash，不把新freeze伪装为旧批通过。历史报告不改。

当前精确paint合同使用本次实际preedit7d55与 `artifacts/soft-editorial-ui-local-20261031T085953070749Z/paint-fragments-v2.json`（首次清单另存不覆盖；v2只修正无模块时不生成空组条）。每个片段固定新旧区间/hash及唯一上下文锚点，再逐片段逆转比较剩余全文；不屏蔽整文件、整个业务函数或所有frame/background。该清单是审计合同，不是Swift/真实几何执行。各CLI的scope仅复用精确delta，不嵌套跑其他整套检查计数。

```powershell
$env:GIT_OPTIONAL_LOCKS='0'
$env:PYTHONDONTWRITEBYTECODE='1'
$env:TMP=$env:PI_SCRATCH_DIR
$env:TEMP=$env:PI_SCRATCH_DIR
python -B scripts/check_library_navigation_schemes.py
python -B scripts/check_reader_dock_schemes.py
python -B scripts/check_navigation_panel_layout.py
python -B scripts/check_ui_motion_polish.py
python -B scripts/check_app_visual_foundation.py
python -B scripts/check_ui_control_cohesion.py
git diff --check
```

证据目录同上，含preedit/posthash、完整diff、实际修改清单、每次命令真实exit/stdout/stderr、开发首错与修正。覆盖全部tracked+相关untracked源码/Skills/lock/三私hash、两稿和原型、最新交付IPA一份、原pycache列表/hash，类别重叠不加总。未递归扫描历史海量artifacts。范围最多30路径，仅实际必要变更；HEAD/index/staged保持本批开始值。

独立复核由主会话安排一次；本执行器不递归委派。Windows离线静检不是Swift编译、视觉/触控/VO通过；原生大字/横屏/short-height、色彩对比、系统Menu/List按下/焦点/容差、C/D1真实交互仍需后续明确授权的设备检查。

## F1 定点修复（独立复核后）
唯一独立复核 Astra 指出：虽然原14指定检查均通过，C收合按钮的opaque label底色及当前selected preset底色会盖住共享style的pressed背景。这是源码可达的绘制层次缺陷，非iOS实测；原独立报告/F1及原FINAL全部保留，不改写为原来已通过。

仅把这两处steady base从label内部移到`.buttonStyle(...)`之后的caller `.background`，因此前后层序为 **内容 → style pressed fill → caller steady base**。不在内容前盖veil，不改变共享style、目标几何、D1、action/AX/guard/状态/任务/手势。C仍同形28圆角与原metrics，ReduceTransparency的1/0.97输入不变；selected preset仍16圆角单surface+字重。底色单独保留原disabled 0.4 alpha，避免移出style整体opacity后禁用外观变实；foreground原opacity与pressed enabled/RM门控完全不改。

当前checker追加独立F1 layer-order source合同，直接加载保存的修前真实style+两caller组合并拒绝旧组合（同时验证仅旧C/仅旧preset），不靠造一个无关泛例。新组合按C opaque/0.97、preset selected/unselected × enabled/pressed/ReduceMotion推导32行源码规格；它们不是Swift渲染或实际触摸。原122片段/hash清单不改，另追加明确4个base移动/disabled paint片段，再归一到原清单；不whole-mask业务函数。修复证据在 `artifacts/soft-editorial-ui-local-20261031T085953070749Z/F1_REPAIR20261031T092542046883Z/`，本次新间隔hash与原260/231区间分开记录。

只复测相关六个current CLI（因为共享精确paint合同）、business比较与diff-check，不重跑entry/launch全套。不覆盖Astra的`independent-audit.py`或raw diff/原exit1；LF/CRLF仅是原diff证据格式断言问题，本修复另外保存raw LF diff并标注规范化对等，不当作源码bug。主会话安排原reviewer只核F1关闭，不开展第二轮全面review；本执行器无native编译/视觉/命中验证，也不提交或触发云。

## 31文件发布阶段（新批准；不改UI）
用户另批准「批准31文件发布与单次设备构建」（messageID unavailable）。本次只适配ios-build资格/披露及cohesion阶段接线：23 Swift和其余5checker全部按F1关闭scope hash冻结，不沿用旧16文件发布额度。实际新SHA/次数/run及最终构建结果只记ignored release证据，不把旧7d55包或3b72历史134/1/3当本次通过。

原`current_protection()`及历史函数原样保留；原local阶段在新workflow变化/stage/commit后应拒绝，不能称旧freeze通过。完整UI source/negative/122+4精确paint、F1真实旧source拒绝仍运行。新的显式CLI `python -B scripts/check_ui_control_cohesion.py --release-receipt <本批ignored receipt> --receipt-sha256 <实际receipt SHA256> --release-stage precommit|staged|committed [--source-sha <新实际SHA>]` 额外验证本批固定parent、权威exact31、23Swift/F1 closure与原全部保护hash。precommit锁旧HEAD/index/staged0；staged逐31index blob且仅exact31；committed核单父/newSHA/31blob/其余tracked tree和clean/private状态。receipt/start-freeze/scope各有明确路径与hash绑定，不接受目录白名单、任意metadata或阶段自动跳过。

本地原冻结文件不改/不公开；新receipt/freeze在 `artifacts/soft-editorial-device-buildonly-20261031T094514424891Z/`。云端现有workflow不调用依赖本地ignored证据的cohesion保护CLI；gate自带23Swift+5冻结checker hash与exact31路径检查，status记录实际31候选hash。后续toolchain/Release arm64/GRDB资源unsigned/packaging/loader/upload保持。只一次普通commit/push及397959305 dispatch attempt1；任何真实生成/依赖/编译/资源/打包失败即停，不修补重推/rerun，成功也停止。此说明不是native/视觉/命中验收。
