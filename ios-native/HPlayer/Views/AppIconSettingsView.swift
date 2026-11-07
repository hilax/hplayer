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
        case .classic: return "黑曜与金"
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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = AppIconStore()

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 14)]

    private var isDefaultActive: Bool { store.selected == .prism }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageIntroduction(
                    eyebrow: "App Icon",
                    title: "应用图标",
                    subtitle: "选择喜欢的图标，展现个性化的主屏幕风格。",
                    showsTitle: false
                )

                currentIconHeroCard

                VStack(alignment: .leading, spacing: 12) {
                    Text("可选样式")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 2)

                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(HomeScreenIcon.allCases) { icon in
                            iconOption(icon)
                        }
                    }
                }

                if !store.supportsAlternateIcons {
                    Text("当前设备不支持更换应用图标。")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    tipBox
                }
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(Theme.contentInset)
            .padding(.bottom, 76)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("应用图标")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .overlay(alignment: .bottom) {
            if let notice = store.notice {
                IconChangeNoticeCard(notice: notice, store: store)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.smooth, value: store.notice)
        .animation(Motion.snappy, value: store.selected)
        .onAppear { store.refreshFromSystem() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { store.refreshFromSystem() }
        }
    }

    // MARK: - 当前生效图标 Hero 卡片

    private var currentIconHeroCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                Image(store.selected.previewName)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(Theme.accentGradient, lineWidth: 1.5)
                    }
                    .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isDefaultActive ? Theme.success : Theme.gold)
                            .frame(width: 7, height: 7)
                        Text(isDefaultActive ? "默认主图标" : "已启用个性图标")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(isDefaultActive ? Theme.success : Theme.accent)
                    }

                    Text(store.selected.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)

                    Text(store.selected.subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()
            }

            Button {
                store.select(.prism)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: AppIcon.refresh.name)
                        .font(.system(size: 13, weight: .semibold))
                    Text(isDefaultActive ? "已是默认图标" : "恢复默认图标")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(
                    isDefaultActive ? Theme.surfaceRaised.opacity(0.6) : Theme.tileTint,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                )
                .foregroundStyle(isDefaultActive ? Theme.textTertiary : Theme.accent)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                        .strokeBorder(
                            isDefaultActive ? Theme.hairline : Theme.accent.opacity(0.35),
                            lineWidth: 1
                        )
                }
            }
            .buttonStyle(.pressable(scale: 0.98))
            .disabled(store.isChanging || !store.supportsAlternateIcons || isDefaultActive)
            .accessibilityIdentifier("settings.appIcon.restoreDefault")
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .shadow(color: Theme.shadow, radius: 10, x: 0, y: 4)
    }

    // MARK: - 图标选项卡片

    private func iconOption(_ icon: HomeScreenIcon) -> some View {
        let selected = store.selected == icon
        return Button {
            store.select(icon)
        } label: {
            VStack(spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    Image(icon.previewName)
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: Color.black.opacity(0.1), radius: 5, x: 0, y: 2)

                    if selected {
                        Image(systemName: AppIcon.selected.name)
                            .font(.system(size: 20, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Theme.onPrimary, Theme.gold)
                            .offset(x: 4, y: -4)
                            .shadow(color: Color.black.opacity(0.25), radius: 3, x: 0, y: 1)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                VStack(spacing: 2) {
                    Text(icon.title)
                        .font(.subheadline.weight(selected ? .bold : .medium))
                        .foregroundStyle(selected ? Theme.accent : Theme.textPrimary)
                        .lineLimit(1)

                    Text(icon.subtitle)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(
                selected ? Theme.surfaceRaised : Theme.surface,
                in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(
                        selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.hairline),
                        lineWidth: selected ? 2 : 1
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.95))
        .disabled(store.isChanging || !store.supportsAlternateIcons)
        .accessibilityLabel(icon.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.appIcon.\(icon.rawValue)")
    }

    // MARK: - 提示卡片

    private var tipBox: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: AppIcon.info.name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.top, 1)

            Text("更换后主屏幕立即更新，页内会给出确认卡片，可随时撤销。个别系统版本回退到公开接口时仍会弹出系统提示，轻点确认即可。")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            Theme.surfaceRaised.opacity(0.7),
            in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.8)
        }
    }
}

// MARK: - 重新设计的页内确认提示（取代系统弹窗体验）

private struct IconChangeNoticeCard: View {
    let notice: AppIconStore.Notice
    @ObservedObject var store: AppIconStore

    var body: some View {
        HStack(spacing: 12) {
            switch notice {
            case .success(let icon, _):
                Image(icon.previewName)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: AppIcon.selected.name)
                            .font(.system(size: 14, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Theme.onPrimary, Theme.gold)
                            .offset(x: 4, y: 4)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text("图标已更新")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("主屏幕已同步为「\(icon.title)」")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button("撤销") { store.undo() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .background(Theme.tileTint, in: Capsule())
                    .accessibilityIdentifier("settings.appIcon.notice.undo")
                Button {
                    store.clearNotice()
                } label: {
                    Image(systemName: AppIcon.close.name)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(Theme.surfaceRaised, in: Circle())
                }
                .accessibilityLabel("完成")
                .accessibilityIdentifier("settings.appIcon.notice.done")
            case .failure(let message):
                Image(systemName: AppIcon.alert.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.danger)
                    .frame(width: 44, height: 44)
                    .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("更换失败")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Button {
                    store.clearNotice()
                } label: {
                    Image(systemName: AppIcon.close.name)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(Theme.surfaceRaised, in: Circle())
                }
                .accessibilityLabel("知道了")
                .accessibilityIdentifier("settings.appIcon.notice.done")
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 20)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.8)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 16, x: 0, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.appIcon.notice")
    }
}