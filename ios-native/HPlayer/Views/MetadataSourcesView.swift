import SwiftUI

/// 资料来源：影视资料、番号资料、接口凭证三组。
/// 所有行都是同一种设置行：自动使用的来源右边写状态，可配置的来源点进凭证页，开关用系统开关。
struct MetadataSourcesView: View {
    var showsCloseButton = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AdultMetadataSettings.enabledKey) private var adultMatching = false
    @State private var credentials = false
    @State private var tmdbEnabled = !TMDBClient.storedKey.isEmpty
    @State private var dmmEnabled = DMMClient.storedCredentials() != nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                SettingsSection(title: "影视资料", footnote: "番组计划和 IMDb 不用配置，匹配封面时自动使用。") {
                    LibraryActionRow(symbol: AppIcon.sparkles.name, title: "番组计划", subtitle: "动画与亚洲影视资料",
                                     value: "自动使用", showsChevron: false)
                    LibraryActionRow(symbol: AppIcon.video.name, title: "IMDb / Cinemeta", subtitle: "电影与剧集资料",
                                     value: "自动使用", showsChevron: false)
                    Button { credentials = true } label: {
                        LibraryActionRow(symbol: AppIcon.key.name, title: "TMDB", subtitle: "可选的中文海报与影片资料",
                                         value: tmdbEnabled ? "已开启" : "未配置", valueHighlighted: tmdbEnabled)
                    }
                    .buttonStyle(.pressable(scale: 0.985))
                    .accessibilityIdentifier("metadata.tmdb")
                }

                SettingsSection(title: "番号资料",
                                footnote: "默认关闭。开启后通过 R18.dev 与可选的 FANZA（DMM）查询番号资料，只发送识别出的番号，不发送 115 Cookie、文件路径或视频内容。") {
                    SettingRow(icon: .privacy, title: "按番号匹配成人影片") {
                        Toggle("按番号匹配成人影片", isOn: $adultMatching.animation(reduceMotion ? nil : Motion.smooth))
                            .labelsHidden()
                            .tint(Theme.accentFill)
                            .accessibilityIdentifier("scan.adultMatching")
                    }
                    if adultMatching {
                        LibraryActionRow(symbol: AppIcon.series.name, title: "R18.dev", subtitle: "开启番号匹配后自动使用",
                                         value: "已开启", showsChevron: false)
                            .transition(.opacity)
                        Button { credentials = true } label: {
                            LibraryActionRow(symbol: AppIcon.key.name, title: "FANZA（DMM）", subtitle: "可选，需要 API 凭证",
                                             value: dmmEnabled ? "已开启" : "可选", valueHighlighted: dmmEnabled)
                        }
                        .buttonStyle(.pressable(scale: 0.985))
                        .accessibilityIdentifier("metadata.dmm")
                        .transition(.opacity)
                    }
                }

                SettingsSection(title: "接口凭证", footnote: "关闭或删除资料来源不会删除已经匹配的封面与资料。") {
                    Button { credentials = true } label: {
                        LibraryActionRow(symbol: AppIcon.keyHorizontal.name, title: "管理接口凭证",
                                         value: tmdbEnabled || dmmEnabled ? "已保存" : "")
                    }
                    .buttonStyle(.pressable(scale: 0.985))
                    .accessibilityIdentifier("metadata.credentials")
                }
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.contentInset)
            .padding(.vertical, Theme.Space.lg)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("资料来源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .designScreen("metadata")
        .toolbar {
            if showsCloseButton { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .sheet(isPresented: $credentials, onDismiss: {
            tmdbEnabled = !TMDBClient.storedKey.isEmpty
            dmmEnabled = DMMClient.storedCredentials() != nil
        }) { NavigationStack { MetadataCredentialsView() } }
    }
}
