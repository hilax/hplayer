import SwiftUI

/// 全应用唯一的图标表。
///
/// 规则（保证所有页面的图标看起来是同一套）：
/// 1. 只用 SF Symbols 的线框款，字重统一走 `Theme.iconWeight`。
/// 2. 实心款只留给「正在发生 / 被选中」的状态：播放键、评分星、选中的底部标签、勾选圆圈。
/// 3. 同一个意思只有一个图标：所有提醒都是 `alert`，所有"更多"都是 `more`，所有"完成"都是 `success`。
/// 4. 页面里不允许直接写 `"xxx.fill"` 这样的字面量，一律从这里取；
///    `ios-native/scripts/check-icons.py` 会在云端构建里检查。
enum AppIcon: String, CaseIterable {
    // MARK: 底部导航
    case home, library, cloud, mine

    // MARK: 通用动作
    case search, back, forward, expand, collapse, close, clear, more, add, remove
    case check, selected, unselected, success, alert, info, help, addCircle
    case refresh, history, clock, sortAscending, sortDescending, tune, settings
    case copy, trash, openExternal, returnKey, sparkles, hidden, hot, topics, mirror

    // MARK: 播放
    case play, playCircle, pause, stop, previous, next, skip, seek, fullscreen, exitFullscreen
    case lock, unlock, screenshot, subtitle, audio, aspect, aspectFit, aspectFill, aspectStretch
    case speed, playlist, decoder, sleepTimer, nowPlaying
    case brightnessLow, brightnessHigh
    case volumeMute, volumeLow, volumeMedium, volumeHigh
    case playback

    // MARK: 影视内容
    case video, series, tv, poster, posterBatch, posterSearch, rating
    case people, peopleAdd, personUnknown, autoMatch, addToLibrary, device

    // MARK: 文件与网盘
    case folder, folderSettings, file, document, archive, torrentFile
    case link, key, keyHorizontal, privacy, verified, checklist
    case download, cloudDownload, cloudReady, cloudFailed, cloudLocked
    case network, fast, scan, qrScan, switchAccount, logout

    // MARK: 外观
    case appearance, appearanceLight, appearanceDark, appearanceSystem

    /// 线框款（默认）或本来就只有一种样子的图标。
    var name: String {
        switch self {
        case .home: return "house"
        case .library: return "square.grid.2x2"
        case .cloud: return "icloud"
        case .mine: return "person"

        case .search: return "magnifyingglass"
        case .back: return "chevron.left"
        case .forward: return "chevron.right"
        case .expand: return "chevron.down"
        case .collapse: return "chevron.up"
        case .close: return "xmark"
        case .clear: return "xmark.circle.fill"
        case .more: return "ellipsis"
        case .add: return "plus"
        case .addCircle: return "plus.circle"
        case .remove: return "minus.circle"
        case .check: return "checkmark"
        case .selected: return "checkmark.circle.fill"
        case .unselected: return "circle"
        case .success: return "checkmark.circle"
        case .alert: return "exclamationmark.circle"
        case .info: return "info.circle"
        case .help: return "questionmark.circle"
        case .refresh: return "arrow.clockwise"
        case .history: return "clock.arrow.circlepath"
        case .clock: return "clock"
        case .sortAscending: return "arrow.up"
        case .sortDescending: return "arrow.down"
        case .tune: return "slider.horizontal.3"
        case .settings: return "gearshape"
        case .copy: return "doc.on.doc"
        case .trash: return "trash"
        case .hidden: return "eye.slash"
        case .openExternal: return "arrow.up.right.square"
        case .returnKey: return "return"
        case .sparkles: return "sparkles"
        case .hot: return "flame"
        case .topics: return "square.stack"
        case .mirror: return "globe"

        case .play: return "play.fill"
        case .playCircle: return "play.circle.fill"
        case .pause: return "pause.fill"
        case .stop: return "stop.circle"
        case .previous: return "backward.end.fill"
        case .next: return "forward.end.fill"
        case .skip: return "forward.fill"
        case .seek: return "goforward"
        case .fullscreen: return "arrow.up.left.and.arrow.down.right"
        case .exitFullscreen: return "arrow.down.right.and.arrow.up.left"
        case .lock: return "lock.fill"
        case .unlock: return "lock.open"
        case .screenshot: return "camera"
        case .subtitle: return "captions.bubble"
        case .audio: return "waveform"
        case .aspect: return "aspectratio"
        case .aspectFit: return "rectangle.center.inset.filled"
        case .aspectFill: return "rectangle.inset.filled"
        case .aspectStretch: return "arrow.left.and.right.square"
        case .speed: return "speedometer"
        case .playlist: return "list.bullet"
        case .decoder: return "cpu"
        case .sleepTimer: return "timer"
        // 选集里「正在播放」的标记：实心款只用在正在发生的状态上
        case .nowPlaying: return "chart.bar.fill"
        case .brightnessLow: return "sun.min.fill"
        case .brightnessHigh: return "sun.max.fill"
        case .volumeMute: return "speaker.slash.fill"
        case .volumeLow: return "speaker.wave.1.fill"
        case .volumeMedium: return "speaker.wave.2.fill"
        case .volumeHigh: return "speaker.wave.3.fill"
        case .playback: return "play.rectangle"

        case .video: return "film"
        case .series: return "film.stack"
        case .tv: return "tv"
        case .poster: return "photo"
        case .posterBatch: return "photo.on.rectangle.angled"
        case .posterSearch: return "photo.badge.magnifyingglass"
        case .rating: return "star.fill"
        case .people: return "person.2"
        case .peopleAdd: return "person.2.badge.plus"
        case .personUnknown: return "person.crop.circle.badge.questionmark"
        case .autoMatch: return "sparkle.magnifyingglass"
        case .addToLibrary: return "rectangle.stack.badge.plus"
        case .device: return "iphone"

        case .folder: return "folder"
        case .folderSettings: return "folder.badge.gearshape"
        case .file: return "doc"
        case .document: return "doc.text"
        case .archive: return "doc.zipper"
        case .torrentFile: return "doc.badge.arrow.up"
        case .link: return "link"
        case .key: return "key"
        case .keyHorizontal: return "key.horizontal"
        case .privacy: return "lock.shield"
        case .verified: return "checkmark.shield.fill"
        case .checklist: return "checklist"
        case .download: return "arrow.down.to.line"
        case .cloudDownload: return "icloud.and.arrow.down"
        case .cloudReady: return "checkmark.icloud.fill"
        case .cloudFailed: return "exclamationmark.icloud"
        case .cloudLocked: return "lock.icloud"
        case .network: return "antenna.radiowaves.left.and.right"
        case .fast: return "bolt.horizontal.circle"
        case .scan: return "viewfinder"
        case .qrScan: return "qrcode.viewfinder"
        case .switchAccount: return "arrow.triangle.2.circlepath"
        case .logout: return "rectangle.portrait.and.arrow.right"

        case .appearance: return "moon"
        case .appearanceLight: return "sun.max.fill"
        case .appearanceDark: return "moon.fill"
        case .appearanceSystem: return "circle.lefthalf.filled"
        }
    }

    /// 被选中时的实心款。只有底部标签用到；其余图标选中时不换样子，只换颜色。
    var activeName: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "square.grid.2x2.fill"
        case .cloud: return "icloud.fill"
        case .mine: return "person.fill"
        default: return name
        }
    }
}

extension Image {
    init(icon: AppIcon, active: Bool = false) {
        self.init(systemName: active ? icon.activeName : icon.name)
    }
}

extension Label where Title == Text, Icon == Image {
    init(_ title: String, icon: AppIcon) {
        self.init(title, systemImage: icon.name)
    }
}

// MARK: - 统一的图标样式

extension View {
    /// 所有图标共用的字号字重。`size` 决定大小，字重固定为 medium，
    /// 这样列表行、工具栏、卡片角标里的图标线条粗细一致。
    func iconStyle(size: CGFloat = 18, color: Color? = nil) -> some View {
        self
            .font(.system(size: size, weight: Theme.iconWeight))
            .foregroundStyle(color ?? Theme.accent)
            .symbolRenderingMode(.monochrome)
    }
}

/// 圆角方块图标底：琥珀色淡底 + 琥珀色线框图标。列表行、工具卡、设置行都用它。
struct IconTile: View {
    let symbolName: String
    var size: CGFloat = 34
    var tone: Tone = .accent

    init(icon: AppIcon, size: CGFloat = 34, tone: Tone = .accent) {
        self.init(symbolName: icon.name, size: size, tone: tone)
    }

    /// 给还在传 SF Symbol 名字的行用（例如 `LibraryActionRow`）；名字本身必须来自 `AppIcon`。
    init(symbolName: String, size: CGFloat = 34, tone: Tone = .accent) {
        self.symbolName = symbolName
        self.size = size
        self.tone = tone
    }

    enum Tone {
        case accent, neutral, danger

        var foreground: Color {
            switch self {
            case .accent: return Theme.accent
            case .neutral: return Theme.textSecondary
            case .danger: return Theme.danger
            }
        }

        var background: Color {
            switch self {
            case .accent: return Theme.tileTint
            case .neutral: return Theme.surfaceRaised
            case .danger: return Theme.danger.opacity(0.14)
            }
        }
    }

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: size * 0.5, weight: Theme.iconWeight))
            .foregroundStyle(tone.foreground)
            .frame(width: size, height: size)
            .background(tone.background, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}
