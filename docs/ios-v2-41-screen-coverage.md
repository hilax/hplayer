# 47 项原型与原生页面对照

[41 张 Figma 原型（2.0 界面重构后新增「片库」）](https://www.figma.com/design/GokGdpKDY5nhYi9YnPRpx9?node-id=4-34)，加上网盘文件管理新增的 8 张画板（目录更多菜单、删除确认、移动到、文件信息、回收站、离线下载、添加离线任务、下载管理），并去掉已移除的「BT 云下载」「种子文件选择」「115 官方授权」3 页，共 47 项。本清单按画板逐项对应。47 项包含完整页面、空状态、解析状态与播放面板，不以 Swift 文件数量计算。截图由真实 SwiftUI 视图运行后导出，测试数据与凭证隔离；Release 包不包含预览宿主或测试海报。

云端构建会检查 47 项截图是否齐全，并将截图与覆盖报告上传到 `HPlayer-player-ui-test/prototype41`。登录、文件操作、离线下载提交使用真实服务流程，截图测试只显示固定的示例数据，不发起真实登录、文件操作或下载。

1.4（8）的代码复查修复了以下问题，并保留对应回归检查：

- 本地导入不再先删除同名文件；后台复制完整后发布，保留原文件与同名新文件，并显示导入错误。`LocalMediaStoreTests` 覆盖自身文件、同名文件、复制失败和无效输入。
- 搜索请求按提交顺序更新，旧结果与旧错误不能覆盖新查询；取消及换号后丢弃结果。`CloudSearchStoreTests` 使用可控请求顺序复现。
- 登录验证取消、退出或新登录会使旧请求失效；网页登录子弹窗关闭后再关闭父页面。`AppStateTests` 覆盖取消、退出、乱序登录及同账号凭证更新。
- 目录、扫描目录、账号状态和磁力云端结果按会话校验；换号后清理旧文件与播放队列。`MagnetCloudSessionTests` 覆盖换号、退出及保留当前会话结果。
- 同集重试、画质切换和自动降级只接受当前请求。
- 截图只在相册确认保存后显示成功；播放器在自身事件队列释放时不再同步等待自身队列。
- 手动匹配或取消匹配会清除尚未发布的旧自动匹配结果；并发匹配中的重新查找不会因旧请求仍在执行而被丢弃。
- 竖屏播放器底部操作具有至少 44 点高的触摸区域；竖屏信息页的清晰度、倍速、字幕、画面比例、解码五个入口都在按钮旁边弹出菜单（不是底部面板），右上角「…」只放定时关闭；交互测试连续打开关闭这些菜单和选集抽屉。横屏播放/上下集移至进度条下方，锁屏与截图向内收。

云端回归同时运行业务单元测试、播放与手势交互测试、47 项深色截图、12 项浅色截图（含竖屏播放页及其定时关闭、倍速、字幕、画面比例菜单和选集的浅色），以及 BT 引擎生命周期和本地节点传输检查。真实账号登录、115 文件操作与外网资源可用性仍受账号和远端服务状态影响。

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
| 12 | 片库 · 分类网格 | 片库（首页分类入口也会跳到这里） | [CatalogTab](../ios-native/HPlayer/Views/CatalogTab.swift) |
| 13 | 网盘 · 已连接 | 网盘 → 已连接 | [CloudTab](../ios-native/HPlayer/Views/CloudTab.swift) |
| 14 | 网盘 · 未连接 | 网盘 → 未连接 | [CloudTab](../ios-native/HPlayer/Views/CloudTab.swift) |
| 15 | 115 · 文件目录（完整文件管理） | 网盘 → 115 → 目录 | [LibraryView](../ios-native/HPlayer/Views/LibraryView.swift) |
| 16 | 115 · 多选与底部操作栏 | 115 目录 → 更多 → 选择 | [LibraryView](../ios-native/HPlayer/Views/LibraryView.swift) |
| 17 | 115 · 目录更多菜单 | 网盘 → 115 → 目录 → 更多 | [LibraryView](../ios-native/HPlayer/Views/LibraryView.swift) |
| 18 | 115 · 删除确认 | 115 目录 → 选择 → 删除 | [DeleteConfirmSheet](../ios-native/HPlayer/Views/FileManagementViews.swift) |
| 19 | 115 · 移动到 / 复制到 | 115 目录 → 选择 → 移动 / 复制 | [FolderPickerSheet](../ios-native/HPlayer/Views/FileManagementViews.swift) |
| 20 | 115 · 文件信息 | 115 目录 → 选择 → 信息 | [FileInfoSheet](../ios-native/HPlayer/Views/FileManagementViews.swift) |
| 21 | 115 · 回收站 | 115 目录 → 更多 → 回收站 | [RecycleBinView](../ios-native/HPlayer/Views/RecycleBinView.swift) |
| 22 | 115 · 离线下载 | 网盘 → 离线下载 | [OfflineTasksView](../ios-native/HPlayer/Views/OfflineTasksView.swift) |
| 23 | 115 · 添加离线任务 | 离线下载 → 添加任务 | [OfflineAddSheet](../ios-native/HPlayer/Views/OfflineTasksView.swift) |
| 24 | 115 · 下载管理 | 115 目录 → 更多 → 下载管理 | [DownloadsView](../ios-native/HPlayer/Views/DownloadsView.swift) |
| 25 | 本机视频 | 网盘 → 本机视频 | [LocalVideosView](../ios-native/HPlayer/Views/LocalVideosView.swift) |
| 26 | 搜索 · 初始 | 搜索 | [SearchTab](../ios-native/HPlayer/Views/SearchTab.swift) |
| 27 | 搜索 · 聚合结果 | 搜索 → 输入关键词 | [SearchTab](../ios-native/HPlayer/Views/SearchTab.swift) |
| 28 | 搜索 · 无结果 | 搜索 → 无匹配结果 | [SearchTab](../ios-native/HPlayer/Views/SearchTab.swift) |
| 29 | 媒体库管理 | 我的 → 媒体库管理 | [HomeLibraryScanView](../ios-native/HPlayer/Views/HomeLibraryScanView.swift) |
| 30 | 选择扫描目录 | 媒体库管理 → 选择文件夹扫描 | [ScanFolderPicker](../ios-native/HPlayer/Views/ScanFolderPicker.swift) |
| 31 | 未匹配影片 | 媒体库管理 → 未匹配影片 | [HomeLibraryScanView](../ios-native/HPlayer/Views/HomeLibraryScanView.swift) |
| 32 | 匹配封面与资料 | 影片菜单 / 未匹配影片 → 匹配封面 | [MetadataMatchView](../ios-native/HPlayer/Views/MetadataMatchView.swift) |
| 33 | 资料来源 | 媒体库管理 / 匹配页 → 资料来源 | [MetadataSourcesView](../ios-native/HPlayer/Views/MetadataSourcesView.swift) |
| 34 | 资料接口凭证 | 资料来源 → 管理接口凭证 | [MetadataCredentialsView](../ios-native/HPlayer/Views/MetadataCredentialsView.swift) |
| 35 | 我的 | 我的 | [SettingsView](../ios-native/HPlayer/Views/SettingsView.swift) |
| 36 | 外观 | 我的 → 显示方式 | [SettingsView](../ios-native/HPlayer/Views/SettingsView.swift) |
| 37 | 连接 115 | 网盘 / 我的 → 登录 115 | [CookieWebLoginView](../ios-native/HPlayer/Views/CookieWebLoginView.swift) |
| 38 | 开源许可 | 我的 → 开源许可 | [SettingsView](../ios-native/HPlayer/Views/SettingsView.swift) |
| 39 | 磁力在线播放 | 网盘 / 添加 → 磁力播放 | [MagnetPlayerView](../ios-native/HPlayer/Views/MagnetPlayerView.swift) |
| 40 | 磁力解析中 | 磁力 → 解析中 | [MagnetPlayerView](../ios-native/HPlayer/Views/MagnetPlayerView.swift) |
| 41 | 磁力资源目录 | 磁力 → 解析完成 | [MagnetPlayerView](../ios-native/HPlayer/Views/MagnetPlayerView.swift) |
| 42 | 竖屏播放器 | 播放器 → 切换竖屏 | [PlaybackControlsView](../ios-native/HPlayer/Views/PlaybackControlsView.swift) |
| 43 | 横屏播放器 | 播放器 → 横屏 | [PlaybackControlsView](../ios-native/HPlayer/Views/PlaybackControlsView.swift) |
| 44 | 竖屏倍速菜单（按钮旁弹出） | 播放器 → 竖屏 → 倍速 | [PlaybackControlsView](../ios-native/HPlayer/Views/PlaybackControlsView.swift) |
| 45 | 竖屏字幕与音轨菜单（按钮旁弹出） | 播放器 → 竖屏 → 字幕 | [PlaybackControlsView](../ios-native/HPlayer/Views/PlaybackControlsView.swift) |
| 46 | 播放器选集面板 | 播放器 → 选集 | [PlaybackControlsView](../ios-native/HPlayer/Views/PlaybackControlsView.swift) |
| 47 | 竖屏画面比例菜单（按钮旁弹出） | 播放器 → 竖屏 → 画面比例 | [PlaybackControlsView](../ios-native/HPlayer/Views/PlaybackControlsView.swift) |
