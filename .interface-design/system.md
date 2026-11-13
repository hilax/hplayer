# HPlayer 设计系统 · 暗房社论（Darkroom Editorial，3.0）

> 这份文件锁定全局视觉规则。代码里的唯一来源是 `ios-native/HPlayer/Views/Theme.swift`（颜色、间距、圆角、字号）
> 和 `Views/DesignComponents.swift`（按钮、输入框、行、筛选块、角标）。改规范 = 先改这里，再改那两个文件。
> 页面里不写色值、不写字号数字、不写圆角数字。

## 方向

- **谁在用**：晚上在暗处单手竖屏刷片的人。要的是「两步内找到下一部，接着看」，然后顺手管网盘。
- **感觉**：像一本影评刊物，或者暗房：暖黑和旧纸色打底，墨色 / 纸色当主操作，宋体标题，细线分栏。安静、有辨识度，不炫。
- **签名元素**：宋体栏目标题 + 线分栏；排名用铜金色的衬线斜体数字；整个界面只有一种褪了色的朱砂。
- **拒绝的默认做法**：彩色「金刚区」快捷入口 → 单色线框；渐变光轨 → 实色细线；卡片投影 → 底色深浅 + 细线；胶囊按钮 → 8pt 圆角矩形。

## 深度策略：底色深浅 + 细线，不用投影

- 层级：页面 → 卡片 → 弹层 → 控件，同一暖色相，每级只差几个百分点的明度。
- 卡片：`surface` + 0.5pt `hairline`（`.surfaceCard()`）。
- 浮层（轻提示、浮动操作栏、操作中卡片）：`surfaceRaised` + 1pt `rule`（`.floatingSurface()`）。
- `Theme.shadow` 两种模式都是透明，旧调用处保留但不再出投影。
- 例外：浮在视频 / 封面上的玻璃控件仍用系统材质（Liquid Glass / 毛玻璃），保持胶囊形。

## 颜色 Token

| Token | 深色 | 浅色 | 用途 |
|---|---|---|---|
| `pageBackground` | `#15120F` | `#F5F0E7` | 页面底 |
| `surface` | `#1E1A16` | `#FBF8F2` | 卡片、分组、次按钮底 |
| `surfaceRaised` | `#28231E` | `#ECE5D8` | 弹层、轻提示、封面占位 |
| `surfaceHigh` | `#332D26` | `#E3DACB` | 分段选中块、控件底 |
| `inputFill` | `#100D0B` | `#EDE6DA` | 输入框（比周围略深） |
| `textPrimary` | `#F1EAE0` | `#1C1814` | 正文 |
| `textSecondary` | `#B4AA9C` | `#5C5348` | 次要文字 |
| `textTertiary` | `#978C7F` | `#6B6155` | 数量、注释（≥ 4.5:1） |
| `textMuted` | `#6E655A` | `#A39886` | 不可用、占位（刻意不达正文对比度） |
| `hairline` | 纸 9% | 墨 10% | 卡片外沿、封面描边、输入框 |
| `rule` | 纸 13% | 墨 14% | 分隔线、浮层边 |
| `ruleStrong` | 纸 24% | 墨 26% | 未选中勾选圈、描边标签 |
| `track` | 纸 12% | 墨 10% | 进度、开关轨道 |
| `tileTint` / `pressTint` | 纸 7% / 10% | 墨 5% / 8% | 选中行淡底 / 按下薄层 |
| `primaryAction`（= `gold`） | 纸 `#F1EAE0` | 墨 `#1C1814` | 每屏唯一的主按钮、选中块、勾选 |
| `onPrimary` | `#15120F` | `#FBF8F2` | 主操作色上的字 |
| `accent` / `accentFill` | `#CF8770` | `#9A4C37` | 褪色朱砂：更新、在看、进行中、焦点环 |
| `onAccentFill` | `#15120F` | `#FBF8F2` | 朱砂实心上的字 |
| `brass`（= `rating` = `warning`） | `#C9A26B` | `#7C5A2A` | 评分、排名数字、警告 |
| `success` | `#7FB685` | `#356B41` | 完成 |
| `danger` / `dangerFill` | `#EF6A5B` / `#B3412F` | `#B3261E` | 危险文字 / 危险按钮底（白字） |
| `Source.*` | 灰蓝 / 灰紫 / 灰绿 | 同色相加深 | 来源色点，只区分类别 |
| `ink` / `paper` | `#15120F` / `#F1EAE0` | 同左 | 不随模式变：播放页、封面上的控件 |

规则：
- **60 / 30 / 10**：大面积是纸 / 墨，线和次要文字是结构，朱砂不超过一屏的 10%。
- 朱砂只做文字、细线、小实心角标，不做大面积底色；同一屏最多一处朱砂实心。
- 评分和排名只用铜金。不再用渐变做装饰（`prismGradient` / `accentGradient` 已改成朱砂实色），棱镜五色只留给品牌标志和弹幕取色。
- 所有正文、次要、三级文字在页面 / 卡片 / 弹层三种底上都 ≥ 4.5:1（两种模式都核算过）。

## 字体与字号阶梯（全部跟随系统字号）

| Token | 字体 | 默认字号 | 用途 |
|---|---|---|---|
| `Typo.pageTitle` | 宋体 Bold | 30（largeTitle 缩放） | 一级页面大标题 |
| `Typo.detailTitle` | 宋体 Bold | 26（title 缩放） | 详情页片名 |
| `Typo.section` | 宋体 Bold | 20（title3 缩放） | 栏目 / 货架标题 |
| `Font.display(_:)` | 宋体 Bold | 调用处给定 | 其余标题字、统计数字 |
| `Font.numeral(_:)` | New York 斜体 semibold | 调用处给定 | 排名、序号（配铜金） |
| `Typo.headline` | 苹方 / SF semibold | 17 | 卡片标题 |
| `Typo.body` | 苹方 / SF | 17 | 正文、输入框 |
| `Typo.row` / `Typo.button` | 苹方 / SF | 15 / 15 semibold | 列表行、按钮 |
| `Typo.meta` | 苹方 / SF | 13 | 辅助信息、行尾数值 |
| `Typo.caption` | 苹方 / SF | 12 | 卡片下的小字 |
| `Typo.badge` | 苹方 / SF semibold | 11 | 封面角标（全应用最小字号） |

- 宋体（`STSongti-SC-Bold`）是苹果的按需下载字体：`EditorialFont.prepare()` 在启动时激活 / 下载，没就绪前回落到系统衬线体。
- 宋体只用在标题时刻；正文、控件、数字一律系统字体。
- 字重最多到 semibold；不再用 `.black` / `.heavy`。
- 时间、集数、容量、数量一律 `.monospacedDigit()`。
- 不写 `.system(size:)` 固定字号给文字（图标的 `.system(size:weight:)` 可以）。

## 间距（4pt 网格，`Theme.Space`）

`hair 2 · xs 4 · sm 8 · md 12 · lg 16 · page 20 · xl 24 · section 32 · shelf 40`

- 页面左右边距 `page` 20（`Theme.contentInset`）。
- 卡片内边距 `lg` 16；卡片 / 网格间隙 `md` 12；分组之间 `xl` 24；首页货架之间 `shelf` 40。
- 列表行：最小 56 高，左右 16，图标列 24，分隔线从标题处开始（`LibraryActionRow.dividerInset` = 54）。
- 疏密有节奏：组内紧（4–8），组间松（24–40），不要处处同一个间距。

## 圆角（`Theme.Radius`）

`badge 3 · poster 4 · chip 6 · control 8 · tile 8 · card 12 · sheet 16`

- 按钮、输入框是 8pt 圆角矩形，不用胶囊。玻璃控件（浮在画面上）例外，保持胶囊 / 圆形。
- 嵌套：外层 = 内层 + 内边距（例：分段控件外框 9 = 选中块 6 + 3）。

## 交互状态（所有控件同一套）

| 状态 | 表现 |
|---|---|
| 默认 | 墨 / 纸 / 线，最多一处朱砂 |
| 按下 | 同色 12% 薄层 + 缩到 0.97–0.98，不改布局；减少动态效果时只变明度 |
| 悬停（iPad 指针） | `.hoverEffect(.highlight)` |
| 焦点 | 输入框边线 0.5pt `hairline` → 1pt 朱砂，标签字变朱砂；按钮用系统焦点环 |
| 不可用 | 底色退成 `tileTint`、文字退成 `textMuted`；`.pressable` 整体 45% |
| 选中 | 墨 / 纸实心块（筛选块、勾选）；分段控件是 `surfaceHigh` 块 + 正文色 |

- 点按区域至少 44pt：筛选块看上去 32pt，点按区域上下各扩 6pt（左右不扩，相邻的不会互相抢点按）。
- 动效：点按 `Motion.quick` / `Motion.snappy`，面板 `Motion.smooth`，都 < 0.5 秒，不做循环动画。

## 组件规格

| 组件 | 规格 |
|---|---|
| `PrimaryActionStyle` | 48 高 · 8 圆角 · 15 semibold · 墨底纸字（深色反相） |
| `SecondaryActionStyle` | 46 高 · 8 圆角 · 15 medium · `surface` 底 + 1pt `rule` |
| `FooterButtonStyle` | 50 高，主 / 次同上 |
| `DestructiveActionStyle` | 50 高 · `dangerFill` + 白字 |
| `GlassCapsuleButton` | 浮在画面上的胶囊；主款墨 / 纸实心，无投影 |
| `DesignField` | 标签 13 medium · 输入区 48 高 · `inputFill` · 8 圆角 · 焦点 1pt 朱砂 |
| `ChannelSearchField` / `MagnetSearchField` | 40 高 · `.fieldChrome()` |
| `SelectionPill` | 32 高（点按 44）· 6 圆角 · 选中墨 / 纸实心 |
| `CountSegmentedControl` | 外框 9 圆角 + 细边，选中块 6 圆角 `surfaceHigh` |
| `TagBadge` | 18 高 · 3 圆角 · 11 semibold · 四种：`onArtwork` / `accent` / `neutral` / `outline` |
| `RatingBadge` / `EpisodeCountBadge` | `TagBadge(.onArtwork)`；评分字用 `ratingOnArtwork` |
| `.surfaceCard()` / `DesignGroup` | `surface` · 12 圆角 · 0.5pt `hairline` |
| `.floatingSurface()` | `surfaceRaised` · 12 圆角 · 1pt `rule`（轻提示、操作中、浮动操作栏用 16） |
| `.designSheet()` | 自定义底部面板：`surface` 底 · 16 圆角 · 拖动条 |
| `OperationOverlay` | `scrim` 48% + `floatingSurface` 卡片 |
| `ThinProgressBar` / `GlassProgressBar` | 4pt / 3pt 朱砂实色，暂停变灰 |
| `ProgressRing` | 4pt 朱砂环 |
| `LibraryActionRow` | 56 高 · 15 行标题 · 13 等宽数值（高亮为朱砂）· 13 chevron（`textMuted`） |
| `RowDivider` | 0.5pt `rule`，从标题处开始 |

## 还没迁移的（下一阶段，页面级）

- 页面里仍有约 250 处 `.system(size:)` 固定字号、12 种写死的圆角、零散的黑白半透明 → 逐页换成上面的 token。
- 彩色快捷入口（`ShortcutTint`）、首页货架卡片样式收敛、「网盘」「我的」自绘标题栏换系统大标题 → 页面重构时处理。
