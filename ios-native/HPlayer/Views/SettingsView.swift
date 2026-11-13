import SwiftUI

struct SettingsTab: View {
    var body: some View {
        SettingsView()
    }
}

/// 「我的」：账号、三项统计，然后是我的内容、播放、弹幕、外观、媒体库、关于。
/// 播放和弹幕两组直接读写播放器已有的偏好（解码、边播边存、字幕样式、自动连播、后台小窗、弹幕样式），
/// 下次打开播放器时生效；这里只是界面，不碰播放器内核。
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var accountInfo: P115AccountInfoStore
    @EnvironmentObject private var recents: RecentStore
    @EnvironmentObject private var localStore: LocalMediaStore
    @EnvironmentObject private var mediaLibrary: MediaLibraryStore

    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system
    @State private var confirmLogout = false
    @State private var showManagement = false
    @State private var titleAway = false
    @ObservedObject private var watchlist = AnimeWatchlistStore.shared

    // 播放偏好：和播放页用的是同一组键
    @AppStorage("player.autoPlayNext") private var autoPlayNext = true
    @State private var decoding = VideoDecoding.saved
    @State private var readahead = ReadaheadLevel.saved
    @State private var subtitleStyle = SubtitleStyle.saved
    @State private var autoPictureInPicture = PictureInPictureSettings.automatic

    // 弹幕偏好：和播放页的弹幕设置是同一组键
    @AppStorage(DanmakuPrefs.enabled) private var danmakuEnabled = true
    @AppStorage(DanmakuPrefs.area) private var danmakuArea = 0.5
    @AppStorage(DanmakuPrefs.opacity) private var danmakuOpacity = 0.9
    @AppStorage(DanmakuPrefs.scale) private var danmakuScale = 1.0
    @AppStorage(DanmakuPrefs.speed) private var danmakuSpeed = 1.0
    @State private var danmakuExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var status: P115Status? { appState.isAuthenticated ? accountInfo.status(for: appState.sessionID) : nil }
    private var loadingStatus: Bool { appState.isAuthenticated && accountInfo.isLoading(for: appState.sessionID) }
    private var error: String { appState.isAuthenticated ? accountInfo.error(for: appState.sessionID) : "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                ScreenTitleBar("我的")
                    .padding(.horizontal, -Theme.contentInset)
                    .scrolledAway($titleAway)
                VStack(spacing: Theme.Space.md) {
                    profileCard
                    statsRow
                }
                .reveal(0)
                contentGroup.reveal(1)
                playbackGroup.reveal(2)
                danmakuGroup.reveal(3)
                appearanceGroup.reveal(4)
                mediaGroup.reveal(5)
                aboutGroup.reveal(6)
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.contentInset)
            .padding(.top, Theme.Space.xs)
            .padding(.bottom, Theme.Space.section + Theme.Space.sm)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground.ignoresSafeArea())
        .overlay(alignment: .top) { CompactTitleBar(title: "我的", visible: titleAway) }
        .toolbar(.hidden, for: .navigationBar)
        .designScreen("settings")
        .fullScreenCover(isPresented: $showManagement) { LibraryManagementView() }
        // 播放页里也能改这几项：回到这一页时重新读一遍
        .onAppear(perform: reloadPlayerPreferences)
        .onChange(of: decoding) { VideoDecoding.saved = $0 }
        .onChange(of: readahead) { ReadaheadLevel.saved = $0 }
        .onChange(of: subtitleStyle) { SubtitleStyle.saved = $0 }
        .onChange(of: autoPictureInPicture) { PictureInPictureSettings.automatic = $0 }
    }

    private func reloadPlayerPreferences() {
        decoding = VideoDecoding.saved
        readahead = ReadaheadLevel.saved
        subtitleStyle = SubtitleStyle.saved
        autoPictureInPicture = PictureInPictureSettings.automatic
    }

    // MARK: 账号

    private var avatarLetter: String? {
        guard appState.isAuthenticated, let name = status?.userName, let first = name.first else { return nil }
        return String(first)
    }

    /// 头像：中性底 + 名字首字，不描彩边
    private var avatar: some View {
        ZStack {
            Circle().fill(Theme.surfaceHigh)
            if let letter = avatarLetter {
                Text(letter)
                    .font(.scaled(22, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .transition(.opacity)
            } else {
                Image(systemName: AppIcon.mine.name)
                    .font(.scaled(22, weight: Theme.iconWeight))
                    .foregroundStyle(Theme.textSecondary)
                    .transition(.opacity)
            }
        }
        .frame(width: 52, height: 52)
        .animation(Motion.smooth, value: avatarLetter)
        .accessibilityHidden(true)
    }

    /// 账号身份：名字、连接状态、切换和退出。容量只在「网盘」页显示，这里不重复。
    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.md) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(status?.userName ?? "115 网盘")
                        .font(Theme.Typo.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Circle().fill(accountState.color).frame(width: 6, height: 6)
                        Text(accountState.text).lineLimit(1)
                    }
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if loadingStatus && status == nil { ProgressView().controlSize(.small) }
                NavigationLink {
                    CookieWebLoginView(onConnected: {})
                        .toolbar(.visible, for: .navigationBar)
                } label: {
                    Image(systemName: AppIcon.switchAccount.name)
                        .font(.scaled(18, weight: Theme.iconWeight))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.pressable(scale: 0.9))
                .accessibilityLabel(appState.isAuthenticated ? "重新登录 115" : "登录 115")
                .accessibilityIdentifier("settings.account.login")
                if appState.isAuthenticated {
                    Button { confirmLogout = true } label: {
                        Image(systemName: AppIcon.logout.name)
                            .font(.scaled(18, weight: Theme.iconWeight))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable(scale: 0.9))
                    .accessibilityLabel("退出 115")
                    .accessibilityIdentifier("settings.account.logout")
                    // 弹窗挂在按钮自己身上，才会从按钮处弹出；挂在整个页面上会被当成锚在页面底部
                    .confirmationDialog("退出后将断开 115 网盘连接", isPresented: $confirmLogout, titleVisibility: .visible) {
                        Button("退出 115", role: .destructive) { appState.logout() }
                            .accessibilityIdentifier("settings.account.confirmLogout")
                        Button("取消", role: .cancel) {}
                    }
                    .transition(.opacity)
                }
            }
            .padding(.vertical, Theme.Space.md)
            .padding(.leading, Theme.Space.lg)
            .padding(.trailing, Theme.Space.xs)

            if !error.isEmpty {
                Label(error, systemImage: AppIcon.alert.name)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.lg)
                    .padding(.bottom, Theme.Space.md)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
        .animation(reduceMotion ? nil : Motion.snappy, value: appState.isAuthenticated)
        .animation(reduceMotion ? nil : Motion.smooth, value: error)
    }

    // MARK: 统计

    /// 视频、观看记录、追番：三格并排，大数字靠字重而不是颜色
    private var statsRow: some View {
        let videos = localStore.files.count + mediaLibrary.files(for: appState).count
        return HStack(spacing: 0) {
            stat("\(videos)", "视频")
            stat("\(recents.items.count)", "观看记录")
            stat("\(watchlist.items.count)", "追番")
        }
        .padding(.vertical, Theme.Space.md + 2)
        .frame(maxWidth: .infinity)
        .surfaceCard()
    }

    private func stat(_ value: String, _ title: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.scaled(22, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .rollingNumber()
                .animation(Motion.smooth, value: value)
            Text(title)
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: 分组

    /// 分组：小标题 + 一张卡片，可选一行脚注。行之间不画分隔线。
    private func group<Content: View>(_ title: String, footnote: String = "",
                                      @ViewBuilder _ content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            GroupLabel(title: title)
            DesignGroup { content() }
            if !footnote.isEmpty {
                Text(footnote)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.xs)
            }
        }
    }

    /// 我的内容：追番。右边是数量（有更新时琥珀色）。传输中心只在「网盘」页，这里不重复。
    private var contentGroup: some View {
        group("我的内容") {
            NavigationLink(value: MineRoute.watchlist) {
                LibraryActionRow(symbol: AppIcon.heart.name, title: "我的追番",
                                 value: watchUpdates > 0 ? "\(watchUpdates) 部更新" : (watchlist.items.isEmpty ? "" : "\(watchlist.items.count)"),
                                 valueHighlighted: watchUpdates > 0)
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("mine.watchlist")
        }
    }

    // MARK: 播放

    private var playbackGroup: some View {
        group("播放", footnote: "从下一次打开播放器开始生效。播放时也可以在播放页的「更多」里临时调整。") {
            SettingRow(icon: .autoPlayNext, title: "自动连播") {
                Toggle("自动连播", isOn: $autoPlayNext)
                    .labelsHidden()
                    .tint(Theme.accentFill)
                    .accessibilityIdentifier("mine.playback.autoNext")
            }
            if PictureInPictureSettings.supported {
                SettingRow(icon: .pictureInPicture, title: "回到桌面时自动小窗") {
                    Toggle("回到桌面时自动小窗", isOn: $autoPictureInPicture)
                        .labelsHidden()
                        .tint(Theme.accentFill)
                        .accessibilityIdentifier("mine.playback.autoPiP")
                }
            }
            SettingRow(icon: .subtitle, title: "字幕样式") {
                menuPicker("字幕样式", selection: $subtitleStyle, options: SubtitleStyle.allCases, title: \.title,
                           identifier: "mine.playback.subtitle")
            }
            SettingRow(icon: .readahead, title: "边播边存") {
                menuPicker("边播边存", selection: $readahead, options: ReadaheadLevel.allCases, title: \.title,
                           identifier: "mine.playback.readahead")
            }
            SettingRow(icon: .decoder, title: "解码方式") {
                menuPicker("解码方式", selection: $decoding, options: VideoDecoding.allCases, title: \.title,
                           identifier: "mine.playback.decoding")
            }
        }
    }

    /// 行尾的下拉选择：系统菜单样式，显示当前值
    private func menuPicker<Option: Hashable & Identifiable>(_ label: String, selection: Binding<Option>, options: [Option],
                                                             title: KeyPath<Option, String>, identifier: String) -> some View {
        Picker(label, selection: selection) {
            ForEach(options) { option in
                Text(option[keyPath: title]).tag(option)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .tint(Theme.textSecondary)
        .accessibilityIdentifier(identifier)
    }

    // MARK: 弹幕

    private var danmakuSummary: String {
        let area: String
        switch danmakuArea {
        case ..<0.3: area = "1/4 屏"
        case ..<0.6: area = "半屏"
        case ..<0.9: area = "3/4 屏"
        default: area = "全屏"
        }
        return "\(area) · \(Int((danmakuOpacity * 100).rounded()))%"
    }

    private var danmakuGroup: some View {
        group("弹幕") {
            SettingRow(icon: .danmaku, title: "显示弹幕") {
                Toggle("显示弹幕", isOn: $danmakuEnabled)
                    .labelsHidden()
                    .tint(Theme.accentFill)
                    .accessibilityIdentifier("mine.danmaku")
            }
            Button {
                Haptics.tap()
                withAnimation(reduceMotion ? nil : Motion.smooth) { danmakuExpanded.toggle() }
            } label: {
                SettingRow(icon: .danmakuStyle, title: "弹幕样式") {
                    HStack(spacing: Theme.Space.sm) {
                        Text(danmakuSummary)
                            .font(Theme.Typo.meta.monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                        Image(systemName: AppIcon.forward.name)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.textMuted)
                            .rotationEffect(.degrees(danmakuExpanded ? 90 : 0))
                    }
                }
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityValue(danmakuExpanded ? "已展开" : "已收起")
            .accessibilityIdentifier("mine.danmaku.style")

            if danmakuExpanded {
                danmakuStyleEditor
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// 展开后的弹幕样式：上面一块实时预览，下面是区域、不透明度、字号、速度
    private var danmakuStyleEditor: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            DanmakuPreview(area: danmakuArea, opacity: danmakuOpacity, scale: danmakuScale, enabled: danmakuEnabled)
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("显示区域")
                    .font(Theme.Typo.row)
                    .foregroundStyle(Theme.textPrimary)
                Picker("显示区域", selection: $danmakuArea) {
                    Text("1/4").tag(0.25)
                    Text("半屏").tag(0.5)
                    Text("3/4").tag(0.75)
                    Text("全屏").tag(1.0)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("mine.danmaku.area")
            }
            sliderRow("不透明度", value: $danmakuOpacity, range: 0.2...1, step: 0.05,
                      text: "\(Int((danmakuOpacity * 100).rounded()))%", identifier: "mine.danmaku.opacity")
            sliderRow("字号", value: $danmakuScale, range: 0.7...1.5, step: 0.1,
                      text: String(format: "%.1f×", danmakuScale), identifier: "mine.danmaku.scale")
            sliderRow("速度", value: $danmakuSpeed, range: 0.6...1.6, step: 0.1,
                      text: String(format: "%.1f×", danmakuSpeed), identifier: "mine.danmaku.speed")
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.xs)
        .padding(.bottom, Theme.Space.lg)
        .disabled(!danmakuEnabled)
        .opacity(danmakuEnabled ? 1 : 0.5)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                           text: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text(title)
                    .font(Theme.Typo.row)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(text)
                    .font(Theme.Typo.meta.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .contentTransition(.numericText())
            }
            Slider(value: value, in: range, step: step)
                .tint(Theme.accentFill)
                .accessibilityLabel(title)
                .accessibilityValue(text)
                .accessibilityIdentifier(identifier)
        }
    }

    // MARK: 外观、媒体库、关于

    private var appearanceGroup: some View {
        group("外观") {
            NavigationLink { AppearanceSettingsView() } label: {
                LibraryActionRow(symbol: AppIcon.appearance.name, title: "显示方式", value: appearance.title)
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("settings.appearance")
            NavigationLink { AppIconSettingsView() } label: {
                LibraryActionRow(symbol: AppIcon.appIconStyle.name, title: "应用图标")
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("settings.appIcon")
        }
    }

    private var mediaGroup: some View {
        group("媒体库") {
            Button { showManagement = true } label: {
                LibraryActionRow(symbol: AppIcon.folderSettings.name, title: "媒体库管理")
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("mine.manage")
            NavigationLink {
                MetadataSourcesView()
            } label: {
                LibraryActionRow(symbol: AppIcon.metadataSources.name, title: "资料来源")
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("mine.sources")
        }
    }

    private var aboutGroup: some View {
        group("关于") {
            LibraryActionRow(symbol: AppIcon.version.name, title: "版本", value: appVersion, showsChevron: false)
            NavigationLink {
                LicensesView()
                    .toolbar(.visible, for: .navigationBar)
            } label: {
                LibraryActionRow(symbol: AppIcon.license.name, title: "开源许可")
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("settings.licenses")
        }
    }

    private var watchUpdates: Int { watchlist.items.filter(\.hasUpdate).count }

    private var accountState: (text: String, color: Color) {
        let idle = Theme.textMuted
        guard appState.isAuthenticated else { return ("尚未登录 115", idle) }
        if loadingStatus && status == nil { return ("检查中", idle) }
        if !error.isEmpty { return ("连接状态待确认", Theme.warning) }
        guard let status else { return ("已登录", idle) }
        if !status.configured { return (status.message ?? "等待授权", Theme.warning) }
        if status.error != nil { return (status.message ?? "Cookie 可能已失效", Theme.warning) }
        return ("已连接", Theme.success)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version)（\(build)）"
    }
}

/// 设置行：线框图标 + 标题，右边放开关、下拉或数值。和 `LibraryActionRow` 同样的尺寸。
private struct SettingRow<Trailing: View>: View {
    let icon: AppIcon
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 14) {
            RowIcon(icon: icon, tint: isEnabled ? Theme.textPrimary : Theme.textMuted)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.Typo.row)
                .foregroundStyle(isEnabled ? Theme.textPrimary : Theme.textMuted)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: Theme.Space.sm)
            trailing()
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.sm - 2)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

/// 弹幕样式的实时预览：一块深色「画面」，按当前的区域、不透明度和字号摆几条示例弹幕。
private struct DanmakuPreview: View {
    let area: Double
    let opacity: Double
    let scale: Double
    let enabled: Bool

    private static let samples = ["前方高能", "这一段配乐太好了", "第一次看到这里", "名场面", "哈哈哈哈", "终于更新了"]
    private static let height: CGFloat = 112

    var body: some View {
        let fontSize = DanmakuPrefs.baseFontSize * CGFloat(scale) * 0.78
        let lane = fontSize + 8
        let visibleHeight = Self.height * CGFloat(area)
        let lanes = max(1, Int((visibleHeight - 8) / lane))
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .fill(Theme.ink)
            // 弹幕能用的区域：上面一块，下沿一条虚线
            Rectangle()
                .fill(Theme.paper.opacity(Theme.Opacity.hint))
                .frame(height: visibleHeight)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .stroke(Theme.paper.opacity(Theme.Opacity.soft), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(height: 1)
                }
            if enabled {
                ForEach(0..<min(lanes, Self.samples.count), id: \.self) { index in
                    Text(Self.samples[index])
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundStyle(Theme.paper)
                        .shadow(color: .black.opacity(Theme.Opacity.strong), radius: 1, x: 0, y: 1)
                        .opacity(opacity)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: index.isMultiple(of: 2) ? 16 + CGFloat(index) * 14 : 96 + CGFloat(index) * 10,
                                y: 6 + CGFloat(index) * lane)
                }
            }
        }
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .animation(Motion.quick, value: area)
        .animation(Motion.quick, value: scale)
        .accessibilityElement()
        .accessibilityLabel("弹幕预览")
    }
}

struct AppearanceSettingsView: View {
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                AppearancePicker(selection: $appearance)
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    GroupLabel(title: "预览")
                    HStack(spacing: Theme.Space.md) {
                        IconTile(icon: .playback, size: 48, tone: .neutral)
                        VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
                            Text("继续观看").font(Theme.Typo.row.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                            Text("第 7 集 · 看到 18:42").font(Theme.Typo.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                            ProgressView(value: 0.42).tint(Theme.accent)
                        }
                    }
                    .padding(Theme.Space.lg)
                    .surfaceCard()
                }
                DesignNotice(symbol: AppIcon.appearance.name, text: "播放页面始终使用深色外观，避免观看时受到亮色界面干扰。")
            }
            .frame(maxWidth: 620).frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.contentInset)
            .padding(.vertical, Theme.Space.lg)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .designScreen("appearance")
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

/// 打包在 App 里的开源许可文本
struct LicensesView: View {
    private struct Entry: Identifiable {
        let id: String
        let title: String
        let url: URL
    }

    private var entries: [Entry] {
        let files: [(name: String, ext: String, title: String)] = [
            ("MPVKit-LICENSE", "txt", "mpv / MPVKit"),
            ("POW-LICENSE", "txt", "Pow"),
            ("NUVIO-ENGINE-LICENSE", "txt", "Nuvio Engine"),
            ("THIRD_PARTY_NOTICES", "md", "Nuvio 第三方声明"),
            ("LIBTORRENT-LICENSE", "txt", "libtorrent"),
            ("LIBTORRENT-COPYING", "txt", "libtorrent COPYING"),
            ("BOOST-LICENSE_1_0", "txt", "Boost"),
            ("OPENSSL-LICENSE", "txt", "OpenSSL"),
            ("TRY_SIGNAL-LICENSE", "txt", "try_signal"),
        ]
        return files.compactMap { file in
            let url = Bundle.main.url(forResource: file.name, withExtension: file.ext)
                ?? Bundle.main.url(forResource: file.name, withExtension: file.ext, subdirectory: "NuvioLicenses")
                ?? Bundle.main.url(forResource: file.name, withExtension: file.ext, subdirectory: "MPVLicenses")
            return url.map { Entry(id: file.name, title: file.title, url: $0) }
        }
    }

    var body: some View {
        DesignPage(eyebrow: "Made possible by open source", title: "致谢开源社区", subtitle: "HPlayer 的播放体验，离不开这些开源项目。") {
            DesignGroup {
                if entries.isEmpty { Text("这个版本没有打包许可文件。").foregroundStyle(.secondary).padding(20) }
                ForEach(entries) { entry in
                    NavigationLink { LicenseTextView(title: entry.title, url: entry.url) } label: {
                        LibraryActionRow(symbol: AppIcon.document.name, title: entry.title, subtitle: entryDetail(entry.id))
                    }
                    .buttonStyle(.pressable(scale: 0.985))
                    .accessibilityIdentifier("settings.license.\(entry.id)")
                }
            }
            DesignNotice(text: "许可文件随应用打包，可在离线状态下阅读。")
        }
        .designScreen("licenses")
        .navigationTitle("开源许可")
    }

    private func entryDetail(_ id: String) -> String {
        switch id {
        case "MPVKit-LICENSE": return "视频播放内核"
        case "POW-LICENSE": return "界面动画"
        case "NUVIO-ENGINE-LICENSE": return "磁力播放引擎"
        case "THIRD_PARTY_NOTICES": return "第三方许可与版权声明"
        case "LIBTORRENT-LICENSE": return "BitTorrent 库"
        case "BOOST-LICENSE_1_0": return "C++ 库"
        case "OPENSSL-LICENSE": return "加密与安全通信"
        case "TRY_SIGNAL-LICENSE": return "信号处理库"
        default: return "版权与许可文本"
        }

    }
}

private struct LicenseTextView: View {
    let title: String
    let url: URL
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? "无法读取许可文件。"
        }
    }
}

/// 外观选择：三张小预览图，选中的那张描边高亮。
private struct AppearancePicker: View {
    @Binding var selection: AppearanceMode
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) {
                    ForEach(AppearanceMode.allCases) { mode in option(mode) }
                }
            } else {
                HStack(spacing: 10) {
                    ForEach(AppearanceMode.allCases) { mode in option(mode) }
                }
            }
        }
    }

    private func option(_ mode: AppearanceMode) -> some View {
        let selected = selection == mode
        return Button {
            if selection != mode { Haptics.select() }
            withAnimation(Motion.snappy) { selection = mode }
        } label: {
            VStack(spacing: 9) {
                AppearancePreview(mode: mode)
                    .frame(height: 116)
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: AppIcon.selected.name)
                                .font(.scaled(18, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Theme.onPrimary, Theme.gold)
                                .offset(x: 4, y: -4)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                Text(mode.title)
                    .font(Theme.Typo.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(selected ? Theme.primaryAction : Theme.hairline, lineWidth: selected ? 1.5 : Theme.Stroke.hairline)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.96))
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.appearance.\(mode.rawValue)")
    }
}

private struct AppearancePreview: View {
    let mode: AppearanceMode

    var body: some View {
        if mode == .system {
            miniScreen(dark: false)
                .overlay {
                    miniScreen(dark: true)
                        .mask {
                            HStack(spacing: 0) {
                                Color.clear
                                Color.black
                            }
                        }
                }
        } else {
            miniScreen(dark: mode == .dark)
        }
    }

    private func miniScreen(dark: Bool) -> some View {
        let background = dark ? Theme.Preview.darkPage : Theme.Preview.lightPage
        let card = dark ? Theme.Preview.darkCard : Theme.Preview.lightCard
        let line = dark ? Theme.Preview.darkLine : Theme.Preview.lightLine
        return ZStack(alignment: .topLeading) {
            background
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                    .fill(Theme.Preview.accent)
                    .frame(height: 24)
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                            .fill(card)
                            .frame(width: 15, height: 20)
                    }
                }
                Capsule()
                    .fill(line)
                    .frame(width: 36, height: 3)
            }
            .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }
}

/// 「我的」页里压进导航栈的页面
enum MineRoute: Hashable {
    case watchlist
    case transfers
    case page(ManagementPage)
}
