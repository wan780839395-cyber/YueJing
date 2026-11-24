# 阅境全流程 UI 审视与打磨记录（UI Flow Polish）

> **审阅与验证边界声明**：本轮在 Windows 环境下基于 `YueJing-txt-font` 当前脏工作树完成，仅做源码级 SwiftUI 架构审阅、公开测试断言核对与静态词法/括号平衡检查；**未在 macOS / Xcode / iOS 真机上编译或运行原生渲染**，不冒充原生视觉验收。所有真实视觉比例、字体回退、动态字体换行、深色/墨夜对比度与 XCUITest 回归均列于文末「需上机确认」。

---

## 一、设计原则（阅境本地书斋识别）

在不改动全局调色板、不引入假统计或外部资源的前提下，围绕阅境已有的「宣纸松烟 · 朱砂印泥 · 线装书页」视觉语言，确立四条可落地的设计原则：

1. **案头与检索分境**：无筛选书架呈现「案头续读 + 藏书阁」的阅读书桌秩序；一旦进入书名搜索或格式筛选，即刻切换为清晰的「匹配结果」编目视图，不再把第一条搜索命中包装成「案头续读」。
2. **真凭实据的身份辨识**：绝不虚构进度百分比或作者信息，只在存在误判风险的场景（同名多副本、删书确认）显式呈现真实持久化事实（格式、TXT 编码、体积 `byteCount`、入架时间 `addedAt`、阅读状态 `lastReadAt`）。
3. **所调即所见的活页书样**：强化 `ReaderTypographyPreview` 的活页校样特征，在常规竖屏大面板下常驻于设置滚动区上方，让字号、行距、纸色、快捷排版与底部正文字体选择形成即时联动，无需反复滚回顶部核对。
4. **藏锋于静的安全层次**：将 `sealAccent`（朱砂印泥）克制地统一用于书签、同名提示、破坏性边界及开发者诊断入口；健康状态提示退隐到结构摘要中，异常态才升格为醒目恢复卡片。

---

## 二、全流程逐段发现与优先级

| 优先级 | 流程段落 | 源码级发现 |
| :--- | :--- | :--- |
| **P0** | **搜索筛选与同名删书确认** (`LibraryShelfContent.swift`, `LibraryBookRow.swift`) | 1. 筛选/搜索命中时仍把首条结果渲染为巨幅 `LibraryHeroBookCard`（「案头续读 / 新卷入斋」），其余才入「藏书阁」，语义失真。<br>2. 同名多副本在画廊卡片中缺失体积/编码/入架时间，视觉完全不可区分；删书弹窗 `Alert` 仅写「这本 TXT/EPUB」，无法确认待删的是哪一份副本。<br>3. 搜索框无边框层次，空匹配态 `library.shelf.noMatches` 为裸露 `VStack` 文本，与书架卡片体系割裂。 |
| **P0** | **排版样张与 TXT/EPUB 设置流** (`ReaderTypographyPreview.swift`, `ReaderSettingsView.swift`, `EPUBSettingsView.swift`) | 1. TXT/EPUB 设置均对底部 `EPUBUserFontPicker` 关闭了内嵌样张（`showsSpecimen: false`），约定由顶部 `ReaderTypographyPreview` 担任唯一主样张；但主样张位于 `ScrollView` 内，滚到纸色、快捷排版或选字体时样张已滚出视野。<br>2. EPUB `本章排版` 卡片仅写「作者原始排版 / 阅读器排版」，未在一眼内解释为何「行距」控件会随之显隐。<br>3. `ReaderTypographyPreview` 内状态徽章取 `appearance.accent/sealAccent`，主题切换过渡帧未严格绑定 `validated.theme`。 |
| **P1** | **EPUB 目录层级与可用态提示** (`EPUBContentsView.swift`) | 1. 打开目录时首屏在第一章上方堆叠了 5 层控件条（页头 + 三段标签 + 章节摘要 + 独立「目录可操作」行 + 纵向堆叠的筛选框与定位按钮），压缩有效目录可视高度。<br>2. 摘要行右侧与左侧徽章重复出现两次「共 N 章」。<br>3. 正常态下独立展示「目录可操作」偏调试口径，异常态恢复提示反而缺少卡片级警示区分。 |
| **P1** | **关于 / 开发者模式及返回** (`LibraryExploreSettings.swift`, `ReaderDiagnosticsView.swift`) | 1. `aboutSection` 中「开源许可 / 当前版本 / 导入诊断」均有 34×34 图标卡且分割线左缩进 60pt，唯独「开发者模式」`Toggle` 缺失图标卡导致文字左错位，且开启后与普通设置项缺乏视觉边界。<br>2. `ReaderDiagnosticsView` 未显式声明 `.toolbarBackground` / `.toolbarColorScheme`（对比 `LibraryLicenseView` 已声明），浅色系统搭配「墨夜」外观推入「导入诊断」时导航栏存在对比度风险（本批记录待后续补齐）。 |
| **P2** | **入架 / 编码反馈与空架续读** (`LibraryShelfContent.swift`, `LibraryNoticeBanner.swift`, `EncodingChoiceView.swift`) | 1. `importingCard` 仅展示文字阶段，未将 `LibraryImportPresentation.phase` 的离散阶段可视化，长文件准备缺乏阶段感。<br>2. `LibraryNoticeBanner` 对入架成功、重复保留、取消停止使用同一 `accent` 视觉，区分度偏弱（本批保持原状，留待后续）。<br>3. `EncodingChoiceView` 已有衬线样文与文本选择能力，多候选时可补充序号提示（本批保持原状）。 |
| **P2** | **TXT 目录页头与浮窗工具** (`ReaderContentsSheet.swift`, `ReaderScreen.swift`, `ReaderFloatingToolsView.swift`) | 1. TXT `ReaderContentsSheet` 将「目录 / 书签 / 搜正文」分段栏放在 `ReaderPanelHeader`（「目录」+「完成」）**上方**，与 EPUB（页头在上、分段栏在下）倒置，且切换页签会重建「完成」按钮；因涉及 3 个阅读面板文件改动，本批超出 7 文件克制预算，列为下一批优先收敛项。<br>2. 底部浮动章栏与顶部返回条在双格式已高度统一且受严格点击热区测试保护，保持原状。 |

---

## 三、已落实方案（5 项方案 / 7 个 App SwiftUI 文件）

本批严格限定在 **7 个 App 展示文件**，未改动 `Sources`、`Tests`、`ViewModel`、CI 或 UIKit/WebKit 渲染与手势。

1. **书架检索分境、精装搜索条与离散导入阶段** — `App/Library/LibraryShelfContent.swift`
   - 筛选或搜索激活（`query.isFiltering`）时，不再将首条命中渲染为「案头续读」大卡，改为展示 `匹配结果`（`匹配数 / 总数` 徽章 + 当前筛选摘要 + 一键 `清除筛选` `library.shelf.clearFilter` + 视图切换）与完整结果集合。
   - 重做搜索条（`library.shelf.search`）的卡片底面、焦点描边与图标响应；将 `library.shelf.noMatches` 升级为统一卡片形态并说明当前失效条件（保留「没有匹配的书」与「查看全部藏书」）。
   - 在 `importingCard` 中新增由真实 `importPresentation.phase` 驱动的 4 段离散进度条（读取原件 → 解析内容 → 编排结构 → 写入书架），不捏造百分比。

2. **同名副本真凭实据区分与安全删书确认** — `App/Library/LibraryBookRow.swift`、`App/Library/LibraryShelfContent.swift`
   - 在 `LibraryBookMetrics` 新增纯格式化工具：`encodingLabel`（直接读取持久化 `encodingRaw`）、`shortDate`、`shortTimestamp` 与 `editionSummary`。
   - 为 `LibraryBookRow`、`LibraryHeroBookCard`、`LibraryBookGridCard` 增加默认值为 `false` 的 `showsEditionDetails`（与 `EPUBReaderHostTests` 源码兼容）；当书架存在同名书籍时，卡片在书名与格式徽章之后展示朱砂点缀的「同名副本」真实信息条（编码/体积/入架时间），画廊卡常规态也补充体积显示。
   - 保持 `book.title` 为各卡片无障碍合并标签首位，完整保留 `label BEGINSWITH title` 与 `EPUB · 封面` / `EPUB · 文字占位` / `TXT` 断言。
   - 删书弹窗保留精确标题 `删除《书名》？` 与「删除 / 取消」按钮，正文补充当前副本的格式、编码、体积、入架时间与阅读状态，同名多本时显式提示「书架上共有 N 本同名书籍，本次仅删除此副本」。

3. **EPUB 目录去冗余与空间收束** — `App/EPUB/EPUBContentsView.swift`
   - 去除摘要行重复的「共 N 章」，仅在左侧 `reader.directory.total` 胶囊保留总数，右侧简洁展示「当前第 X 章 / 未定位当前章节」。
   - 正常可用态下将 `epub.directory.availability` 轻量化并入目录摘要行（保留原有标识符与完整 `accessibilityValue` 诊断串）；不可用态升级为朱砂描边恢复卡片，突出 `epub.directory.recover`。
   - 常规字号且未输入筛选词时，将筛选输入框（`epub.directory.search`）与定位当前按钮（`epub.directory.current`，紧凑展示「当前」并保持无障碍标签「定位当前章节」）合并为单行，输入筛选词或无障碍大字下自动切回纵向全宽堆叠。

4. **活页书样识别与阅读设置常驻联动** — `App/Reading/ReaderTypographyPreview.swift`、`App/Reading/ReaderSettingsView.swift`、`App/EPUB/EPUBSettingsView.swift`
   - `ReaderTypographyPreview` 左侧加入细双线书页版心校样线，与右上角朱砂书签带呼应；内部徽章与描边严格按 `validated.theme` 取色，并新增 `compactPinned` 紧凑常驻形态。
   - `ReaderSettingsView` 与 `EPUBSettingsView`（`常用` 页签）通过 `GeometryReader` 与 `verticalSizeClass` 实现自适应常驻：常规竖屏大面板（TXT `height >= 580`、EPUB `height >= 620`，非紧凑高度且非无障碍大字）下将活页样张固定在 `reader.settings.scroll` 上方；中档面板、横屏或无障碍大字自动回落到滚动区内部，避免挤压触控与滚动空间。
   - EPUB `本章排版` 卡片加入左侧色条与一行能力说明（「文字按比例缩放，行高随文字同步」vs「字号与行距可独立微调」）；双格式 `本书诊断` 按钮统一使用 `sealAccent` 标识开发者边界。

5. **关于与开发者模式对齐收束及安全层次** — `App/Library/LibraryExploreSettings.swift`
   - 为「开发者模式」`Toggle` 内部标签补齐 34×34 图标卡（`wrench.and.screwdriver`），与「开源许可 / 当前版本 / 导入诊断」精确对齐至 60pt 基准线，同时保持 `app.switches["library.developerMode"]` 单一开关语义不变。
   - 开启开发者模式时以 `sealAccent` / `sealSoft` 与「已开启 / 仅本机」徽章清晰区分开发者诊断与日常用户功能；为选中外观卡片增加轻柔选态底色，收束底部书斋牌记卡片。

---

## 四、保持原状项（及理由）

- **书架与阅读器核心调色体系**（`AppVisualStyle.swift`、`ReaderVisualStyle.swift`、`LibraryCoverPlaceholder.swift`）：已有清朗 / 柔雾 / 墨夜与 6 套布面封面基础，不重做全局配色。
- **空架插画与导航壳层**（`LibraryNavigationShell.swift`、`LibrarySidebarView.swift`、`LibraryHeaderView.swift`）：书架空态插画、悬浮底栏与抽屉已满足最小 44pt 触达、大字切换与减少动态，保持稳定。
- **阅读器主画布、顶部返回条与底部浮窗工具**（`ReaderScreen.swift`、`EPUBReaderScreen.swift`、`ReaderFloatingToolsView.swift`）：受严格的返回按钮高度、热区探针与隐藏态 UI 回归约束，且功能层次已清晰，本批不动。
- **书签与正文搜索内部流程**（`ReaderBookmarksView.swift`、`EPUBBookmarksView.swift`、`BookSearchView.swift`）：已具备完整的卡片层级、重命名/删除确认与重试恢复。
- **留待下一批处理的源码发现**：
  1. TXT `ReaderContentsSheet` 分段栏位于 `ReaderPanelHeader` 上方（与 EPUB 倒置），需联动修改 `ReaderContentsSheet.swift` + `ReaderDirectorySheet.swift` + `ReaderBookmarksView.swift`（3 文件）。
  2. `ReaderDiagnosticsView.swift` 补齐 `.toolbarBackground` 与 `.toolbarColorScheme`，消除浅色系统 + 墨夜外观下「导入诊断」返回栏对比度隐患。
  3. `LibraryNoticeBanner.swift` 与 `EncodingChoiceView.swift` 的语义图标与候选序号微调。

---

## 五、需上机确认清单（macOS / Xcode / iOS 真机或模拟器）

1. **编译与定向验收（待另行执行）**：编译 App 及有关 UI 测试目标，优先检查搜索/删书、EPUB 目录、TXT/EPUB 排版与关于页；用同一组合成书对照普通字号与大字。未改动的阅读内核和文件选择器不作为本轮默认回归范围。
2. **书架筛选与同名删书**：
   - 导入两本同名书（如两本 TXT 或一 TXT 一 EPUB），核对画廊/编目/案头续读卡上的「同名副本」信息条不换行错乱、不截断书名。
   - 输入书名或切换 TXT/EPUB 筛选，核对视图切换为「匹配结果」而非「案头续读」；清空后无闪烁恢复案头续读。
   - 长按触发删除弹窗，核对同名提示、副本事实行与 `取消 / 删除` 布局在窄屏与大字下完整可读。
3. **EPUB 目录收束**：
   - 验证首屏章节露出数量提升，核对窄屏下 `筛选框 + 当前` 单行不挤压输入框、输入文字后平滑切换为纵向全宽「清空筛选并定位当前章节」。
   - 验证切后台/失效态下朱砂恢复卡片与 `epub.directory.recover` 清晰可见。
4. **常驻活页书样与最大字号边界**：
   - 在 TXT / EPUB 设置 `.large` 面板下将字号调至 `36`、行距调至 `20`，确认顶部常驻 `ReaderTypographyPreview` 下方的 `ScrollView` 仍有充裕可视高度，且滑动选择底部 `EPUBUserFontPicker` 字体或切换 3 种纸色时预览即时刷新。
   - 拖动面板至 `.medium` 档位、旋转横屏、以及开启 `AccessibilityXXXL` 超大字体时，确认样张自动回落至 `ScrollView` 内，不遮挡控件。
5. **设置与关于 / 深色 / 墨夜 / 减少动态 / VoiceOver**：
   - 在「清朗 / 柔雾 / 墨夜」× 浅色/深色系统下核对 `关于阅境` 60pt 图标卡对齐、开发者模式开启后的朱砂视觉区分及 VoiceOver 焦点顺序。
   - 确认开启「减弱动态效果」时筛选切换、外观选态与面板切换均无多余位移或弹性动画。
