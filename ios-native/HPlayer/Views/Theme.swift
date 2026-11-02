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

/// 琥珀金 + 黑曜石：深色是影院式的近黑底，浅色是偏暖的纸白底；
/// 主色只用来标出「当前在哪、下一步点哪」，其余全部是中性灰阶。
enum Theme {
    static let accentUIColor = UIColor.adaptive(light: UIColor(hex: 0xB26A14), dark: UIColor(hex: 0xE9B061))
    static let accentAltUIColor = UIColor.adaptive(light: UIColor(hex: 0x8A5210), dark: UIColor(hex: 0xF4CB8A))

    static let accent = Color(uiColor: accentUIColor)
    static let accentAlt = Color(uiColor: accentAltUIColor)

    /// 品牌金，两种模式下保持不变；用在实心按钮、进度条、角标上。
    static let gold = Color(uiColor: UIColor(hex: 0xE9B061))
    static let goldLight = Color(uiColor: UIColor(hex: 0xF4CB8A))
    static let goldDeep = Color(uiColor: UIColor(hex: 0xC98A32))
    /// 压在金色上的文字和图标
    static let onPrimary = Color(uiColor: UIColor(hex: 0x1A1206))
    static let brandNight = Color(uiColor: UIColor(hex: 0x0B0C10))

    static let pageBackground = Color(uiColor: .adaptive(light: UIColor(hex: 0xF6F3ED), dark: UIColor(hex: 0x0B0C10)))
    static let surface = Color(uiColor: .adaptive(light: .white, dark: UIColor(hex: 0x15171D)))
    static let surfaceRaised = Color(uiColor: .adaptive(light: UIColor(hex: 0xEDE8DE), dark: UIColor(hex: 0x1E2028)))
    static let surfaceHigh = Color(uiColor: .adaptive(light: UIColor(hex: 0xE2DCCF), dark: UIColor(hex: 0x2A2D36)))
    static let primaryAction = gold
    static let playerBackground = Color(uiColor: UIColor(hex: 0x050608))
    static let playerSurface = Color(uiColor: UIColor(hex: 0x15171D))
    static let contentInset: CGFloat = 16

    static let textPrimary = Color(uiColor: .adaptive(light: UIColor(hex: 0x1B1D24), dark: UIColor(hex: 0xF2F3F5)))
    static let textSecondary = Color(uiColor: .adaptive(light: UIColor(hex: 0x5E6371), dark: UIColor(hex: 0xA1A6B3)))
    static let textTertiary = Color(uiColor: .adaptive(light: UIColor(hex: 0x8B90A0), dark: UIColor(hex: 0x6B7080)))

    static let hairline = Color(uiColor: .adaptive(
        light: UIColor(white: 0, alpha: 0.07),
        dark: UIColor(white: 1, alpha: 0.06)
    ))
    static let track = Color(uiColor: .adaptive(
        light: UIColor(white: 0, alpha: 0.10),
        dark: UIColor(white: 1, alpha: 0.12)
    ))
    static let shadow = Color(uiColor: .adaptive(
        light: UIColor(hex: 0x5A4010, alpha: 0.07),
        dark: UIColor(white: 0, alpha: 0)
    ))
    static let tileTint = Color(uiColor: .adaptive(
        light: UIColor(hex: 0xB26A14, alpha: 0.12),
        dark: UIColor(hex: 0xE9B061, alpha: 0.14)
    ))

    /// 文件夹图标：橙色背板、黄色前板，放在一块淡灰蓝的圆角底上。
    static let folderBack = Color(uiColor: UIColor(hex: 0xE09A3A))
    static let folderFront = Color(uiColor: UIColor(hex: 0xF3C45C))
    static let folderTile = Color(uiColor: .adaptive(
        light: UIColor(hex: 0xF1ECE2),
        dark: UIColor(white: 1, alpha: 0.09)
    ))

    static let success = Color(uiColor: .systemGreen)
    static let warning = Color(uiColor: .systemOrange)
    static let danger = Color(uiColor: .systemRed)

    /// 所有线框图标统一的字重
    static let iconWeight: Font.Weight = .medium

    /// 圆角台阶：全应用只有这四种
    enum Radius {
        static let poster: CGFloat = 10
        static let tile: CGFloat = 12
        static let card: CGFloat = 16
        static let sheet: CGFloat = 24
    }

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [goldLight, gold, goldDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension Font {
    /// 片名和栏目大标题：衬线黑体，像院线海报上的字。
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .black, design: .serif)
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
                        Capsule().fill(Theme.accentGradient)
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
            content.shadow(color: Theme.gold.opacity(0.32), radius: 12, x: 0, y: 6)
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

/// 海报和缩略图底部的进度线：3pt 的金色细线，压在半透明的轨道上。
struct GlassProgressBar: View {
    /// 0...1
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.18))
                Rectangle()
                    .fill(Theme.gold)
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
