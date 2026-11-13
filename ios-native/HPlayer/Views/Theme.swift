import SwiftUI
import UIKit

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

/// 放映厅（Screening Room，3.0 · 方案 A）：克制精密的石墨灰阶。整个界面基本是灰阶，
/// 唯一亮起来的颜色是琥珀——观看进度、「在看 / 更新」和进行中的数量，像暗场里只有放映机那一束光。
/// 主操作色是白（深色）/ 墨黑（浅色）。层级靠底色深浅和细线，卡片不用投影，只有浮层在浅色模式下带一层轻投影。
/// 完整规范见仓库根目录 `.interface-design/system.md`。
/// 名称沿用 1.x / 2.0（gold / onPrimary / tileTint / prismGradient …），调用处不用改，只换了取值。
enum Theme {
    // MARK: 石墨：页面、表面、控件
    // 中性灰，只改明度：页面 → 卡片 → 弹层 → 控件，每一级只差几个百分点。

    /// 页面底
    static let pageBackground = Color(uiColor: .adaptive(light: UIColor(hex: 0xF7F7F8), dark: UIColor(hex: 0x0A0A0B)))
    /// 卡片、分组、列表行（第一级）
    static let surface = Color(uiColor: .adaptive(light: UIColor(hex: 0xFFFFFF), dark: UIColor(hex: 0x141416)))
    /// 抬高一层：弹层、底部面板、轻提示、封面占位
    static let surfaceRaised = Color(uiColor: .adaptive(light: UIColor(hex: 0xEFEFF1), dark: UIColor(hex: 0x1C1C1F)))
    /// 控件底：分段选中块
    static let surfaceHigh = Color(uiColor: .adaptive(light: UIColor(hex: 0xE6E6E9), dark: UIColor(hex: 0x26262A)))
    /// 输入框底：比周围略深一点，表示「往里写」
    static let inputFill = Color(uiColor: .adaptive(light: UIColor(hex: 0xEFEFF1), dark: UIColor(hex: 0x060607)))

    // MARK: 文字（四级）

    static let textPrimary = Color(uiColor: .adaptive(light: UIColor(hex: 0x111113), dark: UIColor(hex: 0xEDEDEF)))
    static let textSecondaryUIColor = UIColor.adaptive(light: UIColor(hex: 0x52525B), dark: UIColor(hex: 0xA1A1AA))
    static let textSecondary = Color(uiColor: textSecondaryUIColor)
    static let textTertiary = Color(uiColor: .adaptive(light: UIColor(hex: 0x62626B), dark: UIColor(hex: 0x85858E)))
    /// 第四级：不可用、占位。刻意不满足正文对比度，只用在禁用态和占位字。
    static let textMuted = Color(uiColor: .adaptive(light: UIColor(hex: 0xA1A1AA), dark: UIColor(hex: 0x5A5A62)))
    /// 首页铺的是封面取色的底：上面的灰色次要文字会发闷，改用半透明白，底色偏亮偏暗都看得清。
    static let textSecondaryOnArtwork = Color.white.opacity(0.78)
    static let textTertiaryOnArtwork = Color.white.opacity(0.56)

    // MARK: 线

    /// 最轻的边：卡片外沿、封面描边、输入框
    static let hairline = Color(uiColor: .adaptive(
        light: UIColor(white: 0, alpha: 0.08),
        dark: UIColor(white: 1, alpha: 0.07)
    ))
    /// 分隔线：列表行之间、浮层边
    static let rule = Color(uiColor: .adaptive(
        light: UIColor(white: 0, alpha: 0.10),
        dark: UIColor(white: 1, alpha: 0.10)
    ))
    /// 强调边：未选中的勾选圈、描边标签
    static let ruleStrong = Color(uiColor: .adaptive(
        light: UIColor(white: 0, alpha: 0.22),
        dark: UIColor(white: 1, alpha: 0.20)
    ))
    /// 进度条、开关之类的轨道
    static let track = Color(uiColor: .adaptive(
        light: UIColor(white: 0, alpha: 0.10),
        dark: UIColor(white: 1, alpha: 0.12)
    ))
    /// 卡片不用投影：保留这个名字只为了旧调用处编译通过，两种模式下都是透明。
    static let shadow = Color.clear
    /// 浮层（轻提示、浮动操作栏）的投影：只在浅色模式出现；深色模式投影看不出来，靠底色和线。
    static let floatShadow = Color(uiColor: .adaptive(
        light: UIColor(white: 0, alpha: 0.12),
        dark: UIColor(white: 0, alpha: 0)
    ))
    /// 图标块、选中行、淡底
    static let tileTint = Color(uiColor: .adaptive(
        light: UIColor(white: 0, alpha: 0.05),
        dark: UIColor(white: 1, alpha: 0.06)
    ))
    /// 按下时压在控件上的一层（不改尺寸，只改明度）
    static let pressTint = Color(uiColor: .adaptive(
        light: UIColor(white: 0, alpha: 0.07),
        dark: UIColor(white: 1, alpha: 0.08)
    ))
    /// 弹层后面的遮罩
    static let scrim = Color.black.opacity(0.5)
    /// 压在封面上的小标签底：近黑半透明，任何画面上都清楚
    static let badgeScrim = Color(uiColor: UIColor(hex: 0x0A0A0B, alpha: 0.78))

    // MARK: 主操作色（白 / 墨）

    /// 主操作色：每屏唯一的主按钮、当前集、选中胶囊、勾选。深色模式为白，浅色模式为墨黑。
    static let gold = Color(uiColor: .adaptive(light: UIColor(hex: 0x111113), dark: UIColor(hex: 0xF5F5F6)))
    static let goldLight = Color(uiColor: .adaptive(light: UIColor(hex: 0x2A2A2E), dark: UIColor.white))
    static let goldDeep = Color(uiColor: .adaptive(light: UIColor(hex: 0x6E4C06), dark: UIColor(hex: 0xC98A32)))
    static let primaryAction = gold
    /// 压在主操作色上的文字和图标（与 gold 反相）
    static let onPrimary = Color(uiColor: .adaptive(light: .white, dark: UIColor(hex: 0x0A0A0B)))
    /// 固定的墨色与白：不随深浅模式变，用在始终是深色的画面上（播放页、封面上的按钮）
    static let ink = Color(uiColor: UIColor(hex: 0x0A0A0B))
    static let paper = Color(uiColor: UIColor(hex: 0xF5F5F6))
    static let brandNight = ink

    // MARK: 强调（琥珀，全应用唯一的彩色）

    static let accentUIColor = UIColor.adaptive(light: UIColor(hex: 0x8A6008), dark: UIColor(hex: 0xE6A54B))
    static let accentAltUIColor = UIColor.adaptive(light: UIColor(hex: 0x6E4C06), dark: UIColor(hex: 0xF0C07A))
    /// 琥珀：观看进度、更新、在看、进行中的数量、焦点。文字、细线、进度用它，不做大面积底色。
    static let accent = Color(uiColor: accentUIColor)
    static let accentAlt = Color(uiColor: accentAltUIColor)
    /// 琥珀实心：开关、实心角标。上面的字和图标用 onAccentFill。
    static let accentFill = Color(uiColor: accentUIColor)
    /// 压在琥珀实心上的文字（浅色模式白字 5.6:1，深色模式墨字 9.3:1）
    static let onAccentFill = Color(uiColor: .adaptive(light: .white, dark: UIColor(hex: 0x0A0A0B)))
    /// 琥珀淡底：选中行、强调提示的底色
    static let accentWash = Color(uiColor: .adaptive(
        light: UIColor(hex: 0x8A6008, alpha: 0.10),
        dark: UIColor(hex: 0xE6A54B, alpha: 0.14)
    ))

    /// 评分和排名也用琥珀（方案 A 不另设铜金）
    static let brass = accent
    static let rating = accent
    /// 压在封面暗底上的评分（不随模式变）
    static let ratingOnArtwork = Color(uiColor: UIColor(hex: 0xE6A54B))

    // MARK: 语义色

    static let success = Color(uiColor: .adaptive(light: UIColor(hex: 0x16754D), dark: UIColor(hex: 0x4CC38A)))
    static let warning = Color(uiColor: .adaptive(light: UIColor(hex: 0xA84A16), dark: UIColor(hex: 0xF0884B)))
    static let danger = Color(uiColor: .adaptive(light: UIColor(hex: 0xC42B33), dark: UIColor(hex: 0xF2555A)))
    /// 危险按钮的实心底（上面放白字，两种模式都 ≥ 5:1）
    static let dangerFill = Color(uiColor: .adaptive(light: UIColor(hex: 0xC42B33), dark: UIColor(hex: 0xC9363D)))
    /// 信息提示不单独用蓝色，和次要文字同色
    static let info = textSecondary

    /// 来源色点：在线 / 115 / 磁力 / 本地。低饱和的灰调，只区分类别，不抢琥珀。
    enum Source {
        static let online = Theme.accent
        static let cloud115 = Color(uiColor: .adaptive(light: UIColor(hex: 0x46617A), dark: UIColor(hex: 0x7E9CB8)))
        static let magnet = Color(uiColor: .adaptive(light: UIColor(hex: 0x5E5480), dark: UIColor(hex: 0x9C8FC0)))
        static let local = Color(uiColor: .adaptive(light: UIColor(hex: 0x3F6E55), dark: UIColor(hex: 0x7FB89A)))
    }

    /// 棱镜五色只留给品牌标志（H 标志、应用图标）和弹幕取色，界面里不再用作装饰。
    static let prismColors: [Color] = ([0x35D0FF, 0x5B7CFF, 0xA45CFF, 0xFF4D8D, 0xFF8A5C] as [UInt32]).map { Color(uiColor: UIColor(hex: $0)) }
    static let prismStops: [Gradient.Stop] = zip(prismColors, [0.0, 0.32, 0.60, 0.84, 1.0] as [CGFloat]).map { Gradient.Stop(color: $0.0, location: $0.1) }

    /// 文件夹图标：琥珀背板、浅琥珀前板
    static let folderBack = Color(uiColor: UIColor(hex: 0xC99A52))
    static let folderFront = Color(uiColor: UIColor(hex: 0xE8C27F))
    static let folderTile = Color(uiColor: .adaptive(
        light: UIColor(hex: 0xEFEFF1),
        dark: UIColor(white: 1, alpha: 0.07)
    ))

    static let playerBackground = Color(uiColor: UIColor(hex: 0x000000))
    static let playerSurface = Color(uiColor: UIColor(hex: 0x141416))

    // MARK: 间距（4pt 网格，偏紧凑）

    /// 页面左右边距
    static let contentInset: CGFloat = Space.page

    enum Space {
        /// 2：图标和角标里的微调
        static let hair: CGFloat = 2
        /// 4：同一组里的紧密元素（标题与副标题）
        static let xs: CGFloat = 4
        /// 8：组件内部的间隙、标题到内容
        static let sm: CGFloat = 8
        /// 12：卡片内的段落间隙
        static let md: CGFloat = 12
        /// 16：页面边距、卡片内边距、行的左右内边距
        static let lg: CGFloat = 16
        /// 16：页面左右边距
        static let page: CGFloat = 16
        /// 24：分组之间
        static let xl: CGFloat = 24
        /// 32：页面里的大段落之间
        static let section: CGFloat = 32
        /// 32：首页货架之间
        static let shelf: CGFloat = 32
    }

    // MARK: 线宽

    enum Stroke {
        /// 外沿、描边、分隔线
        static let hairline: CGFloat = 0.5
        /// 焦点环、次按钮外框
        static let rule: CGFloat = 1
    }

    /// 所有线框图标统一的字重
    static let iconWeight: Font.Weight = .medium

    /// 圆角台阶。嵌套时外层 = 内层 + 内边距。主按钮和筛选块不用这里的值，直接是胶囊（`Capsule`）。
    enum Radius {
        /// 封面上的小标签
        static let badge: CGFloat = 4
        /// 海报、缩略图
        static let poster: CGFloat = 8
        /// 分段里的选中块
        static let chip: CGFloat = 8
        /// 次按钮、输入框
        static let control: CGFloat = 10
        /// 小块（图标底、封面占位）
        static let tile: CGFloat = 10
        /// 卡片、分组、轻提示
        static let card: CGFloat = 14
        /// 自己画的底部面板、浮动操作栏
        static let sheet: CGFloat = 20
    }

    /// 叠在画面上的黑 / 白半透明只用这几档（遮罩、渐变、画面上的控件底）。
    enum Opacity {
        static let hint: Double = 0.08
        static let faint: Double = 0.15
        static let soft: Double = 0.25
        static let medium: Double = 0.4
        static let strong: Double = 0.6
        static let heavy: Double = 0.75
        static let solid: Double = 0.9
    }

    /// 外观设置里的小预览图：分别画浅色和深色两种模式，所以取的是两套固定值（和上面的 token 一致）。
    enum Preview {
        static let lightPage = Color(uiColor: UIColor(hex: 0xF7F7F8))
        static let lightCard = Color(uiColor: UIColor(hex: 0xFFFFFF))
        static let lightLine = Color.black.opacity(0.14)
        static let darkPage = Color(uiColor: UIColor(hex: 0x0A0A0B))
        static let darkCard = Color(uiColor: UIColor(hex: 0x1C1C1F))
        static let darkLine = Color.white.opacity(0.3)
        static let accent = Color(uiColor: UIColor(hex: 0xE6A54B))
    }

    /// 2.0 的棱镜渐变改成琥珀实色：进度、选中指示都用它，调用处不用改。
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

extension Font {
    /// 片名和大标题：系统字体粗体（中文苹方，西文 SF Pro），跟随系统字号缩放。
    /// `size` 是默认字号下的大小，`relativeTo` 决定随「更大字体」怎么放大。字重最多 bold，不用 black。
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle? = nil) -> Font {
        let anchor: Font.TextStyle = style ?? (size >= 30 ? .largeTitle : size >= 24 ? .title : size >= 19 ? .title3 : .headline)
        return .system(size: UIFontMetrics(forTextStyle: anchor.uiTextStyle).scaledValue(for: size), weight: .bold)
    }

    /// 页面里原来写死的字号统一走这里：默认字号下大小不变，随系统「更大字体」放大（最多 1.4 倍，免得固定尺寸的控件被撑破），
    /// 最小 11pt。字重最多 bold——传进来的 heavy / black 会降成 bold。
    static func scaled(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        let base = max(size, 11)
        let anchor: Font.TextStyle = base >= 30 ? .largeTitle : base >= 24 ? .title : base >= 19 ? .title3
            : base >= 16 ? .body : base >= 14 ? .subheadline : base >= 12.5 ? .footnote : base >= 11.5 ? .caption : .caption2
        let scaledSize = min(UIFontMetrics(forTextStyle: anchor.uiTextStyle).scaledValue(for: base), base * 1.4)
        let capped: Font.Weight = (weight == .heavy || weight == .black) ? .bold : weight
        return .system(size: scaledSize, weight: capped, design: design)
    }

    /// 排名、序号、统计这类数字：SF 半粗、等宽数字。
    static func numeral(_ size: CGFloat) -> Font {
        .system(size: UIFontMetrics(forTextStyle: .title2).scaledValue(for: size), weight: .semibold).monospacedDigit()
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
    /// 字号阶梯：只用系统字体（苹方 / SF），全部跟随系统字号。
    /// 最小 11pt；字重最多 bold。层级主要靠字重和颜色，而不是字号。时间、集数、容量一律 `.monospacedDigit()`。
    enum Typo {
        /// 一级页面大标题：34 bold
        static let pageTitle = Font.largeTitle.weight(.bold)
        /// 详情页片名：22 bold
        static let detailTitle = Font.title2.weight(.bold)
        /// 栏目 / 货架标题：17 semibold
        static let section = Font.headline
        /// 卡片标题、强调行：17 semibold
        static let headline = Font.headline
        /// 正文：17
        static let body = Font.body
        /// 列表行标题：15
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

    /// 浮在内容上的一层（轻提示、浮动操作栏、操作中卡片）：抬高一级的底色 + 细边；
    /// 浅色模式再加一层轻投影（y 8 · 模糊 24 · 12%），深色模式只靠底色和线。
    func floatingSurface(cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        self
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.rule, lineWidth: Theme.Stroke.hairline)
            }
            .shadow(color: Theme.floatShadow, radius: 12, x: 0, y: 8)
    }

    /// 输入框外观：比周围略深的底 + 细边；获得焦点时边变成 1pt 琥珀。
    /// 搜索框、表单输入框都用它，形状统一是 10pt 圆角矩形。
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

    /// 自定义底部面板统一的外观：卡片底色、20pt 圆角、显示拖动条（iOS 16.4 起；更早的系统用默认样式）。
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

/// 海报和缩略图底部的进度线：3pt 的琥珀细线，压在半透明的白色轨道上。
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
