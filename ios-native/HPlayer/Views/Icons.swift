import SwiftUI

/// 全应用唯一的图标表。
///
/// 图标是 HPlayer 自己画的一套（不再是系统 SF Symbols），以自定义符号的形式放在
/// `Assets.xcassets/Icons`，资源名是 `hp.<case>`；用法和系统符号一样，跟着 `.font` 缩放。
/// 图形的源文件是 `ios-native/scripts/icons/icons.js`，改完运行 `build-symbols.py` 重新生成。
///
/// 规则（保证所有页面的图标看起来是同一套）：
/// 1. 24pt 网格、1.6 线宽、圆头圆角；线框为默认。
/// 2. 实心款只留给「正在发生 / 被选中」的状态：播放键、评分星、选中的底部标签、勾选圆圈。
/// 3. 同一个意思只有一个图标：所有提醒都是 `alert`，所有"更多"都是 `more`，所有"完成"都是 `success`。
/// 4. 页面里不允许直接写图标名字面量，也不允许 `Image(systemName:)`，一律从这里取；
///    `ios-native/scripts/check-icons.py` 会在云端构建里检查。
enum AppIcon: String, CaseIterable {
    // MARK: 底部导航
    case home, library, magnet, cloud, mine

    // MARK: 通用动作
    case search, back, forward, expand, collapse, close, clear, more, add, remove
    case check, selected, unselected, success, alert, info, help, addCircle
    /// 操作失败（HUD 失败语气）
    case failure
    case refresh, history, clock, sortAscending, sortDescending, tune, settings
    case copy, trash, openExternal, returnKey, sparkles, hidden, hot, topics, mirror
    case heart, heartFill, bolt
    case comment, like, pin

    // MARK: 播放
    case play, playCircle, pause, stop, previous, next, skip, seek, seekBack, fullscreen, exitFullscreen
    case lock, unlock, screenshot, subtitle, audio, aspect, aspectFit, aspectFill, aspectStretch
    case speed, playlist, decoder, sleepTimer, nowPlaying
    case brightnessLow, brightnessHigh
    case volumeMute, volumeLow, volumeMedium, volumeHigh
    case battery0, battery25, battery50, battery75, battery100, batteryCharging
    case playback

    // MARK: 影视内容
    case video, series, tv, poster, posterBatch, posterSearch, rating
    case people, peopleAdd, personUnknown, autoMatch, addToLibrary, device

    // MARK: 文件与网盘
    case folder, folderSettings, file, document, archive, torrentFile
    case link, key, keyHorizontal, privacy, verified, checklist
    case download, cloudDownload, cloudReady, cloudFailed, cloudLocked
    case network, fast, scan, qrScan, switchAccount, logout
    // MARK: 文件管理
    case rename, moveTo, newFolder, recycleBin, restore, sort, paste, share

    // MARK: 外观
    case appearance, appearanceLight, appearanceDark, appearanceSystem

    // MARK: 「我的」「网盘」列表
    case transfers, danmaku, metadataSources, appIconStyle, license, version, allFiles
    /// 「我的」里的播放设置
    case autoPlayNext, pictureInPicture, pictureInPictureExit, readahead, danmakuStyle
    /// 「我的」里的 HPlayer 账号：消息、任务、签到、金币、点赞、发送
    case bell, checkIn, coin, likeFill, send, textStyle, mail, phone, eye

    /// 资源名（自定义符号），线框款或本来就只有一种样子的图标。
    var name: String { "hp.\(rawValue)" }

    /// 被选中时的实心款。只有底部标签用到；其余图标选中时不换样子，只换颜色。
    var activeName: String {
        switch self {
        case .home, .library, .magnet, .cloud, .mine: return "hp.\(rawValue).active"
        default: return name
        }
    }

    /// 读屏朗读的名字。系统符号自带英文名字，自定义符号默认会读出资源名，所以这里给中文名。
    var spokenName: String {
        switch self {
        case .home: return "首页"
        case .library: return "片库"
        case .magnet: return "磁力"
        case .cloud: return "网盘"
        case .mine: return "我的"
        case .search: return "搜索"
        case .back: return "返回"
        case .forward: return "前往"
        case .expand: return "展开"
        case .collapse: return "收起"
        case .close: return "关闭"
        case .clear: return "清除"
        case .more: return "更多"
        case .add: return "添加"
        case .remove: return "移除"
        case .check: return "勾选"
        case .selected: return "已选"
        case .unselected: return "未选"
        case .success: return "完成"
        case .alert: return "提醒"
        case .info: return "信息"
        case .help: return "帮助"
        case .addCircle: return "添加"
        case .failure: return "失败"
        case .refresh: return "刷新"
        case .history: return "历史"
        case .clock: return "时间"
        case .sortAscending: return "升序"
        case .sortDescending: return "降序"
        case .tune: return "筛选"
        case .settings: return "设置"
        case .copy: return "复制"
        case .trash: return "删除"
        case .openExternal: return "在外部打开"
        case .returnKey: return "换行"
        case .sparkles: return "智能"
        case .hidden: return "隐藏"
        case .hot: return "热门"
        case .topics: return "专题"
        case .mirror: return "镜像站点"
        case .heart: return "收藏"
        case .heartFill: return "已收藏"
        case .bolt: return "加速"
        case .comment: return "评论"
        case .like: return "点赞"
        case .pin: return "置顶"
        case .play: return "播放"
        case .playCircle: return "播放"
        case .pause: return "暂停"
        case .stop: return "停止"
        case .previous: return "上一个"
        case .next: return "下一个"
        case .skip: return "快进"
        case .seek: return "前进 10 秒"
        case .seekBack: return "后退 10 秒"
        case .fullscreen: return "全屏"
        case .exitFullscreen: return "退出全屏"
        case .lock: return "已锁定"
        case .unlock: return "解锁"
        case .screenshot: return "截图"
        case .subtitle: return "字幕"
        case .audio: return "音轨"
        case .aspect: return "画面比例"
        case .aspectFit: return "适应"
        case .aspectFill: return "填充"
        case .aspectStretch: return "拉伸"
        case .speed: return "倍速"
        case .playlist: return "选集"
        case .decoder: return "解码"
        case .sleepTimer: return "定时关闭"
        case .nowPlaying: return "正在播放"
        case .brightnessLow: return "亮度低"
        case .brightnessHigh: return "亮度高"
        case .volumeMute: return "静音"
        case .volumeLow: return "音量低"
        case .volumeMedium: return "音量中"
        case .volumeHigh: return "音量高"
        case .battery0: return "电量低"
        case .battery25: return "电量 25%"
        case .battery50: return "电量 50%"
        case .battery75: return "电量 75%"
        case .battery100: return "电量满"
        case .batteryCharging: return "正在充电"
        case .playback: return "播放"
        case .video: return "视频"
        case .series: return "剧集"
        case .tv: return "电视"
        case .poster: return "封面"
        case .posterBatch: return "批量封面"
        case .posterSearch: return "搜索封面"
        case .rating: return "评分"
        case .people: return "演员"
        case .peopleAdd: return "添加演员"
        case .personUnknown: return "未知演员"
        case .autoMatch: return "自动匹配"
        case .addToLibrary: return "加入片库"
        case .device: return "本机"
        case .folder: return "文件夹"
        case .folderSettings: return "文件夹设置"
        case .file: return "文件"
        case .document: return "文档"
        case .archive: return "压缩包"
        case .torrentFile: return "种子文件"
        case .link: return "链接"
        case .key: return "密钥"
        case .keyHorizontal: return "密钥"
        case .privacy: return "隐私"
        case .verified: return "已认证"
        case .checklist: return "清单"
        case .download: return "下载"
        case .cloudDownload: return "离线下载"
        case .cloudReady: return "已离线"
        case .cloudFailed: return "离线失败"
        case .cloudLocked: return "需要登录"
        case .network: return "网络"
        case .fast: return "加速"
        case .scan: return "扫描"
        case .qrScan: return "扫码"
        case .switchAccount: return "切换账号"
        case .logout: return "退出登录"
        case .rename: return "重命名"
        case .moveTo: return "移动到"
        case .newFolder: return "新建文件夹"
        case .recycleBin: return "回收站"
        case .restore: return "还原"
        case .sort: return "排序"
        case .paste: return "粘贴"
        case .share: return "分享"
        case .appearance: return "外观"
        case .appearanceLight: return "浅色"
        case .appearanceDark: return "深色"
        case .appearanceSystem: return "跟随系统"
        case .transfers: return "传输"
        case .danmaku: return "弹幕"
        case .metadataSources: return "媒体库来源"
        case .appIconStyle: return "应用图标"
        case .license: return "开源许可"
        case .version: return "版本"
        case .allFiles: return "全部文件"
        case .autoPlayNext: return "自动连播"
        case .pictureInPicture: return "小窗播放"
        case .pictureInPictureExit: return "退出小窗"
        case .readahead: return "边播边存"
        case .danmakuStyle: return "弹幕样式"
        case .bell: return "消息"
        case .checkIn: return "签到"
        case .coin: return "金币"
        case .likeFill: return "已点赞"
        case .send: return "发送"
        case .textStyle: return "文字样式"
        case .mail: return "邮箱"
        case .phone: return "手机"
        case .eye: return "显示"
        }
    }

    /// 资源名 → 图标（含选中款），给只拿到名字字符串的地方查读屏名字。
    static let byAssetName: [String: AppIcon] = {
        var map: [String: AppIcon] = [:]
        for icon in AppIcon.allCases {
            map[icon.name] = icon
            map[icon.activeName] = icon
        }
        return map
    }()
}

extension Image {
    init(icon: AppIcon, active: Bool = false) {
        self.init(appIconNamed: active ? icon.activeName : icon.name)
    }

    /// 按资源名取图标（名字必须来自 `AppIcon.name` / `activeName`），带上中文读屏名字。
    init(appIconNamed name: String) {
        if let icon = AppIcon.byAssetName[name] {
            self.init(name, bundle: nil, label: Text(icon.spokenName))
        } else {
            self.init(name)
        }
    }
}

extension Label where Title == Text, Icon == Image {
    init(_ title: String, icon: AppIcon) {
        self.init(title, image: icon.name)
    }
}

extension Button where Label == SwiftUI.Label<Text, Image> {
    /// 和系统的 `Button(_:icon:role:action:)` 一样，只是图标来自 HPlayer 图标表（传 `AppIcon.name`）。
    init(_ title: String, icon name: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(title, image: name) }
    }
}

// MARK: - 统一的图标样式

extension View {
    /// 所有图标共用的字号字重。`size` 决定大小，字重固定为 medium，
    /// 这样列表行、工具栏、卡片角标里的图标线条粗细一致。
    func iconStyle(size: CGFloat = 18, color: Color? = nil) -> some View {
        self
            .font(.scaled(size, weight: Theme.iconWeight))
            .foregroundStyle(color ?? Theme.accent)
            .symbolRenderingMode(.monochrome)
    }
}

/// 圆角方块图标底：极淡的灰底 + 线框图标。工具卡、设置行用它。
struct IconTile: View {
    let symbolName: String
    var size: CGFloat = 34
    var tone: Tone = .accent

    init(icon: AppIcon, size: CGFloat = 34, tone: Tone = .accent) {
        self.init(symbolName: icon.name, size: size, tone: tone)
    }

    /// 给还在传图标名字的行用（例如 `LibraryActionRow`）；名字本身必须来自 `AppIcon`。
    init(symbolName: String, size: CGFloat = 34, tone: Tone = .accent) {
        self.symbolName = symbolName
        self.size = size
        self.tone = tone
    }

    enum Tone {
        case accent, neutral, danger

        var foreground: Color {
            switch self {
            case .accent: return Theme.textPrimary
            case .neutral: return Theme.textSecondary
            case .danger: return Theme.danger
            }
        }

        var background: Color {
            switch self {
            case .accent: return Theme.tileTint
            case .neutral: return Theme.surfaceRaised
            case .danger: return Theme.danger.opacity(0.12)
            }
        }
    }

    var body: some View {
        Image(appIconNamed: symbolName)
            .font(.scaled(size * 0.5, weight: Theme.iconWeight))
            .foregroundStyle(tone.foreground)
            .frame(width: size, height: size)
            .background(tone.background, in: RoundedRectangle(cornerRadius: min(Theme.Radius.tile, size * 0.25), style: .continuous))
            .accessibilityHidden(true)
    }
}

/// 导航栏按钮里的图标（右上角的 ＋、…、搜索、追番 …）。
///
/// iOS 26 会把「按钮里只有一张图」转换成系统栏按钮再上色，真机上出现过右上角只剩玻璃圆、
/// 图标不见了（动漫详情的追番、离线下载的 ＋）。这里给图标固定尺寸并显式上色，由 SwiftUI 自己画，
/// 不走那次转换；禁用时变灰。所有导航栏图标按钮的 label 都用它。
struct NavigationIcon: View {
    let icon: AppIcon
    var active = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ icon: AppIcon, active: Bool = false) {
        self.icon = icon
        self.active = active
    }

    var body: some View {
        Image(icon: icon, active: active)
            .font(.system(size: 17, weight: Theme.iconWeight))
            .foregroundStyle(isEnabled ? Theme.navigationButton : Theme.textMuted)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
    }
}

// MARK: - 排查用：导航栏探针

#if DEBUG
/// 排查「导航栏右上角只剩玻璃圆」用：UI 测试设置 HPLAYER_TOOLBAR_PROBE=1 时，
/// 在右上角多放几种按钮（红方块、文字、系统符号），由测试量出各自画出了多少像素。
private struct ToolbarProbe: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if ProcessInfo.processInfo.environment["HPLAYER_TOOLBAR_PROBE"] == "1" {
            content.toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {} label: { Rectangle().fill(Color.red).frame(width: 18, height: 18) }
                        .accessibilityIdentifier("probe.rect")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("测") {}
                        .accessibilityIdentifier("probe.text")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {} label: { Image(systemName: "plus") }
                        .accessibilityIdentifier("probe.sf")
                }
            }
        } else {
            content
        }
    }
}
#endif

extension View {
    @ViewBuilder func toolbarProbe() -> some View {
        #if DEBUG
        modifier(ToolbarProbe())
        #else
        self
        #endif
    }
}
