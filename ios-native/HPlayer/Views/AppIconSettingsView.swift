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
    @State private var currentName: String? = Self.resolveInitialIconName()
    @State private var isChanging = false
    @State private var errorMessage: String?

    private static func resolveInitialIconName() -> String? {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["HPLAYER_HOME_TEST"] == "1" {
            return UserDefaults.standard.string(forKey: "hplayer.simulated_alternate_icon")
        }
        #endif
        return UIApplication.shared.alternateIconName
    }

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 14)]

    private var isDefaultActive: Bool {
        currentName == nil || currentName == "AppIconPrism"
    }

    private var activeIcon: HomeScreenIcon {
        HomeScreenIcon.allCases.first { $0.matchesCurrentName(currentName) } ?? .prism
    }

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

                if !UIApplication.shared.supportsAlternateIcons {
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
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("应用图标")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear {
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["HPLAYER_HOME_TEST"] == "1" {
                currentName = UserDefaults.standard.string(forKey: "hplayer.simulated_alternate_icon")
                return
            }
            #endif
            currentName = UIApplication.shared.alternateIconName
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                #if targetEnvironment(simulator)
                if ProcessInfo.processInfo.environment["HPLAYER_HOME_TEST"] == "1" {
                    return
                }
                #endif
                currentName = UIApplication.shared.alternateIconName
            }
        }
        .alert("无法更换图标", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "请稍后重试。")
        }
    }

    // MARK: - 当前生效图标 Hero 卡片

    private var currentIconHeroCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                Image(activeIcon.previewName)
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

                    Text(activeIcon.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)

                    Text(activeIcon.subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()
            }

            Button {
                changeIcon(to: .prism)
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
            .disabled(isChanging || !UIApplication.shared.supportsAlternateIcons || isDefaultActive)
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
        let selected = icon.matchesCurrentName(currentName)
        return Button {
            changeIcon(to: icon)
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
        .disabled(isChanging || !UIApplication.shared.supportsAlternateIcons)
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

            Text("更换应用图标后主屏幕将立即更新。受 iOS 系统机制限制，切换时系统可能会弹出确认提示，轻点确认即可完成设置。")
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

    // MARK: - 切换图标逻辑

    private func changeIcon(to icon: HomeScreenIcon) {
        guard !isChanging, UIApplication.shared.supportsAlternateIcons else { return }

        // 如果用户选的就是当前已经激活的图标
        if icon.matchesCurrentName(currentName) {
            // 如果处于默认图标，但底层系统 alternateIconName 仍遗留字符串（如旧版 AppIconPrism），同步归一化设为 nil
            if icon == .prism && UIApplication.shared.alternateIconName != nil {
                applyAlternateIcon(nil)
            } else {
                Haptics.tap()
            }
            return
        }

        applyAlternateIcon(icon.alternateName)
    }

    private func applyAlternateIcon(_ alternateName: String?) {
        isChanging = true
        UIApplication.shared.setAlternateIconName(alternateName) { [self] error in
            DispatchQueue.main.async {
                self.isChanging = false

                if let error = error as NSError? {
                    // 处理 iOS 26+ 模拟器及特定系统上已知由于 SpringBoard LSIconAlertManager 无法分配 Token 引发的 POSIX 35 (EAGAIN)
                    if error.domain == NSPOSIXErrorDomain && error.code == 35 {
                        withAnimation(Motion.snappy) {
                            self.currentName = alternateName
                            #if targetEnvironment(simulator)
                            if ProcessInfo.processInfo.environment["HPLAYER_HOME_TEST"] == "1" {
                                UserDefaults.standard.set(alternateName, forKey: "hplayer.simulated_alternate_icon")
                            }
                            #endif
                        }
                        Haptics.select()
                        return
                    }

                    self.errorMessage = error.localizedDescription
                    self.currentName = UIApplication.shared.alternateIconName
                    Haptics.warning()
                } else {
                    withAnimation(Motion.snappy) {
                        self.currentName = alternateName
                        #if targetEnvironment(simulator)
                        if ProcessInfo.processInfo.environment["HPLAYER_HOME_TEST"] == "1" {
                            UserDefaults.standard.set(alternateName, forKey: "hplayer.simulated_alternate_icon")
                        }
                        #endif
                    }
                    Haptics.select()
                }
            }
        }
    }
}
