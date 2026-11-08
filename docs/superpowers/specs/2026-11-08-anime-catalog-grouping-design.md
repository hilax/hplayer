# 动漫共和国 首页分组与详情页版式对齐 设计规格

- **日期**：2026-11-08
- **状态**：已评审并实现
- **参考**：原 App 频道页截图（推荐/日漫/国漫/剧场 分组货架）、`SeriesDetailView.swift`
- **前置说明**：先前提出的「动漫 × 网盘融合」方案已暂停，本文档只覆盖首页分组与详情页版式。

---

## 1. 背景与目标

动漫首页此前是一条「全部番剧」无尽瀑布流，线上共 7287 部，首屏一次性铺开后用户很难找到想看的作品。详情页与 App 内的剧集详情页是两套观感，选集格子也缺少观看进度信息。

本次改动两个目标：

1. 首页改成参考图那样的**分组货架**结构，把「几千部往下翻不完」变成「几屏 curated 货架」。
2. 详情页**对齐剧集详情页的视觉规格**，让选集格子带上进度、看完标记与当前集高亮。

---

## 2. 关键决策

| 决策 | 结论 | 理由 |
|---|---|---|
| 热门新番栏目 | **保留**，排在轮播之下、频道货架之上 | 用户明确要求保留 |
| 详情页复用深度 | **只对齐视觉，不动 `SeriesDetailView`** | 剧集页已上线且有 UI 测试覆盖，零回归风险优先 |
| 货架「查看更多」字体 | 复用 `ShelfLinkLabel` | 与首页电影/剧集货架的「全部」完全同规格 |
| 频道页年份/类型筛选 | **不做** | 接口不支持，见 §3 |

---

## 3. 接口边界（实测确认）

`GET /app/video/list` 只支持四个参数：`channel`、`sort`（`weight` / `addtime`）、`limit`、`page`。
**没有年份与类型筛选参数**，因此频道页只提供排序切换，不提供年份/类型胶囊。

用到的接口：

- `GET /app/channel?top-level=true` → 频道列表（推荐页的 tab 与货架来源）
- `GET /app/banners` → 轮播
- `GET /app/video/list?sort=weight&limit=12&page=1` → 热门新番（全库权重排序）
- `GET /app/video/list?channel={id}&sort=weight&limit=6&page=1` → 单个频道的推荐货架
- `GET /app/video/list?channel={id}&sort={sort}&limit=18&page={n}` → 频道页分页网格

---

## 4. 首页结构

### 4.1 频道标签栏

`AnimeChannelBar` 从胶囊行改为**横向标签 + 金色滑条**：

- 第一项固定为「推荐」（`selectedChannelId == nil`），其后是接口返回的各频道
- 选中项：15pt 粗体 + `Theme.textPrimary`；未选中：15pt 常规 + `Theme.textTertiary`
- 下方 22×3pt 金色 Capsule，用 `matchedGeometryEffect` 在标签间平移
- 标识符：`anime.channel.recommend` / `anime.channel.{id}`

### 4.2 推荐页（默认）

顺序：**轮播 → 热门新番 → 推荐·日漫 → 推荐·国漫 → 推荐·剧场 → 其余频道货架**

- 热门新番：全库 `sort=weight&limit=12`，右侧显示「共 12 部」计数（不设跳转，避免造出一个没有返回路径的死胡同页）
- 频道货架：各取 6 部，右侧「查看更多」点击后切到对应频道 tab
- 货架标题用 `ShelfHeader`（18pt 粗体系统字）
- 「查看更多」用 `ShelfLinkLabel(text: "查看更多")`：`.font(.caption)`（12pt 常规）+ `.secondaryTextStyle()`（次要灰，**不是金色**）+ 10pt 粗体箭头，44pt 点击区，`.pressable(scale: 0.92)`

### 4.3 加载策略

- 首屏并发：频道列表、轮播、热门新番、**前 3 个**频道货架
- 其余频道货架在滚动到可见时（`onAppear`）才拉，用 `loadingShelves` 去重
- 货架拉取失败时写入空数组，避免每次滚过来都重试
- 各板块独立 `try?`，单个失败不影响其他板块

### 4.4 频道页

- 排序胶囊：最新上架（`addtime`）/ 推荐权重（`weight`），右侧「共 N 部」
- 固定列宽网格（按屏宽计算，沿用 `gridMetrics`），触底翻页
- 切 tab 或切排序时 `loadGeneration += 1`，迟到的旧请求直接丢弃
- 翻页按 id 去重，防止 `addtime` 排序下新番插入导致的重复条目

---

## 5. 详情页版式对齐

内容顺序与剧集页一致：**抬头 → 简介 → 主按钮 → 选集**。

| 元素 | 规格（对齐 `SeriesDetailView`） |
|---|---|
| 元信息行 | 13pt semibold + `Theme.textSecondary` |
| 类型胶囊 | 11pt medium、22pt 高、`Theme.tileTint` 底 + `Theme.accent` 字 |
| 简介 | 直接铺在页面上（去掉卡片包装），14pt、`lineSpacing(4)`、默认 3 行、「更多/收起」14pt semibold accent |
| 主按钮 | `Label` + `AppIcon.play`、`Capsule`、48pt 高、`.pressable(scale: 0.97)`、标识 `anime.play` |
| 选集标题 | `ShelfHeader(title: "选集", inset: 0)` + 「共 N 集」12pt 三级色 + 正序/倒序双胶囊 |
| 线路胶囊 | `SelectionPill`（与剧集页的「季」同一个组件），文案「日语 · 6 集」 |
| 选集格子 | 48pt 高、`Theme.Radius.tile`、数字 16pt semibold 等宽 |
| 当前集 | 整块填 `Theme.gold`，文字 `Theme.onPrimary` |
| 看完（≥92%） | 文字置三级灰 + 右上角 `AppIcon.check` 8pt bold |
| 看到一半 | 底部金色进度线：2pt 高、左侧 inset 8、宽度 `max(4, (w-16)*progress)` |
| 底部说明 | 「第06集 · 看到 12:30」或「第06集 · 已看完」，12pt 三级色 |

`SeriesDetailView.swift` **一行未改**。

---

## 6. 观看进度数据（含一个 bug 修复）

### 6.1 为什么不能用 URL 查进度

动漫解析出的流地址带时效签名，每次解析都不同。`RecentStore` 原本用 URL 做 key，导致按 URL 查单集进度必然落空——**这也是动漫续播位置偶尔丢失的根因**。

改为按稳定标题 `"{番剧名} {第XX集}"` 精确匹配，新增：

```swift
func animeEpisode(title: String) -> RecentItem?
```

`items` 已按最近播放排序，`first` 即最近一次。用完整标题精确匹配而非 `contains`，避免「第1集」误配「第10集」。

**取舍**：同名番剧理论上会撞（极罕见）；线路不进标题，所以换线路共享同一集进度（这个行为合理）。

### 6.2 看完标记

`savePosition` 在片尾（`seconds > duration - 30` 或 `> 95%`）会清掉 `position`，所以「看完」无法从进度推断。新增：

```swift
var finished: Bool? = nil   // 可选，兼容旧记录
```

- 片尾判定 → `finished = true`，同时清 `position`（下次从头播）
- 开头就退出（`< 10s`）→ 不标记看完
- 选集格子：`finished == true` 时进度按 1 处理，显示打勾

声明为可选类型是为了让旧版本写入的播放记录仍能解码，升级后历史不丢。

---

## 7. 改动文件

**改**：
- `Views/AnimeCatalogView.swift` — 重构为推荐页 + 频道页两种模式
- `Views/AnimeComponents.swift` — 频道标签栏、选集格子升级
- `Views/AnimeDetailView.swift` — 版式对齐、进度查询
- `Services/RecentStore.swift` — `animeEpisode(title:)`、片尾标记
- `Models/PlaybackSource.swift` — `RecentItem.finished`

**不动**：`SeriesDetailView.swift`、`DesignComponents.swift`（只复用）、`AnimeClient.swift`（现有接口够用）

---

## 8. 验证

- `python3 ios-native/scripts/check-icons.py` 通过
- iOS 模拟器构建 `BUILD SUCCEEDED`
- 全量单元测试 **348 项通过**，其中本次新增 3 项：
  - 旧播放记录（无 `finished` 字段）仍能解码
  - 看完记录无续播位置但带标记
  - 倒序稳定性与集数标题精确匹配

真机上的货架滚动手感与进度条显示仍需安装 IPA 后确认。
