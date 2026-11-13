# HPlayer 设计系统 · 放映厅（Screening Room，3.0 · 方案 A）

> 这份文件锁定全局视觉规则。代码里的唯一来源是 `ios-native/HPlayer/Views/Theme.swift`（颜色、间距、圆角、字号）
> 和 `Views/DesignComponents.swift`（按钮、输入框、行、筛选胶囊、角标）。改规范 = 先改这里，再改那两个文件。
> 页面里不写色值、不写字号数字、不写圆角数字。
>
> 备选方向「暗房社论」（方案 B：暖黑旧纸、宋体标题、朱砂强调）的完整实现在提交 `eb6c011`，需要时可以切回。

## 方向

- **谁在用**：晚上在暗处单手竖屏刷片的人。要的是「两步内找到下一部，接着看」，然后顺手管网盘。
- **感觉**：克制精密的现代工作台（Linear / Apple TV 一路）。石墨灰阶承载内容，主操作是白 / 墨，层级靠字重和明度，而不是字号和颜色。
- **签名元素**：整个界面基本是灰阶，唯一亮起来的是琥珀——观看进度线、「在看 / 更新」、进行中的数量。像暗场里只有放映机那一束光。
- **拒绝的默认做法**：彩色「金刚区」快捷入口 → 单色线框；渐变光轨 → 琥珀实色细线；卡片投影 → 底色深浅 + 细线；多种强调色 → 只有琥珀。

## 深度策略：底色深浅 + 细线；只有浮层在浅色模式下带轻投影

- 层级：页面 → 卡片 → 弹层 → 控件，中性灰，每级只差几个百分点的明度。
- 卡片：`surface` + 0.5pt `hairline`（`.surfaceCard()`），不用投影（`Theme.shadow` 两种模式都是透明）。
- 浮层（轻提示、浮动操作栏、操作中卡片）：`surfaceRaised` + 0.5pt `rule`，浅色模式加 `floatShadow`（y 8 · 模糊 24 · 12%），深色模式不加（`.floatingSurface()`）。
- 浮在视频 / 封面上的玻璃控件仍用系统材质（Liquid Glass / 毛玻璃），保持胶囊 / 圆形。

## 颜色 Token

| Token | 深色 | 浅色 | 用途 |
|---|---|---|---|
| `pageBackground` | `#0A0A0B` | `#F7F7F8` | 页面底 |
| `surface` | `#141416` | `#FFFFFF` | 卡片、分组、次按钮底 |
| `surfaceRaised` | `#1C1C1F` | `#EFEFF1` | 弹层、轻提示、封面占位 |
| `surfaceHigh` | `#26262A` | `#E6E6E9` | 分段选中块、控件底 |
| `inputFill` | `#060607` | `#EFEFF1` | 输入框（比周围略深） |
| `textPrimary` | `#EDEDEF` | `#111113` | 正文 |
| `textSecondary` | `#A1A1AA` | `#52525B` | 次要文字 |
| `textTertiary` | `#85858E` | `#62626B` | 数量、注释（页面 / 卡片 / 弹层上 ≥ 4.5:1） |
| `textMuted` | `#5A5A62` | `#A1A1AA` | 不可用、占位（刻意不达正文对比度） |
| `hairline` | 白 7% | 黑 8% | 卡片外沿、封面描边、输入框 |
| `rule` | 白 10% | 黑 10% | 分隔线、浮层边、次按钮外框 |
| `ruleStrong` | 白 20% | 黑 22% | 未选中勾选圈、描边标签 |
| `track` | 白 12% | 黑 10% | 进度、开关轨道 |
| `tileTint` / `pressTint` | 白 6% / 8% | 黑 5% / 7% | 选中行淡底 / 按下薄层 |
| `primaryAction`（= `gold`） | 白 `#F5F5F6` | 墨 `#111113` | 每屏唯一的主按钮、选中胶囊、勾选 |
| `onPrimary` | `#0A0A0B` | 白 | 主操作色上的字 |
| `accent` / `accentFill` | `#E6A54B` | `#8A6008` | 琥珀：进度、更新、在看、进行中、焦点 |
| `onAccentFill` | `#0A0A0B` | 白 | 琥珀实心上的字（9.3:1 / 5.6:1） |
| `rating` / `brass` | 同 `accent` | 同 `accent` | 评分、排名 |
| `success` | `#4CC38A` | `#16754D` | 完成 |
| `warning` | `#F0884B` | `#A84A16` | 警告 |
| `danger` / `dangerFill` | `#F2555A` / `#C9363D` | `#C42B33` | 危险文字 / 危险按钮底（白字 ≥ 5:1） |
| `Source.*` | 灰蓝 / 灰紫 / 灰绿 | 同色相加深 | 来源色点，只区分类别 |
| `ink` / `paper` | `#0A0A0B` / `#F5F5F6` | 同左 | 不随模式变：播放页、封面上的控件 |

规则：
- **60 / 30 / 10**：大面积是石墨灰，线和次要文字是结构，琥珀不超过一屏的 10%。
- 琥珀只做进度、文字、细线、小实心角标，不做大面积底色；同一屏最多一处琥珀实心。
- 不再用渐变做装饰（`prismGradient` / `accentGradient` 已改成琥珀实色），棱镜五色只留给品牌标志和弹幕取色。
- 所有正文、次要、三级文字在页面 / 卡片 / 弹层上都 ≥ 4.5:1（两种模式都核算过）。

## 字体与字号阶梯（只用系统字体，全部跟随系统字号）

| Token | 字重 | 默认字号 | 用途 |
|---|---|---|---|
| `Typo.pageTitle` | bold | 34（largeTitle） | 一级页面大标题 |
| `Typo.detailTitle` | bold | 22（title2） | 详情页片名 |
| `Typo.section` / `Typo.headline` | semibold | 17（headline） | 栏目 / 货架标题、卡片标题 |
| `Font.display(_:)` | bold | 调用处给定，按最接近的文字样式缩放 | 其余标题字、统计数字 |
| `Font.numeral(_:)` | semibold + 等宽数字 | 调用处给定 | 排名、序号 |
| `Typo.body` | regular | 17 | 正文、输入框 |
| `Typo.row` / `Typo.button` | regular / semibold | 15 | 列表行、按钮 |
| `Typo.meta` | regular | 13 | 辅助信息、行尾数值 |
| `Typo.caption` | regular | 12 | 卡片下的小字 |
| `Typo.badge` | semibold | 11 | 封面角标（全应用最小字号） |

- 字体：中文苹方，西文 SF Pro。
- 层级优先靠字重和颜色（同一字号分 semibold / 主色、medium / 次要色、regular / 三级色），而不是字号差两三档。
- 字重最多到 bold；不再用 `.black` / `.heavy`。
- 时间、集数、容量、数量一律 `.monospacedDigit()`；番号、哈希用等宽字体。
- 不写 `.system(size:)` 固定字号给文字（图标的 `.system(size:weight:)` 可以）。

## 间距（4pt 网格，偏紧凑，`Theme.Space`）

`hair 2 · xs 4 · sm 8 · md 12 · lg 16 · page 16 · xl 24 · section 32 · shelf 32`

- 页面左右边距 16（`Theme.contentInset`）。
- 卡片内边距 16；卡片 / 网格间隙 10–12；标题到内容 8；分组之间 24；首页货架之间 32。
- 列表行：最小 52 高，左右 16，图标列 24，分隔线从标题处开始（`LibraryActionRow.dividerInset` = 54）。

## 圆角（`Theme.Radius`）

`badge 4 · poster 8 · chip 8 · control 10 · tile 10 · card 14 · sheet 20`，主按钮、危险按钮、筛选块是胶囊（`Capsule`）。

- 次按钮、输入框是 10pt 圆角矩形。
- 嵌套：外层 = 内层 + 内边距（例：分段控件外框 11 = 选中块 8 + 3）。

## 交互状态（所有控件同一套）

| 状态 | 表现 |
|---|---|
| 默认 | 灰阶 + 白 / 墨主操作，最多一处琥珀 |
| 按下 | 同色 12% 薄层 + 缩到 0.97–0.98，不改布局；减少动态效果时只变明度 |
| 悬停（iPad 指针） | `.hoverEffect(.highlight)` |
| 焦点 | 输入框边线 0.5pt `hairline` → 1pt 琥珀，标签字变琥珀；按钮用系统焦点环 |
| 不可用 | 底色退成 `tileTint`、文字退成 `textMuted`；`.pressable` 整体 45% |
| 选中 | 白 / 墨实心胶囊（筛选、勾选）；分段控件是 `surfaceHigh` 块 + 正文色 |

- 点按区域至少 44pt：筛选胶囊看上去 32pt，点按区域上下各扩 6pt（左右不扩，相邻的不会互相抢点按）。
- 动效：点按 `Motion.quick` / `Motion.snappy`，面板 `Motion.smooth`，都 < 0.5 秒，不做循环动画。

## 组件规格

| 组件 | 规格 |
|---|---|
| `PrimaryActionStyle` | 48 高 · 胶囊 · 15 semibold · 白底墨字（浅色反相） |
| `SecondaryActionStyle` | 46 高 · 10 圆角 · 15 medium · `surface` 底 + 1pt `rule` |
| `FooterButtonStyle` | 50 高，主 / 次同上 |
| `DestructiveActionStyle` | 50 高 · 胶囊 · `dangerFill` + 白字 |
| `.secondaryDestructive` | 46 高 · 10 圆角 · `surface` 底 + 1pt `rule` · 红字 |
| `SettingsSection` / `SettingRow` | 小标题 + 卡片 + 可选脚注；行 52 高，图标 + 标题 + 右侧控件 |
| `GlassCapsuleButton` | 浮在画面上的胶囊；主款白 / 墨实心，无投影 |
| `DesignField` | 标签 13 medium · 输入区 48 高 · `inputFill` · 10 圆角 · 焦点 1pt 琥珀 |
| `ChannelSearchField` / `MagnetSearchField` | 40 高 · `.fieldChrome()` |
| `SelectionPill` | 32 高（点按 44）· 胶囊 · 选中白 / 墨实心 |
| `CountSegmentedControl` | 外框 11 圆角 + 细边，选中块 8 圆角 `surfaceHigh` |
| `TagBadge` | 18 高 · 4 圆角 · 11 semibold · `onArtwork` / `accent` / `neutral` / `outline` |
| `RatingBadge` / `EpisodeCountBadge` | `TagBadge(.onArtwork)`；评分字用 `ratingOnArtwork`（琥珀） |
| `.surfaceCard()` / `DesignGroup` | `surface` · 14 圆角 · 0.5pt `hairline` |
| `.floatingSurface()` | `surfaceRaised` · 14 圆角 · 0.5pt `rule` · 浅色模式轻投影（浮动操作栏 20） |
| `.designSheet()` | 自定义底部面板：`surface` 底 · 20 圆角 · 拖动条 |
| `OperationOverlay` | 50% 黑遮罩 + `floatingSurface` 卡片 |
| `ThinProgressBar` / `GlassProgressBar` | 4pt / 3pt 琥珀实色，暂停变灰 |
| `ProgressRing` | 4pt 琥珀环 |
| `LibraryActionRow` | 52 高 · 15 行标题 · 13 等宽数值（高亮为琥珀）· chevron `textMuted` |
| `RowDivider` | 0.5pt `rule`，从标题处开始 |

## 全局约束（3.0 第二步起）

- **字号**：页面里所有写死的字号都走 `Font.scaled(_:weight:design:)`：默认字号下大小不变，随系统「更大字体」放大（封顶 1.4 倍，免得固定尺寸的控件被撑破），最小 11pt，heavy / black 自动降成 bold。新代码优先用 `Theme.Typo`。弹幕文字例外（大小是用户自己调的）。
- **圆角**：页面里不再写数字，一律 `Theme.Radius.*`。
- **叠在画面上的黑 / 白半透明**只用 `Theme.Opacity` 这几档：`hint 0.08 · faint 0.15 · soft 0.25 · medium 0.4 · strong 0.6 · heavy 0.75 · solid 0.9`。
- **色值**只出现在 `Theme.swift`（外观预览图的两套固定色在 `Theme.Preview`）；封面取色这类运行时算出来的颜色除外。
- **快捷入口**单色：未选中极淡灰底 + 正文色线框图标，选中白 / 墨实心。
- **封面角标**一律 `TagBadge`：状态「更新」用 `.accent`，其余用 `.onArtwork`；轮播卡片的「精选 / 热播」也是 `.onArtwork`。一张封面最多两个角标。
- **列表不画分隔线**：行与行靠行高和留白分开（网盘文件列表、「我的」各组）。
- 栏目入口的文字统一是「全部 ›」。

## 首页卡片：只有三种

| 卡片 | 用在 | 规格 |
|---|---|---|
| 16:9 横卡 | 继续观看 | 168pt 宽，底部 3pt 琥珀进度线 |
| 2:3 竖海报 | 我的追番、热门新番（三列网格）、我的片库 · 电影、剧集、最新更新 | 货架里 108pt 宽；片名 13 medium、副标题 11；角标最多两个 |
| 演员合集 | 演员合集 | 两张 2:3 海报并排，216pt 宽，高度和 108pt 竖海报一致 |

- 横滑货架和网格只是排法不同，卡片本身是同一种。
- 3.0 起「我的片库 · 电影」从两列 16:9 横卡改成竖海报货架。

## 页面模式：一级页面的大标题

- 一级页面（网盘、我的）顶部是 34pt 粗体大标题，随内容一起滚动；滚出屏幕后顶部出现 `CompactTitleBar`（系统材质底 + 细线 + 居中 17pt 标题 + 右侧图标按钮），和系统导航栏的大标题收起效果一致。
- 用法：大标题加 `.scrolledAway($titleAway)`，页面加 `.overlay(alignment: .top) { CompactTitleBar(title:visible:) }`。紧凑栏里的按钮用另一组标识（如 `cloud.search.compact`），不和大标题里的重复。

## 网盘与「我的」的分工

- **网盘**管「存储」：账号条（名字、连接状态、容量条）、四格快捷入口（传输中心、离线下载、本机视频、回收站）、根目录文件。容量只在这里显示。
- **我的**管「身份和偏好」：头像、名字、连接状态、切换 / 退出；然后是播放、弹幕、外观、媒体库、关于。追番在动漫频道、观看记录在首页「继续观看」、容量和传输中心在网盘页，「我的」都不重复。
- 「传输中心」只在网盘页（快捷入口第一格），「我的」不再重复。
- **播放**组直接读写播放器已有的偏好（自动连播、回到桌面时自动小窗、字幕样式、边播边存、解码方式）；**弹幕**组只放开关，「弹幕样式」推进单独一页（16:9 实时预览 + 显示区域 + 不透明度 / 字号 / 速度）。都从下一次打开播放器开始生效，不碰播放器内核。
- 二级页面一律从右侧推入公共导航栈、用系统返回键（媒体库管理也是，不再全屏弹出）；设置类页面用 `SettingsSection` + `SettingRow` / `LibraryActionRow`，开关是系统开关（琥珀），下拉是系统菜单。
- 次要的危险操作（删除凭证、清空记录）用 `ActionButtonStyle(kind: .secondaryDestructive)`：次按钮外形 + 红字。

## 还没迁移的（下一阶段，页面级）

- 其余页面的字号已经能随系统缩放，但还没有逐个换成 `Theme.Typo` 的语义 token。
