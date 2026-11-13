import SwiftUI
import UIKit
import CoreText

// MARK: - 外观模式

/// 用户在「设置 → 外观」里选择的显示模式。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "hplayer.appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var symbol: String {
        switch self {
        case .system: return AppIcon.appearanceSystem.name
        case .light: return AppIcon.appearanceLight.name
        case .dark: return AppIcon.appearanceDark.name
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 直接设置窗口的 overrideUserInterfaceStyle。
/// 比 `.preferredColorScheme` 可靠：从深色切回「跟随系统」时不会卡在旧的模式上。
@MainActor
enum AppearanceController {
    static func apply(_ mode: AppearanceMode) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = mode.interfaceStyle
            }
        }
    }
}

// MARK: - 颜色

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    static func adaptive(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light }
    }
}

/// 暗房社论（Darkroom Editorial，3.0）：暖黑与纸色打底，墨色 / 纸色是唯一的主操作色，
/// 一种褪了色的朱砂只标出「在看、更新、选中、进行中」，铜金只给评分和排名。
/// 层级靠底色的深浅和细线，不用投影；圆角偏小，像印刷品。完整规范见仓库根目录 `.interface-design/system.md`。
/// 名称沿用 1.x / 2.0（gold / onPrimary / tileTint / prismGradient …），调用处不用改，只换了取值。
enum Theme {
    // MARK: 墨与纸：页面、表面、控件
    // 同一种暖色相，只改明度：页面 → 卡片 → 弹层 → 控件，每一级只差几个百分点。

    /// 页面底：暗房的暖黑 / 旧纸
    static let pageBackground = Color(uiColor: .adaptive(light: UIColor(hex: 0xF5F0E7), dark: UIColor(hex: 0x15120F)))
    /// 卡片、分组、列表行（第一级）
    static let surface = Color(uiColor: .adaptive(light: UIColor(hex: 0xFBF8F2), dark: UIColor(hex: 0x1E1A16)))
    /// 抬高一层：弹层、底部面板、轻提示、封面占位
    static let surfaceRaised = Color(uiColor: .adaptive(light: UIColor(hex: 0xECE5D8), dark: UIColor(hex: 0x28231E)))
    /// 控件底：次按钮、分段选中块
    static let surfaceHigh = Color(uiColor: .adaptive(light: UIColor(hex: 0xE3DACB), dark: UIColor(hex: 0x332D26)))
    /// 输入框底：比周围略深一点，表示「往里写」
    static let inputFill = Color(uiColor: .adaptive(light: UIColor(hex: 0xEDE6DA), dark: UIColor(hex: 0x100D0B)))

    // MARK: 文字（四级）

    static let textPrimary = Color(uiColor: .adaptive(light: UIColor(hex: 0x1C1814), dark: UIColor(hex: 0xF1EAE0)))
    static let textSecondaryUIColor = UIColor.adaptive(light: UIColor(hex: 0x5C5348), dark: UIColor(hex: 0xB4AA9C))
    static let textSecondary = Color(uiColor: textSecondaryUIColor)
    static let textTertiary = Color(uiColor: .adaptive(light: UIColor(hex: 0x6B6155), dark: UIColor(hex: 0x978C7F)))
    /// 第四级：不可用、占位。刻意不满足正文对比度，只用在禁用态和输入框占位字。
    static let textMuted = Color(uiColor: .adaptive(light: UIColor(hex: 0xA39886), dark: UIColor(hex: 0x6E655A)))
    /// 首页铺的是封面取色的底：上面的灰色次要文字会发闷，改用半透明纸色，底色偏亮偏暗都看得清。
    static let textSecondaryOnArtwork = Color(uiColor: UIColor(hex: 0xF1EAE0, alpha: 0.80))
    static let textTertiaryOnArtwork = Color(uiColor: UIColor(hex: 0xF1EAE0, alpha: 0.58))

    // MARK: 线（层级主要靠它）

    /// 最轻的边：卡片外沿、封面描边、输入框。看不见时不打扰，要找时找得到。
    static let hairline = Color(uiColor: .adaptive(
        light: UIColor(hex: 0x1C1814, alpha: 0.10),
        dark: UIColor(hex: 0xF1EAE0, alpha: 0.09)
    ))
    /// 分隔线：列表行之间、栏目标题下的细线（1pt）
    static let rule = Color(uiColor: .adaptive(
        light: UIColor(hex: 0x1C1814, alpha: 0.14),
        dark: UIColor(hex: 0xF1EAE0, alpha: 0.13)
    ))
    /// 强调边：未选中但可点的筛选块、次按钮外框
    static let ruleStrong = Color(uiColor: .adaptive(
        light: UIColor(hex: 0x1C1814, alpha: 0.26),
        dark: UIColor(hex: 0xF1EAE0, alpha: 0.24)
    ))
    /// 进度条、开关之类的轨道
    static let track = Color(uiColor: .adaptive(
        light: UIColor(hex: 0x1C1814, alpha: 0.10),
        dark: UIColor(hex: 0xF1EAE0, alpha: 0.12)
    ))
    /// 3.0 起不用投影：保留这个名字只为了旧调用处编译通过，两种模式下都是透明。
    static let shadow = Color.clear
    /// 图标块、选中行、淡底：同一暖色相的极淡一层
    static let tileTint = Color(uiColor: .adaptive(
        light: UIColor(hex: 0x1C1814, alpha: 0.05),
        dark: UIColor(hex: 0xF1EAE0, alpha: 0.07)
    ))
    /// 按下时压在控件上的一层（不改尺寸，只改明度）
    static let pressTint = Color(uiColor: .adaptive(
        light: UIColor(hex: 0x1C1814, alpha: 0.08),
        dark: UIColor(hex: 0xF1EAE0, alpha: 0.10)
    ))
    /// 弹层后面的遮罩
    static let scrim = Color(uiColor: UIColor(hex: 0x0B0907, alpha: 0.48))
    /// 压在封面上的小标签底：近黑暖色，任何画面上都清楚
    static let badgeScrim = Color(uiColor: UIColor(hex: 0x15120F, alpha: 0.80))

    // MARK: 主操作色（墨 / 纸）

    /// 主操作色：每屏唯一的主按钮、当前集、选中块、勾选。深色模式是纸色，浅色模式是墨色。
    static let gold = Color(uiColor: .adaptive(light: UIColor(hex: 0x1C1814), dark: UIColor(hex: 0xF1EAE0)))
    static let goldLight = Color(uiColor: .adaptive(light: UIColor(hex: 0x3A332B), dark: UIColor(hex: 0xFBF8F2)))
    static let goldDeep = Color(uiColor: .adaptive(light: UIColor(hex: 0x7E3C2B), dark: UIColor(hex: 0xB86E58)))
    static let primaryAction = gold
    /// 压在主操作色上的文字和图标（与 gold 反相）
    static let onPrimary = Color(uiColor: .adaptive(light: UIColor(hex: 0xFBF8F2), dark: UIColor(hex: 0x15120F)))
    /// 固定的墨色与纸色：不随深浅模式变，用在始终是深色的画面上（播放页、封面上的按钮）
    static let ink = Color(uiColor: UIColor(hex: 0x15120F))
    static let paper = Color(uiColor: UIColor(hex: 0xF1EAE0))
    static let brandNight = ink

    // MARK: 强调（褪色朱砂，全应用唯一的彩色）

    static let accentUIColor = UIColor.adaptive(light: UIColor(hex: 0x9A4C37), dark: UIColor(hex: 0xCF8770))
    static let accentAltUIColor = UIColor.adaptive(light: UIColor(hex: 0x7E3C2B), dark: UIColor(hex: 0xE0A592))
    /// 朱砂：更新、在看、进行中的数量、链接文字。文字和细线用它，不做大面积底色。
    static let accent = Color(uiColor: accentUIColor)
    static let accentAlt = Color(uiColor: accentAltUIColor)
    /// 朱砂实心：开关、实心角标。上面的字和图标用 onAccentFill。
    static let accentFill = Color(uiColor: accentUIColor)
    /// 压在朱砂实心上的文字（浅色模式纸色 6:1，深色模式墨色 6.5:1）
    static let onAccentFill = Color(uiColor: .adaptive(light: UIColor(hex: 0xFBF8F2), dark: UIColor(hex: 0x15120F)))
    /// 朱砂淡底：选中行、强调提示的底色（12%）
    static let accentWash = Color(uiColor: .adaptive(
        light: UIColor(hex: 0x9A4C37, alpha: 0.10),
        dark: UIColor(hex: 0xCF8770, alpha: 0.14)
    ))

    // MARK: 铜金（只给评分、排名数字）

    static let brass = Color(uiColor: .adaptive(light: UIColor(hex: 0x7C5A2A), dark: UIColor(hex: 0xC9A26B)))
    /// 评分星标和数字
    static let rating = brass
    /// 压在封面暗底上的评分（不随模式变）
    static let ratingOnArtwork = Color(uiColor: UIColor(hex: 0xD8B47E))

    // MARK: 语义色（降饱和，和纸色同温度）

    static let success = Color(uiColor: .adaptive(light: UIColor(hex: 0x356B41), dark: UIColor(hex: 0x7FB685)))
    static let warning = brass
    static let danger = Color(uiColor: .adaptive(light: UIColor(hex: 0xB3261E), dark: UIColor(hex: 0xEF6A5B)))
    /// 危险按钮的实心底（上面放白字，两种模式都 ≥ 5.6:1）
    static let dangerFill = Color(uiColor: .adaptive(light: UIColor(hex: 0xB3261E), dark: UIColor(hex: 0xB3412F)))
    /// 信息提示不再单独用蓝色，和次要文字同色
    static let info = textSecondary

    /// 来源色点：在线 / 115 / 磁力 / 本地。降到和纸色同温度的灰调，只区分类别，不抢强调色。
    enum Source {
        static let online = Theme.accent
        static let cloud115 = Color(uiColor: .adaptive(light: UIColor(hex: 0x4E6676), dark: UIColor(hex: 0x8FA4B3)))
        static let magnet = Color(uiColor: .adaptive(light: UIColor(hex: 0x6B5873), dark: UIColor(hex: 0xA08AA6)))
        static let local = Color(uiColor: .adaptive(light: UIColor(hex: 0x4E6B4C), dark: UIColor(hex: 0x8DAA8A)))
    }

    /// 棱镜五色只留给品牌标志（H 标志、应用图标）和弹幕取色，界面里不再用作装饰。
    static let prismColors: [Color] = ([0x35D0FF, 0x5B7CFF, 0xA45CFF, 0xFF4D8D, 0xFF8A5C] as [UInt32]).map { Color(uiColor: UIColor(hex: $0)) }
    static let prismStops: [Gradient.Stop] = zip(prismColors, [0.0, 0.32, 0.60, 0.84, 1.0] as [CGFloat]).map { Gradient.Stop(color: $0.0, location: $0.1) }

    /// 文件夹图标：铜色背板、纸黄前板
    static let folderBack = Color(uiColor: UIColor(hex: 0xA27C4B))
    static let folderFront = Color(uiColor: UIColor(hex: 0xD6B583))
    static let folderTile = Color(uiColor: .adaptive(
        light: UIColor(hex: 0xECE5D8),
        dark: UIColor(hex: 0xF1EAE0, alpha: 0.07)
    ))

    static let playerBackground = Color(uiColor: UIColor(hex: 0x000000))
    static let playerSurface = Color(uiColor: UIColor(hex: 0x1E1A16))

    // MARK: 间距（4pt 网格）

    /// 页面左右边距
    static let contentInset: CGFloat = Space.page

    enum Space {
        /// 2：图标和角标里的微调
        static let hair: CGFloat = 2
        /// 4：同一组里的紧密元素（标题与副标题）
        static let xs: CGFloat = 4
        /// 8：组件内部的间隙（图标与文字）
        static let sm: CGFloat = 8
        /// 12：卡片与卡片、网格的间隙
        static let md: CGFloat = 12
        /// 16：卡片内边距、行的左右内边距
        static let lg: CGFloat = 16
        /// 20：页面左右边距
        static let page: CGFloat = 20
        /// 24：分组之间
        static let xl: CGFloat = 24
        /// 32：页面里的大段落之间
        static let section: CGFloat = 32
        /// 40：首页货架之间
        static let shelf: CGFloat = 40
    }

    // MARK: 线宽

    enum Stroke {
        /// 外沿、描边
        static let hairline: CGFloat = 0.5
        /// 分隔线、焦点环
        static let rule: CGFloat = 1
    }

    /// 所有线框图标统一的字重（社论风偏细）
    static let iconWeight: Font.Weight = .regular

    /// 圆角台阶：小而克制，像印刷品。嵌套时外层 = 内层 + 内边距。
    enum Radius {
        /// 封面上的小标签
        static let badge: CGFloat = 3
        /// 海报、缩略图
        static let poster: CGFloat = 4
        /// 筛选块、分段里的选中块
        static let chip: CGFloat = 6
        /// 按钮、输入框
        static let control: CGFloat = 8
        /// 小块（图标底、封面占位、缩略图组）
        static let tile: CGFloat = 8
        /// 卡片、分组、轻提示
        static let card: CGFloat = 12
        /// 自己画的底部面板、浮动操作栏
        static let sheet: CGFloat = 16
    }

    /// 2.0 的棱镜渐变改成朱砂实色：进度、选中指示、发送按钮都用它，调用处不用改。
    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accent], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 进度条、选中指示条
    static var prismGradient: LinearGradient {
        LinearGradient(colors: [accent, accent], startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - 封面色底上的文字

private struct ArtworkTintedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 这一块铺在封面取色的底上（首页）。卡片、货架标题据此换用 `textSecondaryOnArtwork` 这一组颜色。
    var artworkTinted: Bool {
        get { self[ArtworkTintedKey.self] }
        set { self[ArtworkTintedKey.self] = newValue }
    }
}

private struct TintAwareForeground: ViewModifier {
    let tertiary: Bool
    @Environment(\.artworkTinted) private var artworkTinted

    private var color: Color {
        if artworkTinted { return tertiary ? Theme.textTertiaryOnArtwork : Theme.textSecondaryOnArtwork }
        return tertiary ? Theme.textTertiary : Theme.textSecondary
    }

    func body(content: Content) -> some View {
        content.foregroundStyle(color)
    }
}

extension View {
    /// 次要文字：普通页面用主题灰，铺了封面色的首页用半透明白。
    func secondaryTextStyle() -> some View { modifier(TintAwareForeground(tertiary: false)) }
    /// 三级文字（数量、注释）：同上。
    func tertiaryTextStyle() -> some View { modifier(TintAwareForeground(tertiary: true)) }
}

// MARK: - 字体

/// 标题用的宋体（Songti SC）。它不随系统预装，是苹果的按需下载字体：
/// 启动时请求一次（已下载过的话立刻激活），没就绪前标题回落到系统衬线体（西文 New York）。
enum EditorialFont {
    static let boldName = "STSongti-SC-Bold"
    static let regularName = "STSongti-SC-Regular"

    private static var ready = false
    private static var lastCheck: TimeInterval = 0

    /// 宋体已在本进程可用。就绪后不再查；没就绪时最多每 2 秒查一次（标题渲染很频繁）。
    static var isReady: Bool {
        if ready { return true }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastCheck > 2 else { return false }
        lastCheck = now
        ready = UIFont(name: boldName, size: 17) != nil
        return ready
    }

    /// 在 App 启动时调用一次。单元测试里不请求，结果保持确定。
    static func prepare() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil, !isReady else { return }
        let descriptors = [boldName, regularName].map {
            CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: $0] as CFDictionary)
        }
        _ = CTFontDescriptorMatchFontDescriptorsWithProgressHandler(descriptors as CFArray, nil) { _, _ in true }
    }
}

extension Font {
    /// 标题字（片名、页面大标题、栏目标题、统计数字）：宋体粗体，跟随系统字号缩放。
    /// `size` 是默认字号下的大小，`relativeTo` 决定随「更大字体」怎么放大。
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle? = nil) -> Font {
        let anchor: Font.TextStyle = style ?? (size >= 30 ? .largeTitle : size >= 24 ? .title : size >= 19 ? .title3 : .headline)
        if EditorialFont.isReady {
            return .custom(EditorialFont.boldName, size: size, relativeTo: anchor)
        }
        return .system(size: UIFontMetrics(forTextStyle: anchor.uiTextStyle).scaledValue(for: size),
                       weight: .bold, design: .serif)
    }

    /// 排名、序号这类「印刷数字」：衬线斜体（New York），铜金色配合使用。
    static func numeral(_ size: CGFloat) -> Font {
        .system(size: UIFontMetrics(forTextStyle: .title2).scaledValue(for: size), weight: .semibold, design: .serif).italic()
    }
}

private extension Font.TextStyle {
    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
}

extension Theme {
    /// 字号阶梯。标题是宋体（衬线），其余全是系统字体（苹方 / SF），都跟随系统字号。
    /// 最小 11pt；字重最多到 semibold，标题的粗由宋体 Bold 负责。时间、集数、容量一律 `.monospacedDigit()`。
    enum Typo {
        /// 一级页面大标题：宋体 30（largeTitle 缩放）
        static var pageTitle: Font { .display(30, relativeTo: .largeTitle) }
        /// 详情页片名：宋体 26
        static var detailTitle: Font { .display(26, relativeTo: .title) }
        /// 栏目 / 货架标题：宋体 20
        static var section: Font { .display(20, relativeTo: .title3) }
        /// 卡片标题、强调行：17 semibold
        static let headline = Font.headline
        /// 正文：17
        static let body = Font.body
        /// 列表行标题、按钮：15
        static let row = Font.subheadline
        /// 按钮文字：15 semibold
        static let button = Font.subheadline.weight(.semibold)
        /// 辅助信息、行尾数值：13
        static let meta = Font.footnote
        /// 卡片下的小字、说明：12
        static let caption = Font.caption
        /// 封面上的角标：11 semibold（全应用最小字号）
        static let badge = Font.caption2.weight(.semibold)
    }
}

// MARK: - 卡片与玻璃

extension View {
    /// iOS 26 用 Liquid Glass，低版本降级成毛玻璃
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = Theme.Radius.sheet) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self.background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }

    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5) }
        }
    }

    @ViewBuilder
    func glassInteractiveCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5) }
        }
    }

    /// 浮在画面上的玻璃圆钮。iOS 26 用可交互的 Liquid Glass，低版本降级成毛玻璃。
    @ViewBuilder
    func glassCircle() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Circle())
        } else {
            self.background(.ultraThinMaterial, in: Circle())
                .overlay { Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5) }
        }
    }

    /// 带品牌色的玻璃胶囊，用在播放这类主操作上。
    @ViewBuilder
    func glassProminentCapsule(tint: Color = Theme.primaryAction) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.tint(tint).interactive(), in: Capsule())
        } else {
            self.background(tint, in: Capsule())
                .overlay { Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5) }
        }
    }

    /// 带品牌色的玻璃圆钮
    @ViewBuilder
    func glassProminentCircle(tint: Color = Theme.primaryAction) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.tint(tint).interactive(), in: Circle())
        } else {
            self.background(tint, in: Circle())
                .overlay { Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5) }
        }
    }

    /// 内容卡片：比页面高一级的纸面，外沿一圈细线。不用投影。
    func surfaceCard(cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        self
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline)
            }
    }

    /// 浮在内容上的一层（轻提示、浮动操作栏、操作中卡片）：抬高一级的底色 + 分隔线粗细的边。
    /// 层级靠底色和线区分，不用投影。
    func floatingSurface(cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        self
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.rule, lineWidth: Theme.Stroke.rule)
            }
    }

    /// 输入框外观：比周围略深的底 + 细边；获得焦点时边变成 1pt 朱砂。
    /// 搜索框、表单输入框都用它，形状统一是 8pt 圆角矩形。
    func fieldChrome(focused: Bool = false, enabled: Bool = true) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        return self
            .background(Theme.inputFill, in: shape)
            .overlay {
                shape.strokeBorder(focused ? Theme.accent : Theme.hairline,
                                   lineWidth: focused ? Theme.Stroke.rule : Theme.Stroke.hairline)
            }
            .opacity(enabled ? 1 : 0.55)
            .animation(Motion.quick, value: focused)
    }

    /// 自定义底部面板统一的外观：纸面底、16pt 圆角、显示拖动条（iOS 16.4 起；更早的系统用默认样式）。
    @ViewBuilder
    func designSheet() -> some View {
        if #available(iOS 16.4, *) {
            self
                .presentationBackground(Theme.surface)
                .presentationCornerRadius(Theme.Radius.sheet)
                .presentationDragIndicator(.visible)
        } else {
            self.presentationDragIndicator(.visible)
        }
    }
}

/// 胶囊按钮：图标 + 文字
struct GlassCapsuleButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(Theme.Typo.button)
                .padding(.horizontal, Theme.Space.page)
                .padding(.vertical, Theme.Space.md)
                .foregroundStyle(prominent ? Theme.onPrimary : Color.primary)
                .background {
                    if prominent {
                        Capsule().fill(Theme.primaryAction)
                    }
                }
                .modifier(ConditionalGlass(prominent: prominent))
                .hoverEffect(.highlight)
        }
        .buttonStyle(.pressable(scale: 0.98))
    }
}

private struct ConditionalGlass: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            // 实心主按钮自己就够醒目，不加投影
            content
        } else {
            content.glassInteractiveCapsule()
        }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Theme.Typo.section)
            .foregroundStyle(Theme.textPrimary)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 列表分组标题（卡片上方的小标题）
struct GroupLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Theme.Typo.meta.weight(.medium))
            .foregroundStyle(Theme.textTertiary)
            .padding(.leading, Theme.Space.xs)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 海报和缩略图底部的进度线：3pt 的朱砂细线，压在半透明的纸色轨道上。
struct GlassProgressBar: View {
    /// 0...1
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.paper.opacity(0.20))
                Rectangle()
                    .fill(Theme.prismGradient)
                    .frame(width: max(0, proxy.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 3)
        .accessibilityElement()
        .accessibilityLabel("已看 \(Int((min(max(value, 0), 1) * 100).rounded()))%")
    }
}

/// 只有上面两个角是圆角的矩形，首页内容区用它盖住横幅下沿。
struct TopRoundedRectangle: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: [.topLeft, .topRight],
            cornerRadii: CGSize(width: radius, height: radius)
        ).cgPath)
    }
}
