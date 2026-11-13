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

/// Prism Noir（2.0）：近黑底承载内容，白色是唯一的主操作色，琥珀色标出「在看、更新、我的」，
/// 棱镜渐变（光轨）只用在进度、选中指示、发送与解析中。浅色是同一套色相的冷白版本。
/// 名称沿用 1.x（gold / onPrimary / tileTint …），调用处不用改：
/// `gold` / `primaryAction` 现在是「主操作色」——深色模式为白，浅色模式为墨黑；`onPrimary` 与它反相。
enum Theme {
    static let accentUIColor = UIColor.adaptive(light: UIColor(hex: 0xB26A14), dark: UIColor(hex: 0xE9B061))
    static let accentAltUIColor = UIColor.adaptive(light: UIColor(hex: 0x8A5210), dark: UIColor(hex: 0xF4CB8A))

    /// 琥珀：更新、在看、置顶、链接文字等强调（沿用原琥珀金主题的色值）
    static let accent = Color(uiColor: accentUIColor)
    static let accentAlt = Color(uiColor: accentAltUIColor)
    /// 琥珀实心：开关、角标等实心强调。底色很亮，上面的字和图标用 onAccentFill（深色），不要用白色
    static let accentFill = Color(uiColor: UIColor(hex: 0xE9B061))
    /// 压在琥珀实心上的文字和图标（对比度约 10:1）
    static let onAccentFill = Color(uiColor: UIColor(hex: 0x1A1206))

    /// 主操作色：每屏唯一的主按钮、当前集、选中胶囊、实心角标。深色为白，浅色为墨黑。
    static let gold = Color(uiColor: .adaptive(light: UIColor(hex: 0x111318), dark: UIColor(hex: 0xF5F6F8)))
    static let goldLight = Color(uiColor: .adaptive(light: UIColor(hex: 0x2A2D36), dark: UIColor.white))
    static let goldDeep = Color(uiColor: UIColor(hex: 0xC98A32))
    /// 压在主操作色上的文字和图标（与 gold 反相）
    static let onPrimary = Color(uiColor: .adaptive(light: .white, dark: UIColor(hex: 0x07080B)))
    static let brandNight = Color(uiColor: UIColor(hex: 0x07080B))

    /// 评分星标统一用琥珀色
    static let rating = Color(uiColor: .adaptive(light: UIColor(hex: 0xB26A00), dark: UIColor(hex: 0xFFB547)))
    /// 信息提示（在线状态等）
    static let info = Color(uiColor: .adaptive(light: UIColor(hex: 0x0A73A0), dark: UIColor(hex: 0x45C8F5)))

    /// 来源色点：在线 / 115 / 磁力 / 本地
    enum Source {
        static let online = Color(uiColor: UIColor(hex: 0xE9B061))
        static let cloud115 = Color(uiColor: UIColor(hex: 0x4C8DFF))
        static let magnet = Color(uiColor: UIColor(hex: 0x9A84FF))
        static let local = Color(uiColor: UIColor(hex: 0x33D6A6))
    }

    /// 棱镜光轨的五个色标（青 → 蓝 → 紫 → 玫红 → 珊瑚），与 Prism 应用图标同源。
    static let prismColors: [Color] = ([0x35D0FF, 0x5B7CFF, 0xA45CFF, 0xFF4D8D, 0xFF8A5C] as [UInt32]).map { Color(uiColor: UIColor(hex: $0)) }
    static let prismStops: [Gradient.Stop] = zip(prismColors, [0.0, 0.32, 0.60, 0.84, 1.0] as [CGFloat]).map { Gradient.Stop(color: $0.0, location: $0.1) }

    static let pageBackground = Color(uiColor: .adaptive(light: UIColor(hex: 0xF4F5F8), dark: UIColor(hex: 0x07080B)))
    static let surface = Color(uiColor: .adaptive(light: .white, dark: UIColor(hex: 0x111319)))
    static let surfaceRaised = Color(uiColor: .adaptive(light: UIColor(hex: 0xEBEDF2), dark: UIColor(hex: 0x181B23)))
    static let surfaceHigh = Color(uiColor: .adaptive(light: UIColor(hex: 0xE1E4EB), dark: UIColor(hex: 0x22262F)))
    static let primaryAction = gold
    static let playerBackground = Color(uiColor: UIColor(hex: 0x000000))
    static let playerSurface = Color(uiColor: UIColor(hex: 0x111319))
    static let contentInset: CGFloat = 16

    static let textPrimary = Color(uiColor: .adaptive(light: UIColor(hex: 0x111318), dark: UIColor(hex: 0xF5F6F8)))
    static let textSecondaryUIColor = UIColor.adaptive(light: UIColor(hex: 0x4D5363), dark: UIColor(hex: 0xA9AFBC))
    static let textSecondary = Color(uiColor: textSecondaryUIColor)
    static let textTertiary = Color(uiColor: .adaptive(light: UIColor(hex: 0x626877), dark: UIColor(hex: 0x828999)))
    /// 首页铺的是封面取色的底：上面的灰色次要文字会发闷，改用半透明白，底色偏亮偏暗都看得清。
    static let textSecondaryOnArtwork = Color.white.opacity(0.78)
    static let textTertiaryOnArtwork = Color.white.opacity(0.56)

    static let hairline = Color(uiColor: .adaptive(
        light: UIColor(white: 0, alpha: 0.08),
        dark: UIColor(white: 1, alpha: 0.08)
    ))
    static let track = Color(uiColor: .adaptive(
        light: UIColor(white: 0, alpha: 0.10),
        dark: UIColor(white: 1, alpha: 0.12)
    ))
    static let shadow = Color(uiColor: .adaptive(
        light: UIColor(hex: 0x111318, alpha: 0.06),
        dark: UIColor(white: 0, alpha: 0)
    ))
    /// 图标块、选中行、淡底：中性，不带色相
    static let tileTint = Color(uiColor: .adaptive(
        light: UIColor(white: 0, alpha: 0.05),
        dark: UIColor(white: 1, alpha: 0.08)
    ))

    /// 文件夹图标：橙色背板、黄色前板，放在一块淡灰蓝的圆角底上。
    static let folderBack = Color(uiColor: UIColor(hex: 0xE09A3A))
    static let folderFront = Color(uiColor: UIColor(hex: 0xF3C45C))
    static let folderTile = Color(uiColor: .adaptive(
        light: UIColor(hex: 0xEEF0F4),
        dark: UIColor(white: 1, alpha: 0.09)
    ))

    static let success = Color(uiColor: .adaptive(light: UIColor(hex: 0x11845F), dark: UIColor(hex: 0x33D6A6)))
    static let warning = Color(uiColor: .adaptive(light: UIColor(hex: 0xB26A00), dark: UIColor(hex: 0xFFB547)))
    static let danger = Color(uiColor: .adaptive(light: UIColor(hex: 0xD92D33), dark: UIColor(hex: 0xFF5A5F)))

    /// 所有线框图标统一的字重
    static let iconWeight: Font.Weight = .medium

    /// 圆角台阶：全应用只有这四种
    enum Radius {
        static let poster: CGFloat = 10
        static let tile: CGFloat = 12
        static let card: CGFloat = 16
        static let sheet: CGFloat = 28
    }

    /// 品牌渐变（斜向），用于头像描边、选中描边、品牌图形。
    static var accentGradient: LinearGradient {
        LinearGradient(stops: prismStops, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 光轨：进度条、选中指示条、发送按钮。
    static var prismGradient: LinearGradient {
        LinearGradient(stops: prismStops, startPoint: .leading, endPoint: .trailing)
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

extension Font {
    /// 片名和栏目大标题：系统黑体最粗一档（中文 PingFang SC，西文 SF Pro）。2.0 起不再用衬线。
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .black, design: .default)
    }
}

// MARK: - 卡片与玻璃

extension View {
    /// iOS 26 用 Liquid Glass，低版本降级成毛玻璃
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 26) -> some View {
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

    /// 内容卡片：浅色模式是白底加柔和投影，深色模式是抬高一层的灰底。
    func surfaceCard(cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        self
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            }
            .shadow(color: Theme.shadow, radius: 10, x: 0, y: 4)
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
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .foregroundStyle(prominent ? Theme.onPrimary : Color.primary)
                .background {
                    if prominent {
                        Capsule().fill(Theme.primaryAction)
                    }
                }
                .modifier(ConditionalGlass(prominent: prominent))
        }
        .buttonStyle(.plain)
    }
}

private struct ConditionalGlass: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            content.shadow(color: Color.black.opacity(0.28), radius: 12, x: 0, y: 6)
        } else {
            content.glassInteractiveCapsule()
        }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title2.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 列表分组标题（卡片上方的小标题）
struct GroupLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 海报和缩略图底部的进度线：3pt 的光轨细线，压在半透明的轨道上。
struct GlassProgressBar: View {
    /// 0...1
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.18))
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
