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
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
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

/// 颜色取自 App 图标：青蓝和紫色两笔组成的 H，中间是播放键。
/// 页面底色沿用 iOS 分组背景，表单页和自绘页面在两种模式下保持一致。
enum Theme {
    static let accentUIColor = UIColor.adaptive(light: UIColor(hex: 0x2F5BFF), dark: UIColor(hex: 0x5B8CFF))
    static let accentAltUIColor = UIColor.adaptive(light: UIColor(hex: 0x6A47F5), dark: UIColor(hex: 0x8F72FF))

    static let accent = Color(uiColor: accentUIColor)
    static let accentAlt = Color(uiColor: accentAltUIColor)

    /// 图标里的三种品牌色，两种模式下保持不变。
    static let brandCyan = Color(uiColor: UIColor(hex: 0x16AEF8))
    static let brandBlue = Color(uiColor: UIColor(hex: 0x2F66FF))
    static let brandViolet = Color(uiColor: UIColor(hex: 0x7C5CFF))
    static let brandNavy = Color(uiColor: UIColor(hex: 0x0B0F45))

    static let pageBackground = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let surfaceRaised = Color(uiColor: .tertiarySystemGroupedBackground)

    static let hairline = Color(uiColor: .adaptive(
        light: UIColor(hex: 0x0B0F45, alpha: 0.08),
        dark: UIColor(white: 1, alpha: 0.08)
    ))
    static let track = Color(uiColor: .adaptive(
        light: UIColor(hex: 0x0B0F45, alpha: 0.10),
        dark: UIColor(white: 1, alpha: 0.14)
    ))
    static let shadow = Color(uiColor: .adaptive(
        light: UIColor(hex: 0x141A5C, alpha: 0.10),
        dark: UIColor(white: 0, alpha: 0)
    ))
    static let tileTint = Color(uiColor: .adaptive(
        light: UIColor(hex: 0x2F5BFF, alpha: 0.10),
        dark: UIColor(hex: 0x5B8CFF, alpha: 0.16)
    ))

    /// 文件夹图标：橙色背板、黄色前板，放在一块淡灰蓝的圆角底上。
    static let folderBack = Color(uiColor: UIColor(hex: 0xF0A23C))
    static let folderFront = Color(uiColor: UIColor(hex: 0xF7CB4D))
    static let folderTile = Color(uiColor: .adaptive(
        light: UIColor(hex: 0xF3F4F9),
        dark: UIColor(white: 1, alpha: 0.09)
    ))

    static let success = Color(uiColor: .systemGreen)
    static let warning = Color(uiColor: .systemOrange)

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [brandCyan, brandBlue, brandViolet],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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

    /// 内容卡片：浅色模式是白底加柔和投影，深色模式是抬高一层的灰底。
    func surfaceCard(cornerRadius: CGFloat = 22) -> some View {
        self
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            }
            .shadow(color: Theme.shadow, radius: 16, x: 0, y: 6)
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
                .foregroundStyle(prominent ? Color.white : Color.primary)
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
            content.shadow(color: Theme.brandBlue.opacity(0.35), radius: 12, x: 0, y: 6)
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

/// 圆角方块图标，用在资源库和设置里的入口行
struct IconTile: View {
    let systemImage: String
    var colors: [Color] = [Theme.brandCyan, Theme.brandBlue]
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            )
    }
}
