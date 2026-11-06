import SwiftUI
import UIKit

enum HomeScreenIcon: String, CaseIterable, Identifiable {
    case prism
    case classic, night, aurora, sunset
    case ocean, mint, iris, coral

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "经典"
        case .night: return "深空"
        case .aurora: return "霓虹"
        case .sunset: return "极光"
        case .prism: return "彩色棱镜"
        case .ocean: return "晴空蓝"
        case .mint: return "薄荷绿"
        case .iris: return "鸢尾紫"
        case .coral: return "珊瑚橙"
        }
    }

    var alternateName: String? {
        switch self {
        case .classic: return "AppIconClassic"
        case .night: return "AppIconNight"
        case .aurora: return "AppIconAurora"
        case .sunset: return "AppIconSunset"
        case .prism: return nil
        case .ocean: return "AppIconOcean"
        case .mint: return "AppIconMint"
        case .iris: return "AppIconIris"
        case .coral: return "AppIconCoral"
        }
    }

    var previewName: String {
        switch self {
        case .classic: return "AppIconPreviewClassic"
        case .night: return "AppIconPreviewNight"
        case .aurora: return "AppIconPreviewAurora"
        case .sunset: return "AppIconPreviewSunset"
        case .prism: return "AppIconPreviewPrism"
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
    @State private var currentName = UIApplication.shared.alternateIconName
    @State private var isChanging = false
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 125, maximum: 180), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageIntroduction(eyebrow: "App Icon", title: "应用图标", subtitle: "选择喜欢的图标，显示在主屏幕上。", showsTitle: false)
                Button { changeIcon(to: .prism) } label: {
                    Label("恢复默认图标", systemImage: AppIcon.refresh.name)
                }
                .buttonStyle(SecondaryActionStyle())
                .disabled(isChanging || !UIApplication.shared.supportsAlternateIcons || currentName == nil)
                .accessibilityIdentifier("settings.appIcon.restoreDefault")
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(HomeScreenIcon.allCases) { icon in
                        iconOption(icon)
                    }
                }
                if !UIApplication.shared.supportsAlternateIcons {
                    Text("当前设备不支持更换应用图标。")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: 620).frame(maxWidth: .infinity)
            .padding(Theme.contentInset)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("应用图标")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear { currentName = UIApplication.shared.alternateIconName }
        .onChange(of: scenePhase) { phase in
            if phase == .active { currentName = UIApplication.shared.alternateIconName }
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

    private func iconOption(_ icon: HomeScreenIcon) -> some View {
        let selected = icon.matchesCurrentName(currentName)
        return Button {
            changeIcon(to: icon)
        } label: {
            VStack(spacing: 10) {
                Image(icon.previewName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: AppIcon.selected.name)
                                .font(.system(size: 21, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Theme.onPrimary, Theme.gold)
                                .offset(x: 5, y: -5)
                        }
                    }
                Text(icon.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if icon == .prism {
                    Text("默认图标")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.hairline, lineWidth: selected ? 2 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.96))
        .disabled(isChanging || !UIApplication.shared.supportsAlternateIcons)
        .accessibilityLabel(icon.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.appIcon.\(icon.rawValue)")
    }

    private func changeIcon(to icon: HomeScreenIcon) {
        guard !isChanging, UIApplication.shared.supportsAlternateIcons,
              currentName != icon.alternateName else { return }
        isChanging = true
        UIApplication.shared.setAlternateIconName(icon.alternateName) { error in
            DispatchQueue.main.async {
                currentName = UIApplication.shared.alternateIconName
                isChanging = false
                if let error {
                    errorMessage = error.localizedDescription
                } else {
                    Haptics.select()
                }
            }
        }
    }
}
