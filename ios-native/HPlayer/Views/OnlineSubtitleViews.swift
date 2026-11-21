import SwiftUI

/// 「我的 › 播放 › 在线字幕来源」：管理免费外挂字幕数据源与本地缓存，全部来源均无需填写 API Token。
struct OnlineSubtitleSourcesView: View {
    @State private var xunlei = OnlineSubtitlePrefs.isSourceEnabled(.xunlei)
    @State private var subtitlecat = OnlineSubtitlePrefs.isSourceEnabled(.subtitlecat)
    @State private var shooter = OnlineSubtitlePrefs.isSourceEnabled(.shooter)
    @State private var opensubtitles = OnlineSubtitlePrefs.isSourceEnabled(.opensubtitles)
    @State private var cachedCount = OnlineSubtitleCache.shared.cachedFileCount
    @State private var cachedBytes = OnlineSubtitleCache.shared.cachedByteCount
    @State private var clearing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                SettingsSection(
                    title: "免费字幕来源",
                    footnote: "视频本身已有自带字幕时，开启自动匹配也只会优先显示自带字幕；未检测到自带字幕时再按指纹、片名、剧集或番号搜索中文字幕。"
                ) {
                    sourceRow(.xunlei, binding: $xunlei, identifier: "onlineSubtitle.source.xunlei")
                    RowDivider()
                    sourceRow(.subtitlecat, binding: $subtitlecat, identifier: "onlineSubtitle.source.subtitlecat")
                    RowDivider()
                    sourceRow(.shooter, binding: $shooter, identifier: "onlineSubtitle.source.shooter")
                    RowDivider()
                    sourceRow(.opensubtitles, binding: $opensubtitles, identifier: "onlineSubtitle.source.opensubtitles")
                }

                SettingsSection(
                    title: "本地字幕缓存",
                    footnote: "已匹配和选定的在线字幕会保存在本机缓存中，续播或回看时直接挂载，不重复发起网络请求。"
                ) {
                    LibraryActionRow(
                        symbol: AppIcon.subtitle.name,
                        title: "已缓存字幕",
                        value: cacheSummary,
                        showsChevron: false
                    )
                    if cachedCount > 0 {
                        RowDivider()
                        Button { clearing = true } label: {
                            LibraryActionRow(
                                symbol: AppIcon.trash.name,
                                title: "清空在线字幕缓存",
                                showsChevron: false,
                                tone: .danger
                            )
                        }
                        .buttonStyle(.pressable(scale: 0.985))
                        .accessibilityIdentifier("onlineSubtitle.clearCache")
                    }
                }

                DesignNotice(symbol: AppIcon.info.name, text: "所有字幕来源均直接从手机端访问公开免费接口，无需配置付费 Token。")
                    .padding(.horizontal, Theme.Space.xs)
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.contentInset)
            .padding(.vertical, Theme.Space.lg)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("在线字幕来源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .designScreen("online-subtitle-sources")
        .onAppear { reload() }
        .onChange(of: xunlei) { OnlineSubtitlePrefs.setSourceEnabled(.xunlei, $0) }
        .onChange(of: subtitlecat) { OnlineSubtitlePrefs.setSourceEnabled(.subtitlecat, $0) }
        .onChange(of: shooter) { OnlineSubtitlePrefs.setSourceEnabled(.shooter, $0) }
        .onChange(of: opensubtitles) { OnlineSubtitlePrefs.setSourceEnabled(.opensubtitles, $0) }
        .confirmationDialog("清空已下载的在线字幕缓存？", isPresented: $clearing, titleVisibility: .visible) {
            Button("清空缓存", role: .destructive) {
                OnlineSubtitleCache.shared.clearAll()
                reload()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清空后不影响内嵌字幕与本地同目录字幕，下次观看时会重新匹配。")
        }
    }

    private func sourceRow(_ source: OnlineSubtitleSource, binding: Binding<Bool>, identifier: String) -> some View {
        SettingRow(icon: .network, title: source.title, subtitle: source.subtitle) {
            Toggle(source.title, isOn: binding)
                .labelsHidden()
                .tint(Theme.accentFill)
                .accessibilityIdentifier(identifier)
        }
    }

    private var cacheSummary: String {
        guard cachedCount > 0 else { return "暂无缓存" }
        let formattedSize = ByteCountFormatter.string(fromByteCount: cachedBytes, countStyle: .file)
        return "\(cachedCount) 个 · \(formattedSize)"
    }

    private func reload() {
        xunlei = OnlineSubtitlePrefs.isSourceEnabled(.xunlei)
        subtitlecat = OnlineSubtitlePrefs.isSourceEnabled(.subtitlecat)
        shooter = OnlineSubtitlePrefs.isSourceEnabled(.shooter)
        opensubtitles = OnlineSubtitlePrefs.isSourceEnabled(.opensubtitles)
        cachedCount = OnlineSubtitleCache.shared.cachedFileCount
        cachedBytes = OnlineSubtitleCache.shared.cachedByteCount
    }
}
