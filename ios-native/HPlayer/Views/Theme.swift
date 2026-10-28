import SwiftUI

enum Theme {
    static let accent = Color(red: 0.31, green: 0.55, blue: 1.0)
    static let accentAlt = Color(red: 0.48, green: 0.36, blue: 1.0)
    static let pageBackground = Color(red: 0.04, green: 0.05, blue: 0.07)

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentAlt],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

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
        }
    }

    @ViewBuilder
    func glassInteractiveCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

/// 截图里那种胶囊按钮：图标 + 文字
struct GlassCapsuleButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
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
            .font(.title2.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
