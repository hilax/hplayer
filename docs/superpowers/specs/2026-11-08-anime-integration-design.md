# HPlayer 果果动漫 (动漫共和国) 集成设计规格书

- **日期**：2026-11-08
- **状态**：已评审并确认 (Approved)
- **文档编号**：SPEC-20261108-ANIME-INTEGRATION
- **参考依据**：`/Users/hilax/Desktop/Mplayer/guoguo-clone/API.md`、`docs/ui-design-system.md`、`Views/Theme.swift`

---

## 1. 项目背景与目标

HPlayer 目前作为一款聚焦于 115 网盘、磁力流播与本地媒体库的 iOS 影音播放器，具备卓越的 MPV 播放内核、自适应刮削匹配和统一的黑曜石+琥珀金视觉规范。
本项目的目标是将已完成逆向分析的「果果动漫 / 动漫共和国」在线视频协议完整接入 HPlayer，为用户提供海量正版/流媒体番剧资源（日漫、国漫、剧场版、美漫、特摄等）的点播体验，且与 HPlayer 现有的片库、搜索、播放器和继续观看体系无缝融合。

### 核心设计原则
1. **零结构破坏**：维持底部 4 个基础标签（首页、片库、网盘、我的），不打乱用户已有的导航心智。
2. **纯正设计语言**：100% 沿用 HPlayer 的设计系统（`Theme.swift` 颜色、圆角、字号；`Icons.swift` SF Symbols 线框图标；`Motion.swift` 弹簧动效）。
3. **原生播放体验**：不使用网页嵌套或第三方内嵌 UI，所有播放行为均唤起 HPlayer 原生独立的 `PlayerWindow`，发挥 MPV 引擎的高画质硬解、倍速、手势与后台画中画能力。
4. **闭环系统集成**：全局搜索联合检索，观看进度实时同步至首页「继续观看」货架。

---

## 2. 整体信息架构与导航规范

### 2.1 片库入口切换 (CatalogTab Segmented Control)
在片库页面（`CatalogTab.swift`）顶部导航栏下方增加分段选择器（Segmented Control）：
* **「我的片库 (115/本地)」**：保留原有本地与云端媒体资产库（电影 / 剧集 / 动画 / 演员合集及四行多维筛选）。
* **「动漫共和国」**：切换至在线动漫流媒体主页。
* **状态持久化**：应用在后台切换或标签来回切换时保持各自滚动位置与选择状态。

### 2.2 页面跳转与路由拓扑
```
[底部标签栏: 片库]
       │
       ├── 分段切换 ──> [动漫主界面 (AnimeCatalogView)]
       │                      │
       │                      ├── 轮播大图/货架卡片/网格 ──> 点击番剧
       │                      │                              │
       │                      ▼                              ▼
       │             [全屏联合搜索 (SearchTab)]        [动漫详情页 (AnimeDetailView)]
       │                      │                              │
       │                      │                              ├── 选集/立即播放
       │                      │                              │
       │                      └──────────────────────────────┼──> 唤起 [独立播放窗口 (PlayerWindow)]
       │                                                     │
       ▼                                                     ▼
[底部标签栏: 首页] ──> 「继续观看」货架 ──(一键续播)──────────┘
```

---

## 3. 详细界面设计与组件规范

### 3.1 动漫主页 (`AnimeCatalogView`)

主页采用**探索流媒体风**，分为四大功能区：

1. **顶部频道横滑胶囊 (`AnimeChannelPills`)**：
   * 动态拉取 `GET /app/channel?top-level=true`。
   * 支持分类：日漫、国漫、剧场、美漫、特摄、少儿、动态漫等。
   * 视觉样式：胶囊高 28pt，未选中项为 `Theme.surfaceRaised` 底 + `Theme.textSecondary` 字，选中项为琥珀金 `Theme.accent` 底 + `Theme.onPrimary` 深色字。
2. **今日热播轮播大图 (`AnimeHeroBanner`)**：
   * 数据源：`GET /app/banners`。
   * 16:9 画幅，圆角 14pt，边缘轻度发光描边（`1px solid rgba(233,176,97,0.25)`）。
   * 底部文字渐变遮罩，左上角标出运营标签（如 `🔥 今日重磅热播`），下方浮现片名与更新信息（如 `8#周五16:00更 · 简中 1080P`）。点击直达详情。
3. **热门新番横滑货架 (`AnimeShelfView`)**：
   * 数据源：`GET /app/video/list?channel={id}&sort=weight&limit=18&page=1`。
   * 标题栏带金色的「全部 >」跳转按钮；卡片宽 95pt，高 145pt，海报右下角带磨砂黑底金字角标（如 `26全`、`更至108集`）。
4. **分类海报瀑布流网格 (`AnimeGridView`)**：
   * 数据源：`GET /app/video/list?channel={id}&sort=addtime&limit=18&page=N`。
   * 双列海报排布，海报比例 3:4，圆角 10pt。
   * 滚动至底部自动触发下一页加载（无限滚动加载）。为空时展示统一的空状态占位，网络错误时提供重试按钮。

### 3.2 动漫详情页 (`AnimeDetailView`)

遵循 HPlayer `SeriesDetailView` 的原生沉浸式规范：

1. **氛围拉伸大图背景 (`Backdrop`)**：
   * 顶部铺满番剧横版封面大图，支持向下拉拽等比拉伸。
   * 底部叠加多段线性渐变平滑融进主背景色 `#0B0C10`。
   * 导航栏半透明悬浮：左侧返回按钮，右侧心形追番按钮（`♡` / `♥`）与更多菜单。
2. **悬浮海报与番剧信息抬头**：
   * 海报卡片（宽 97pt，高 136pt，圆角 10pt，浮在背景图下沿）；
   * 片名采用衬线字体（`Font.display(24)`）；
   * 元信息展示：更新状态、年份、产地、类型胶囊标签、评分星标（金色星标 + 数字）。
3. **主播放按钮**：
   * 醒目的琥珀金全宽按钮：`▶ 续播：第 107 集 (从 14:20 继续)` 或 `▶ 立即播放第 1 集`。
4. **多线路切换与选集矩阵**：
   * **线路胶囊**：解析 `parts[]`，展示 `国语`、`日语` 等线路。切换线路即时切换对应的选集源。
   * **排序切换**：选集右侧提供 `倒序 ⇄ 正序` 切换开关。
   * **选集网格**：采用 5 列紧凑数字方块（`01`, `02`, ..., `108`），当前播放集以琥珀金实线边框 + 淡金底色高亮，已播放过的集数文本置灰显示。
5. **剧情简介手风琴**：
   * 默认最多截断展示 3 行，点击右侧文本或箭头平滑展开全部剧情。

### 3.3 全局联合搜索 (`SearchTab`)

1. **分栏筛选胶囊**：
   * 在搜索输入框下方增加 3 个标签：`全部`、`网盘/本地 (count)`、`在线动漫 (count)`。
   * 在动漫板块点击搜索图标时，自动预选「在线动漫」标签。
2. **搜索请求与防抖**：
   * 用户键入内容后提供 300ms 动态防抖，调用 `GET /app/video/search?key={keyword}&limit=20&page=1`。
3. **搜索卡片展示**：
   * 包含海报缩略图、标题（高亮匹配关键字）、集数状态、金色 `在线动漫` 来源标签。点击直达对应详情页。

### 3.4 首页「继续观看」贯通

1. 每次播放动漫时，向本地 `RecentStore.shared` 写入或更新一条媒体记录。
2. 首页顶部「继续观看」货架同步展示该番剧海报，右下角标明金色 `动漫` 标签和集数进度（如 `第107集 · 55%`）。
3. 点击继续观看卡片，直接唤起 `PlayerWindow` 断点续播。

---

## 4. 核心网络通信与数据流协议

所有主业务 API 域名为 `http://bkbfdm.cenmo.fun`（HTTP/80，TencentEdgeOne CDN），必须严格按照逆向协议实施客户端签名与混合解密。

### 4.1 客户端请求签名 (`AnimeSigner`)

每次请求必须生成全新的时间戳（`ts`）并带齐全部鉴权头：

```swift
let ts = String(Int(Date().timeIntervalSince1970 * 1000))
let signPlain = "2.4.7.9-\(ts)-IOS-1.0.0.1-\(deviceId)"
let inner = signPlain.data(using: .utf8)!.base64EncodedString()
let authentication = AES256CBC.encrypt(
    data: inner.data(using: .utf8)!,
    key: "ziISjqkXPsGUMRNGyWigxDGtJbfTdcGv",
    iv: "WonrnVkxeIxDcFbv"
).base64EncodedString()
```

标准请求头清单：
```http
x-version: 2024-09-24
user-agent: Dart/3.6 (dart:io)
appid: 4150439554430627
ts: {当前毫秒时间戳}
accept-encoding: gzip
authentication: {动态计算的AES密文}
host: bkbfdm.cenmo.fun
content-type: application/json; charset=utf-8
x-token: {JWT用户令牌}
```

### 4.2 响应混合解密 (`AnimeResponseDecoder`)

响应体为加密字符串，格式为 `base64(RSA(randomKey)) + "." + base64(AES(plainJSON))`。

解密流水线：
1. 以 `"."` 为分隔符拆分成 `k` 与 `d`；
2. 用内置的 RSA 私钥（`receive_key`）以 PKCS1 填充解密 `base64_decode(k)`，得到 16 字节的 `randomKey` 字符串；
3. 计算 AES 的 IV：`iv = String(randomKey.reversed())`；
4. 使用 `key = randomKey` 与 `iv`，通过 AES-128-CBC-PKCS7 解密 `base64_decode(d)`；
5. 将解出的明文 UTF-8 字符串反序列化为统一响应外壳：
   ```json
   { "code": 20000, "message": "请求成功!", "data": ... }
   ```

---

## 5. 播放取链与 MPV 播放器集成

### 5.1 自动化播放解析流水线 (`AnimePlaybackResolver`)

```
POST /app/video/play?id={id}&play={play}&part={part}
                     │
                     ▼
          返回 data.url 是否为 "new-{md5}"?
           ├── 否 (如直链 MP4) ──> 直接交由 MPVEngine 播放
           │
           └── 是 (需解析) ────> 执行客户端内置解析算法
                                     │
                                     ├── 1. 计算 apiSource (AES-128-CBC 加密混淆串)
                                     ├── 2. 计算 sign 与四层防篡改头 (Client-Auth/Proof/Probe/Check)
                                     ├── 3. 请求 GET http://jxbfdm.cenmo.fun/?md5={apiSource}&sign={sign}
                                     ├── 4. 互换密钥 AES-128-CBC 解密 addr 与 m3u8FileDomain
                                     ├── 5. 执行域名重写规则 (换取最优 CDN 节点)
                                     │
                                     ▼
                           合成最终可用 m3u8 / mp4 URL
                                     │
                                     ▼
                           传入 HPlayer PlayerWindow
```

### 5.2 防盗链与特殊流媒体特征适配

| 媒体特征 | 表现机制 | HPlayer 适配方案 |
|---|---|---|
| **空 User-Agent** | 目标 CDN 对非常规 UA 或默认浏览器 UA 封锁 | 播放请求显式注入 `headers = ["User-Agent": ""]` |
| **防盗链拦截** | 小红书 CDN 出现外链 Referer 时返回 403 (`020200`) | 强制置空 `Referer` 请求头 |
| **伪扩展名切片** | TS 切片伪装为 `.png` 或 `.pdf` 扩展名 | MPV demuxer 原生支持识别 188 字节 `0x47` 同步字，自动作为 MPEG-TS 解封装 |
| **HEVC/H.265 编码** | 国漫 1080P 片源 PMT 为 `stream_type=0x24` | 启用 MPV `hwdec=auto` 硬件硬解加速 |

---

## 6. 异常处理与网络容灾策略

1. **EdgeOne 节点容灾 (IP 直连)**：
   * 当用户处于代理、TUN 或 DNS 污染环境导致 `*.cenmo.fun` 解析异常时，客户端内置备用真实节点 IP 池（`120.240.157.64`、`183.232.189.187`、`111.29.14.203`、`183.214.145.89`）。
   * 直连 IP 时严格携带 `Host: bkbfdm.cenmo.fun` / `Host: jxbfdm.cenmo.fun`，避免触发 EdgeOne `418` 拦截。
2. **签名失效保护 (`403501`)**：
   * 若系统时间偏差导致签名校验失败，自动从服务器响应头中的 `Date` 校准本地时间戳偏移量并自动重试一次。
3. **播放线路故障降级**：
   * 若当前线路的 `POST /app/video/play` 或解析接口失败，界面提示用户一键切换至备用线路（如 `国语` ⇋ `备用线路`）。

---

## 7. 模块划分与代码组织结构

所有相关代码集中放在独立清晰的模块目录下，不侵入污染其他已有功能：

```
ios-native/HPlayer/
├── Models/
│   └── AnimeModels.swift               // 频道、Banner、番剧条目、选集线路等 Codable 模型
├── Services/
│   ├── AnimeSigner.swift               // AES-256 客户端时间戳动态签名生成器
│   ├── AnimeResponseDecoder.swift      // RSA + AES-128 响应体混合解密器
│   ├── AnimeClient.swift               // 果果动漫 API 客户端 (频道、列表、搜索、详情)
│   ├── AnimePlaybackResolver.swift     // Lua 脚本等价的 Swift 播放解析与取链流水线
│   └── AnimeWatchlistStore.swift       // 本地追番与更新标记存储
└── Views/
    ├── AnimeCatalogView.swift          // 片库内的动漫主界面 (Banner + 货架 + 瀑布流)
    ├── AnimeDetailView.swift           // 动漫沉浸式详情页 (海报抬头 + 线路/选集方块矩阵)
    └── AnimeComponents.swift           // 频道胶囊、番剧海报卡片、选集方块等子组件
```

---

## 8. 测试与质量验证计划

1. **加解密算法单元测试 (`AnimeSecurityTests`)**：
   * 使用 `API.md` 中的已知明文与真机抓包样本，验证 `AnimeSigner` 生成的 `authentication` 密文与时间戳一致性。
   * 验证 `AnimeResponseDecoder` 能正确使用 RSA 私钥解密随机 key 并完成 AES-128-CBC 解密。
   * 验证 `AnimePlaybackResolver` 的签名生成与域名重写逻辑。
2. **界面与导航集成测试 (`AnimeUITests`)**：
   * 测试片库顶部分段控制器切换的平滑度与状态保留。
   * 测试从番剧卡片点击进入 `AnimeDetailView`、线路切换与集数切换。
   * 测试点击播放唤起 `PlayerWindow` 及关闭播放器返回详情页。
   * 测试全局搜索在动漫分类下的搜索结果呈现与直达详情。
3. **真实网络取链与播放回归**：
   * 针对不同来源（快手 CDN 切片、小红书 MP4 直链、H.265 国漫源）进行真机或模拟器连续取链播放测试，确保无 403 防盗链报错且音画流畅。
