import SwiftUI
import UIKit

enum HomeScreenIcon: String, CaseIterable, Identifiable {
    case prism
    case classic
    case ocean, mint, iris, coral

    var id: String { rawValue }

    var title: String {
        switch self {
        case .prism: return "彩色棱镜"
        case .classic: return "经典"
        case .ocean: return "晴空蓝"
        case .mint: return "薄荷绿"
        case .iris: return "鸢尾紫"
        case .coral: return "珊瑚橙"
        }
    }

    var subtitle: String {
        switch self {
        case .prism: return "系统默认"
        case .classic: return "浅蓝底色"
        case .ocean: return "蔚蓝澄澈"
        case .mint: return "清爽柔和"
        case .iris: return "神秘高雅"
        case .coral: return "温暖活力"
        }
    }

    var alternateName: String? {
        switch self {
        case .prism: return nil
        case .classic: return "AppIconClassic"
        case .ocean: return "AppIconOcean"
        case .mint: return "AppIconMint"
        case .iris: return "AppIconIris"
        case .coral: return "AppIconCoral"
        }
    }

    var previewName: String {
        switch self {
        case .prism: return "AppIconPreviewPrism"
        case .classic: return "AppIconPreviewClassic"
        case .ocean: return "AppIconPreviewOcean"
        case .mint: return "AppIconPreviewMint"
        case .iris: return "AppIconPreviewIris"
        case .coral: return "AppIconPreviewCoral"
        }
    }

    func matchesCurrentName(_ name: String?) -> Bool {
        // Keep the white-prism selection from builds where it was an alternate.
        if self == .prism { return name == nil || name == "AppIconPrism" }
        return name == alternateName
    }
}

struct AppIconSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var store = AppIconStore.shared
    /// 仅控制顶部主屏幕预览的深 / 浅桌面底色，不影响系统或应用外观。
    @State private var previewDarkOverride: Bool?

    private var previewDark: Bool {
        previewDarkOverride ?? (colorScheme == .dark)
    }

    private var columns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : 3
        return Array(
            repeating: GridItem(.flexible(), spacing: Theme.Space.md, alignment: .top),
            count: count
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                previewStage

                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    collectionHeader
                    LazyVGrid(columns: columns, spacing: Theme.Space.md) {
                        ForEach(HomeScreenIcon.allCases) { icon in
                            iconOption(icon)
                        }
                    }
                }

                DesignNotice(
                    symbol: store.supportsAlternateIcons ? AppIcon.info.name : AppIcon.alert.name,
                    text: store.supportsAlternateIcons
                        ? "点按样式即可更换主屏幕图标，更换完成后系统会显示一次确认提示。"
                        : "当前设备暂不支持更换应用图标。",
                    warning: !store.supportsAlternateIcons
                )
                .padding(.horizontal, Theme.Space.xs)
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.contentInset)
            .padding(.vertical, Theme.Space.lg)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("应用图标")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .designScreen("app-icon")
        .animation(Motion.resolved(Motion.snappy, reduceMotion: reduceMotion), value: store.selected)
        .animation(Motion.resolved(Motion.snappy, reduceMotion: reduceMotion), value: previewDark)
    }

    // MARK: - 顶部主屏幕预览舞台

    private var previewStage: some View {
        VStack(spacing: 0) {
            homeScreenCanvas
            Rectangle()
                .fill(Theme.rule)
                .frame(height: Theme.Stroke.hairline)
                .accessibilityHidden(true)
            currentStatusBar
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .surfaceCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.appIcon.current")
    }

    /// 模拟主屏幕桌面：正中放置当前选中的 HPlayer 图标与名称，两侧以极淡占位槽位建立桌面比例。
    private var homeScreenCanvas: some View {
        let iconSide: CGFloat = dynamicTypeSize.isAccessibilitySize ? 72 : 64
        let ghostCountPerSide = dynamicTypeSize.isAccessibilitySize ? 0 : (horizontalSizeClass == .regular ? 2 : 1)
        let labelColor = previewDark ? Theme.paper : Theme.ink

        return HStack(alignment: .top, spacing: Theme.Space.xl) {
            if ghostCountPerSide > 0 {
                ForEach(0..<ghostCountPerSide, id: \.self) { _ in
                    ghostAppSlot(size: iconSide - 4)
                }
            }

            VStack(spacing: Theme.Space.sm) {
                IconArtwork(icon: store.selected, size: iconSide, darkBackdrop: previewDark)
                    .id(store.selected)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .scale(scale: 0.92).combined(with: .opacity)
                    )
                Text("HPlayer")
                    .font(Theme.Typo.caption.weight(.medium))
                    .foregroundStyle(labelColor)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("主屏幕预览，当前图标 \(store.selected.title)")

            if ghostCountPerSide > 0 {
                ForEach(0..<ghostCountPerSide, id: \.self) { _ in
                    ghostAppSlot(size: iconSide - 4)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.xl + Theme.Space.xs)
        .padding(.bottom, Theme.Space.xl)
        .background {
            LinearGradient(
                colors: previewDark
                    ? [Theme.Preview.darkCard.opacity(0.75), Theme.Preview.darkPage]
                    : [Theme.Preview.lightCard, Theme.Preview.lightPage],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .overlay(alignment: .topTrailing) {
            backdropToggleButton
        }
    }

    private func ghostAppSlot(size: CGFloat) -> some View {
        let tileFill = previewDark ? Theme.Preview.darkCard : Theme.Preview.lightCard
        let line = previewDark ? Theme.Preview.darkLine.opacity(0.45) : Theme.Preview.lightLine.opacity(0.65)
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)

        return VStack(spacing: Theme.Space.sm + 2) {
            shape
                .fill(tileFill.opacity(previewDark ? 0.85 : 0.9))
                .overlay { shape.strokeBorder(line, lineWidth: Theme.Stroke.hairline) }
                .frame(width: size, height: size)
            Capsule()
                .fill(line)
                .frame(width: size * 0.56, height: 6)
        }
        .padding(.top, Theme.Space.hair)
        .accessibilityHidden(true)
    }

    private var backdropToggleButton: some View {
        Button {
            Haptics.select()
            previewDarkOverride = !previewDark
        } label: {
            Image(icon: previewDark ? .appearanceLight : .appearanceDark)
                .font(.scaled(15, weight: Theme.iconWeight))
                .foregroundStyle(previewDark ? Theme.paper : Theme.ink)
                .frame(width: 30, height: 30)
                .background(
                    (previewDark ? Theme.Preview.darkCard : Theme.Preview.lightCard).opacity(0.9),
                    in: Circle()
                )
                .overlay {
                    Circle().strokeBorder(
                        previewDark ? Theme.Preview.darkLine.opacity(0.5) : Theme.Preview.lightLine,
                        lineWidth: Theme.Stroke.hairline
                    )
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .hoverEffect(.highlight)
        }
        .buttonStyle(.pressable(scale: 0.92))
        .padding(.top, Theme.Space.xs)
        .padding(.trailing, Theme.Space.xs)
        .accessibilityLabel(previewDark ? "切换为浅色桌面预览" : "切换为深色桌面预览")
        .accessibilityIdentifier("settings.appIcon.previewBackdrop")
    }

    private var currentStatusBar: some View {
        HStack(alignment: .center, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(store.selected.title)
                    .font(Theme.Typo.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(store.selected.subtitle)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Theme.Space.sm)

            if store.isChanging {
                HStack(spacing: Theme.Space.xs + 2) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.textSecondary)
                    Text("正在切换")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else if store.selected == .prism {
                TagBadge(text: "默认", style: .neutral)
            } else {
                TagBadge(text: "使用中", style: .accent)
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md + 2)
    }

    // MARK: - 全部样式网格

    private var collectionHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.md) {
                collectionTitle
                Spacer(minLength: 0)
                restoreDefaultButton
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                collectionTitle
                restoreDefaultButton
            }
        }
    }

    private var collectionTitle: some View {
        Text("全部样式")
            .font(Theme.Typo.meta.weight(.medium))
            .foregroundStyle(Theme.textTertiary)
            .padding(.leading, Theme.Space.xs)
            .fixedSize()
            .accessibilityAddTraits(.isHeader)
    }

    private var restoreDefaultButton: some View {
        let isDefault = store.selected == .prism
        return Button {
            store.select(.prism)
        } label: {
            Label("恢复默认", icon: .refresh)
                .font(Theme.Typo.meta.weight(.medium))
                .fixedSize()
                .foregroundStyle(isDefault ? Theme.textMuted : Theme.accentAlt)
                .frame(minHeight: 44)
                .padding(.horizontal, Theme.Space.xs)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(store.isChanging || !store.supportsAlternateIcons || isDefault)
        .accessibilityLabel("恢复默认图标")
        .accessibilityIdentifier("settings.appIcon.restoreDefault")
    }

    private func iconOption(_ icon: HomeScreenIcon) -> some View {
        let selected = store.selected == icon
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)

        return Button {
            store.select(icon)
        } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    accessibleOptionBody(icon: icon, selected: selected)
                } else {
                    compactOptionBody(icon: icon, selected: selected)
                }
            }
            .frame(maxWidth: .infinity)
            .background(selected ? Theme.surfaceRaised : Theme.surface, in: shape)
            .overlay {
                shape.strokeBorder(
                    selected ? Theme.primaryAction : Theme.hairline,
                    lineWidth: selected ? Theme.Stroke.rule : Theme.Stroke.hairline
                )
            }
            .contentShape(shape)
            .hoverEffect(.highlight)
        }
        .buttonStyle(.pressable(scale: 0.97))
        .disabled(store.isChanging || !store.supportsAlternateIcons)
        .accessibilityLabel(icon.title)
        .accessibilityValue(selected ? (store.isChanging ? "正在切换" : "当前使用") : icon.subtitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.appIcon.\(icon.rawValue)")
    }

    private func compactOptionBody(icon: HomeScreenIcon, selected: Bool) -> some View {
        VStack(spacing: Theme.Space.md) {
            IconArtwork(icon: icon, size: 60, darkBackdrop: colorScheme == .dark)
                .padding(.top, Theme.Space.sm)

            VStack(spacing: Theme.Space.hair) {
                Text(icon.title)
                    .font(Theme.Typo.meta.weight(selected ? .semibold : .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(icon.subtitle)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, Theme.Space.md)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            if selected {
                Group {
                    if store.isChanging {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(Theme.textPrimary)
                            .frame(width: 18, height: 18)
                    } else {
                        CheckBadge(selected: true, size: 18)
                    }
                }
                .padding(Theme.Space.sm)
            }
        }
        .accessibilityHidden(true)
    }

    private func accessibleOptionBody(icon: HomeScreenIcon, selected: Bool) -> some View {
        HStack(spacing: Theme.Space.md) {
            IconArtwork(icon: icon, size: 56, darkBackdrop: colorScheme == .dark)

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(icon.title)
                    .font(Theme.Typo.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(icon.subtitle)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Theme.Space.sm)

            if selected && store.isChanging {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.textPrimary)
                    .frame(width: 22, height: 22)
            } else {
                CheckBadge(selected: selected, size: 22)
            }
        }
        .padding(Theme.Space.lg)
        .accessibilityHidden(true)
    }
}

private struct IconArtwork: View {
    let icon: HomeScreenIcon
    let size: CGFloat
    var darkBackdrop: Bool = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        Image(icon.previewName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    darkBackdrop ? Theme.Preview.darkLine.opacity(0.45) : Theme.Preview.lightLine,
                    lineWidth: Theme.Stroke.hairline
                )
            }
            .accessibilityHidden(true)
    }
}
