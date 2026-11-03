# HPlayer 界面规范（2.0 重构）

所有页面的颜色、图标、动效都从下面几处取值，页面里不再自己写颜色值、图标名字和动画参数。改规范就是改全应用。

| 要改什么 | 改哪里 |
|---|---|
| 颜色、圆角、字号字重 | `Views/Theme.swift` |
| 图标 | `Views/Icons.swift`（`AppIcon`） |
| 动画、触感、按压手感 | `Views/Motion.swift` |
| 标题行、分组、按钮、筛选胶囊等通用控件 | `Views/DesignComponents.swift` |
| 底部标签栏与二级页面隐藏标签栏 | `Views/AppTabBar.swift` |

## 配色

深色是主风格：黑曜石底 + 琥珀金强调，像院线海报。浅色是同一套色相的暖白版本，全部用 `UIColor.adaptive` 随系统切换。

| 用途 | 深色 | 浅色 | 代码 |
|---|---|---|---|
| 页面底 | `#0B0C10` | `#F6F3ED` | `Theme.pageBackground` |
| 卡片 / 行 | `#15171D` | 白 | `Theme.surface` |
| 抬高一层 | `#1E2028` | `#EDE8DE` | `Theme.surfaceRaised` |
| 强调色（文字、线框图标） | `#E9B061` | `#B26A14` | `Theme.accent` |
| 主按钮底色 | `#E9B061` | 同左 | `Theme.gold` / `Theme.primaryAction` |
| 主按钮上的文字 | `#1A1206` | 同左 | `Theme.onPrimary` |
| 正文 / 次要 / 三级文字 | `#F2F3F5` / `#A1A6B3` / `#6B7080` | 对应的深色字 | `textPrimary / textSecondary / textTertiary` |

规则：

- 金色底上只放深色字（`onPrimary`），不放白字。
- 评分一律金色星标 + 数字；不用别的颜色表示评分。
- 圆角只有四档：海报 10、小块 12、卡片 16、弹层 24（`Theme.Radius`）。
- 片名和栏目大标题用衬线黑体 `Font.display(_:)`，其余用系统字体。

## 图标

1. 只用 SF Symbols 的**线框款**，字重统一 `Theme.iconWeight`（medium）。
2. **实心款只留给"正在发生 / 被选中"**：播放键、评分星、选中的底部标签、勾选圆圈。
3. **一个意思一个图标**：所有提醒是 `alert`，所有"更多"是 `more`，所有"完成"是 `success`，所有"关闭"是 `close`。
4. 页面里不写 `"xxx.fill"` 这样的字面量，一律 `AppIcon.xxx.name`。需要新图标就在 `Icons.swift` 加一个 case。
5. `ios-native/scripts/check-icons.py` 会在云端构建的第一步检查这条规则，违反就直接失败。
6. 列表行、工具卡、设置行的图标统一放在 `IconTile`（淡金底圆角方块 + 金色线框图标）里。

## 动效

1. **只用弹簧**：`Motion.snappy`（点按、选中）、`Motion.smooth`（面板、内容切换）、`Motion.bouncy`（勾选标记）。淡入淡出用 `Motion.fade`。
2. **不做无限循环**：循环动画会让自动化测试永远等不到界面空闲，也费电。
3. **打开"减少动态效果"时**，位移和缩放全部变成瞬间完成，只保留颜色变化。
4. 常用效果：
   - 按压：`.buttonStyle(.pressable)`，按下缩小并压暗，松手弹回。
   - 货架、网格、列表里的卡片依次浮现：`.reveal(index, id: 卡片id)`。这些容器会回收滑出屏幕的卡片，浮现记录放在 `RevealLedger`（视图外面），所以只有一组卡片刚出现的头半秒（第一屏）会播放浮现，滑回来或滑进来的卡片直接显示，快速滑动时不会出现格子消失又冒出来。固定的几块内容（不在懒加载容器里）才用不带 `id` 的 `.reveal(index)`。
   - 标签栏、筛选胶囊的选中底座在选项之间滑动（`matchedGeometryEffect`）。
   - 数字变化逐位滚动：`.rollingNumber()`；播放⇄暂停图标变形：`.morphSymbol()`；选中时图标弹一下：`.bounceSymbol(on:)`。
   - 勾选圆圈 `CheckBadge`、环形进度 `ProgressRing`。
   - 触感：`Haptics.tap()` / `select()` / `success()` / `warning()`。

## 页面结构

底部四个标签：**首页 / 片库 / 网盘 / 我的**，标签栏用系统原生 TabView：iOS 26 上是悬浮在屏幕底部的横向圆角 Liquid Glass 胶囊（页面内容从下面滚过、可左右拖动切换），较低版本是系统标准标签栏；选中色用琥珀色，图标用统一图标表。进入二级页面时用 `.hidesTabBar()`（系统的 `toolbar(.hidden, for: .tabBar)`）收起标签栏。搜索是从各页右上角进入的全屏页，不占标签位。

- 首页：精选轮播铺满屏幕上方，搜索 / 历史 / 添加三个圆形按钮悬浮在右上角 → 继续观看 / 电影 / 剧集 / 演员合集货架。
  - 翻页时图片停在原地，页面边缘像一扇窗从图上扫过去，片名跟着页面走（减少动态效果时改为普通平移）。
  - 首尾相接循环：第一张往右滑是最后一张，最后一张往左滑回到第一张（首尾各放一张复制页，停稳后无动画换回真页，见 `HeroLoop`）。
  - 整页底色是当前精选封面的取色（画面平均色，明度、饱和度封顶，保证白字清楚），横幅下半截先柔化再融进这个颜色；翻过一半时整页颜色用 `Motion.artworkFade`（0.3 秒）过渡。首页内容固定按深色显示，浅色模式下也一样。实现见 `Views/HomeHeroMotion.swift`。
- 片库：类型 / 地区 / 年份 / 排序四行筛选 + 海报网格。
- 网盘：115 账号卡片、四个工具（磁力播放、BT 云下载、本机视频、媒体库管理）、进入网盘文件。
- 我的：账号卡片、统计、媒体库 / 外观 / 关于三组设置。
- 播放器：竖屏是顶部 16:9 小窗（返回、截图、更多、播放、进度、全屏）+ 下方信息页（片名、清晰度/倍速/字幕/画面/解码快捷格、选集横条、接下来、文件信息）；点全屏转横屏，画面铺满，右侧面板分「选集 / 倍速 / 清晰度 / 字幕音轨」四页，选集页带自动连播开关。默认直接横屏播放，点退出全屏键回到竖屏小窗。播放器放在独立的 UIWindow 里（`PlayerWindow`）：主窗口只支持竖屏，播放器窗口才真的横屏，所以控制中心、录屏、系统弹窗方向和旋转锁定都按真实横屏走，其他页面一直是竖屏；关闭时播放页柔和淡出并轻轻缩小后移除窗口，没有翻转，也不用遮罩。所有打开播放器的地方统一用 `.playerWindow(...)`，不要再用 `fullScreenCover`。
- 进入详情、演员合集、网盘目录、设置子页等二级页面时，标签栏自动收起（`.hidesTabBar()`）。

## 新增页面时

1. 用 `DesignPage` / `ScreenTitleBar` / `DesignGroup` / `LibraryActionRow` / `PrimaryActionStyle` 搭，不要自己写背景和字号。
2. 图标只从 `AppIcon` 取；弹层右上角用 `SheetCloseButton`。
3. 列表和网格里的卡片加 `.reveal(index, id: 卡片id)`（一定要带 id），可点的东西加 `.buttonStyle(.pressable)`。
4. 二级页面加 `.hidesTabBar()`；页面根视图加 `.designScreen("名字")`，并在 `docs/prototype-coverage.json` 和 `ScreenCatalogUITests` 里登记。
