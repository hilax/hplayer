# 41 项原型与原生页面对照

[41 张 Figma 原型](https://www.figma.com/design/GokGdpKDY5nhYi9YnPRpx9?node-id=4-34)。本清单按原型画板逐项对应。41 项包含完整页面、空状态、解析状态与播放面板，不以 Swift 文件数量计算。截图由真实 SwiftUI 视图运行后导出，测试数据与凭证隔离；Release 包不包含预览宿主或测试海报。

云端构建会检查 41 项截图是否齐全，并将截图与覆盖报告上传到 `HPlayer-player-ui-test/prototype41`。登录、云下载提交使用原有真实服务流程，截图测试不发起真实登录或下载。

1.4（7）的代码复查修复了以下问题，并保留对应回归检查：

- 本地导入不再先删除同名文件；后台复制完整后发布，保留原文件与同名新文件，并显示导入错误。`LocalMediaStoreTests` 覆盖自身文件、同名文件、复制失败和无效输入。
- 搜索请求按提交顺序更新，旧结果与旧错误不能覆盖新查询；取消及换号后丢弃结果。`CloudSearchStoreTests` 使用可控请求顺序复现。
- 登录验证取消、退出或新登录会使旧请求失效；网页登录子弹窗关闭后再关闭父页面。`AppStateTests` 覆盖取消、退出、乱序登录及同账号凭证更新。
- 目录、扫描目录、账号状态、BT 和磁力云端结果按会话校验；换号后清理旧文件与播放队列。`MagnetCloudSessionTests` 覆盖换号、退出及保留当前会话结果。
- 同集重试、画质切换和自动降级只接受当前请求；退出官方授权页面后不再启动延迟返回的轮询。
- 竖屏播放器底部操作具有至少 44 点高的触摸区域；交互测试连续打开关闭播放设置、字幕音轨、画面比例和选集。横屏播放/上下集移至进度条下方，锁屏与截图向内收。

云端回归同时运行业务单元测试、播放与手势交互测试、41 项深色截图、6 项浅色截图，以及 BT 引擎生命周期和本地节点传输检查。真实账号登录、官方授权与外网资源可用性仍受账号和远端服务状态影响。

| # | 原型画板 | 应用入口 / 状态 | 原生实现 |
|---|---|---|---|
| 1 | 首页 · 沉浸精选 | 首页 | [HomeTab](../ios-native/HPlayer/Views/HomeTab.swift) |
| 2 | 首页 · 片库货架 | 首页 → 下滑货架 | [HomeTab](../ios-native/HPlayer/Views/HomeTab.swift) |
| 3 | 首页 · 空片库 | 首页 → 空片库 | [HomeTab](../ios-native/HPlayer/Views/HomeTab.swift) |
| 4 | 电影 · 海报网格 | 首页 → 电影 → 全部 | [HomeComponents](../ios-native/HPlayer/Views/HomeComponents.swift) |
| 5 | 剧集 · 海报网格 | 首页 → 剧集 → 全部 | [HomeComponents](../ios-native/HPlayer/Views/HomeComponents.swift) |
| 6 | 演员合集 | 首页 → 演员合集 → 全部 | [MediaActionSheets](../ios-native/HPlayer/Views/MediaActionSheets.swift) |
| 7 | 演员 · 作品列表 | 演员合集 → 演员 | [PerformerCollectionView](../ios-native/HPlayer/Views/PerformerCollectionView.swift) |
| 8 | 剧集详情 · 分季选集 | 首页 / 搜索 → 剧集 | [SeriesDetailView](../ios-native/HPlayer/Views/SeriesDetailView.swift) |
| 9 | 继续观看 · 历史 | 首页 → 继续观看 → 全部 | [HomeComponents](../ios-native/HPlayer/Views/HomeComponents.swift) |
| 10 | 添加影片 · 操作面板 | 首页 → 添加 | [MediaActionSheets](../ios-native/HPlayer/Views/MediaActionSheets.swift) |
| 11 | 影片 · 长按菜单 | 首页 → 精选更多 | [MediaActionSheets](../ios-native/HPlayer/Views/MediaActionSheets.swift) |
| 12 | 资源库 · 已连接 | 资源库 → 已连接 | [LibraryTab](../ios-native/HPlayer/Views/LibraryTab.swift) |
| 13 | 资源库 · 未连接 | 资源库 → 未连接 | [LibraryTab](../ios-native/HPlayer/Views/LibraryTab.swift) |
| 14 | 115 · 文件目录 | 资源库 → 115 → 目录 | [LibraryView](../ios-native/HPlayer/Views/LibraryView.swift) |
| 15 | 115 · 批量选择 | 115 目录 → 更多 → 选择 | [LibraryView](../ios-native/HPlayer/Views/LibraryView.swift) |
| 16 | 本机视频 | 资源库 → 本机视频 | [LocalVideosView](../ios-native/HPlayer/Views/LocalVideosView.swift) |
| 17 | 搜索 · 初始 | 搜索 | [SearchTab](../ios-native/HPlayer/Views/SearchTab.swift) |
| 18 | 搜索 · 聚合结果 | 搜索 → 输入关键词 | [SearchTab](../ios-native/HPlayer/Views/SearchTab.swift) |
| 19 | 搜索 · 无结果 | 搜索 → 无匹配结果 | [SearchTab](../ios-native/HPlayer/Views/SearchTab.swift) |
| 20 | 媒体库管理 | 资源库 → 媒体库管理 | [HomeLibraryScanView](../ios-native/HPlayer/Views/HomeLibraryScanView.swift) |
| 21 | 选择扫描目录 | 媒体库管理 → 选择文件夹扫描 | [ScanFolderPicker](../ios-native/HPlayer/Views/ScanFolderPicker.swift) |
| 22 | 未匹配影片 | 媒体库管理 → 未匹配影片 | [HomeLibraryScanView](../ios-native/HPlayer/Views/HomeLibraryScanView.swift) |
| 23 | 匹配封面与资料 | 影片菜单 / 未匹配影片 → 匹配封面 | [MetadataMatchView](../ios-native/HPlayer/Views/MetadataMatchView.swift) |
| 24 | 资料来源 | 媒体库管理 / 匹配页 → 资料来源 | [MetadataSourcesView](../ios-native/HPlayer/Views/MetadataSourcesView.swift) |
| 25 | 资料接口凭证 | 资料来源 → 管理接口凭证 | [MetadataCredentialsView](../ios-native/HPlayer/Views/MetadataCredentialsView.swift) |
| 26 | 设置 | 设置 | [SettingsView](../ios-native/HPlayer/Views/SettingsView.swift) |
| 27 | 外观 | 设置 → 显示方式 | [SettingsView](../ios-native/HPlayer/Views/SettingsView.swift) |
| 28 | 连接 115 | 资源库 / 设置 → 登录 115 | [CookieWebLoginView](../ios-native/HPlayer/Views/CookieWebLoginView.swift) |
| 29 | 115 官方授权 | BT 云下载 → 115 云下载授权 | [Official115SettingsView](../ios-native/HPlayer/Views/Official115SettingsView.swift) |
| 30 | 开源许可 | 设置 → 开源许可 | [SettingsView](../ios-native/HPlayer/Views/SettingsView.swift) |
| 31 | 磁力在线播放 | 资源库 / 添加 → 磁力播放 | [MagnetPlayerView](../ios-native/HPlayer/Views/MagnetPlayerView.swift) |
| 32 | 磁力解析中 | 磁力 → 解析中 | [MagnetPlayerView](../ios-native/HPlayer/Views/MagnetPlayerView.swift) |
| 33 | 磁力资源目录 | 磁力 → 解析完成 | [MagnetPlayerView](../ios-native/HPlayer/Views/MagnetPlayerView.swift) |
| 34 | BT 种子与云下载 | 资源库 → BT 云下载 | [TorrentView](../ios-native/HPlayer/Views/TorrentView.swift) |
| 35 | 种子文件选择 | BT → 导入种子 → 解析完成 | [TorrentSelectionView](../ios-native/HPlayer/Views/TorrentSelectionView.swift) |
| 36 | 竖屏播放器 | 播放器 → 切换竖屏 | [PlaybackControlsView](../ios-native/HPlayer/Views/PlaybackControlsView.swift) |
| 37 | 横屏播放器 | 播放器 → 横屏 | [PlaybackControlsView](../ios-native/HPlayer/Views/PlaybackControlsView.swift) |
| 38 | 播放设置面板 | 播放器 → 播放设置 | [PlaybackControlsView](../ios-native/HPlayer/Views/PlaybackControlsView.swift) |
| 39 | 字幕与音轨面板 | 播放器 → 字幕 / 音轨 | [PlaybackControlsView](../ios-native/HPlayer/Views/PlaybackControlsView.swift) |
| 40 | 播放器选集面板 | 播放器 → 选集 | [PlaybackControlsView](../ios-native/HPlayer/Views/PlaybackControlsView.swift) |
| 41 | 画面比例面板 | 播放器 → 画面比例 | [PlaybackControlsView](../ios-native/HPlayer/Views/PlaybackControlsView.swift) |
