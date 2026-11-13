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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var store = AppIconStore.shared

    private var columns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : (horizontalSizeClass == .regular ? 3 : 2)
        return Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                currentIconCard

                VStack(alignment: .leading, spacing: 16) {
                    collectionHeader
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(HomeScreenIcon.allCases) { icon in
                            iconOption(icon)
                        }
                    }
                }

                Label(
                    store.supportsAlternateIcons
                        ? "轻点样式，即可更换主屏幕上的应用图标。"
                        : "当前设备暂不支持更换应用图标。",
                    systemImage: AppIcon.info.name
                )
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
            }
            .padding(Theme.contentInset)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: 672)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("应用图标")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let notice = store.notice {
                IconChangeNoticeCard(notice: notice, store: store)
                    .padding(.horizontal, Theme.contentInset)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 672)
                    .frame(maxWidth: .infinity)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.resolved(Motion.smooth, reduceMotion: reduceMotion), value: store.notice)
        .animation(Motion.resolved(Motion.snappy, reduceMotion: reduceMotion), value: store.selected)
    }

    private var currentIconCard: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 20) {
                    IconArtwork(icon: store.selected, size: 88)
                    currentIconDetails
                }
            } else {
                HStack(spacing: 20) {
                    IconArtwork(icon: store.selected, size: 88)
                    currentIconDetails
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.appIcon.current")
    }

    private var currentIconDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if store.isChanging {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.textSecondary)
                        .accessibilityHidden(true)
                }
                Text(store.isChanging ? "正在切换" : "当前使用")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
            }

            Text(store.selected.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(store.selected.subtitle)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var collectionHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                collectionTitle
                Spacer(minLength: 0)
                restoreDefaultButton
            }
            VStack(alignment: .leading, spacing: 8) {
                collectionTitle
                restoreDefaultButton
            }
        }
    }

    private var collectionTitle: some View {
        Text("选择样式")
            .font(.headline)
            .foregroundStyle(Theme.textPrimary)
            .fixedSize()
            .accessibilityAddTraits(.isHeader)
    }

    private var restoreDefaultButton: some View {
        Button {
            store.select(.prism)
        } label: {
            Label("恢复默认", systemImage: AppIcon.refresh.name)
                .font(.subheadline.weight(.medium))
                .fixedSize()
                .foregroundStyle(store.selected == .prism ? Theme.textTertiary : Theme.accent)
                .frame(minHeight: 44)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(store.isChanging || !store.supportsAlternateIcons || store.selected == .prism)
        .accessibilityLabel("恢复默认图标")
        .accessibilityIdentifier("settings.appIcon.restoreDefault")
    }

    private func iconOption(_ icon: HomeScreenIcon) -> some View {
        let selected = store.selected == icon
        return Button {
            store.select(icon)
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                IconArtwork(icon: icon, size: 72)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)

                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(icon.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(icon.subtitle)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)

                    if selected && store.isChanging {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Theme.textPrimary)
                            .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: selected ? AppIcon.selected.name : AppIcon.unselected.name)
                            .font(.scaled(20, weight: Theme.iconWeight))
                            .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
                            .frame(width: 20, height: 20)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Theme.surfaceRaised : Theme.surface,
                in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(selected ? Theme.textPrimary : Theme.hairline, lineWidth: selected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.pressable(scale: 0.97))
        .disabled(store.isChanging || !store.supportsAlternateIcons)
        .accessibilityLabel(icon.title)
        .accessibilityValue(selected ? (store.isChanging ? "正在切换" : "当前使用") : icon.subtitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.appIcon.\(icon.rawValue)")
    }
}

private struct IconArtwork: View {
    let icon: HomeScreenIcon
    let size: CGFloat

    var body: some View {
        Image(icon.previewName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            }
            .shadow(color: Theme.shadow, radius: 8, x: 0, y: 4)
            .accessibilityHidden(true)
    }
}

private struct IconChangeNoticeCard: View {
    let notice: AppIconStore.Notice
    @ObservedObject var store: AppIconStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    message
                    HStack {
                        Spacer(minLength: 0)
                        actions
                    }
                }
            } else {
                HStack(spacing: 12) {
                    message
                    Spacer(minLength: 0)
                    actions
                }
            }
        }
        .padding(12)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .shadow(color: Theme.shadow, radius: 12, x: 0, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.appIcon.notice")
    }

    private var message: some View {
        HStack(spacing: 10) {
            switch notice {
            case .success(let icon, _):
                IconArtwork(icon: icon, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text("图标已更新")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(icon.title)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            case .failure(let message):
                Image(systemName: AppIcon.alert.name)
                    .font(.scaled(20, weight: Theme.iconWeight))
                    .foregroundStyle(Theme.danger)
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("更换失败，已保留原图标")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        HStack(spacing: 0) {
            if case .success = notice {
                Button("撤销") { store.undo() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(store.isChanging)
                    .accessibilityIdentifier("settings.appIcon.notice.undo")
            }
            Button {
                store.clearNotice()
            } label: {
                Image(systemName: AppIcon.close.name)
                    .font(.scaled(13, weight: Theme.iconWeight))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("关闭提示")
            .accessibilityIdentifier("settings.appIcon.notice.done")
        }
        .buttonStyle(.pressable)
    }
}
