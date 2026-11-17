import SwiftUI

struct SettingsTab: View {
    var body: some View {
        SettingsView()
    }
}

/// 「我的」：HPlayer 账号（评论、弹幕、点赞、签到任务、消息），然后是追番、本机视频和各项设置。
/// 115 网盘的登录、切换、退出都在「网盘」页，这里不放。
/// 播放和弹幕两组直接读写播放器已有的偏好，下次打开播放器时生效；这里只是界面，不碰播放器内核。
struct SettingsView: View {
    @EnvironmentObject private var localStore: LocalMediaStore
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var account = AnimeAccount.shared
    @ObservedObject private var watchlist = AnimeWatchlistStore.shared

    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system
    @State private var titleAway = false
    @State private var signInMode: AnimeSignInSheet.Mode?
    @State private var confirmSignOut = false
    @State private var signing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // 弹幕偏好：和播放页的弹幕设置是同一组键
    @AppStorage(DanmakuPrefs.enabled) private var danmakuEnabled = true
    @AppStorage(DanmakuPrefs.area) private var danmakuArea = 0.5
    @AppStorage(DanmakuPrefs.opacity) private var danmakuOpacity = 0.9

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                ScreenTitleBar("我的")
                    .padding(.horizontal, -Theme.contentInset)
                    .scrolledAway($titleAway)
                accountCard.reveal(0)
                activityGroup.reveal(1)
                settingsGroup.reveal(2)
                if account.isSignedIn { signOutRow.reveal(3) }
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
        .refreshable { await account.refresh() }
        .task { await account.refreshIfNeeded() }
        .sheet(item: $signInMode) { mode in AnimeSignInSheet(startWith: mode) }
    }

    // MARK: 账号

    private var avatarLetter: String? {
        guard let first = account.user?.displayName.first else { return nil }
        return String(first)
    }

    private func avatar(size: CGFloat) -> some View {
        ZStack {
            Circle().fill(Theme.surfaceHigh)
            if let letter = avatarLetter {
                Text(letter)
                    .font(.scaled(size * 0.4, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .transition(.opacity)
            } else {
                Image(icon: .mine)
                    .font(.scaled(size * 0.42, weight: Theme.iconWeight))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .animation(Motion.smooth, value: avatarLetter)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var accountCard: some View {
        if account.isSignedIn {
            signedInCard
        } else {
            signedOutCard
        }
    }

    /// 没登录：一句说明 + 登录 / 注册两个按钮
    private var signedOutCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            HStack(spacing: Theme.Space.md + 2) {
                avatar(size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("登录 HPlayer 账号")
                        .font(Theme.Typo.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("评论、弹幕、点赞和签到领金币都要先登录")
                        .font(Theme.Typo.meta)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !account.lastError.isEmpty {
                DesignNotice(symbol: AppIcon.alert.name, text: account.lastError, warning: true)
            }
            HStack(spacing: Theme.Space.md) {
                Button("登录") { signInMode = .signIn }
                    .buttonStyle(PrimaryActionStyle())
                    .accessibilityIdentifier("mine.account.signIn")
                Button("注册") { signInMode = .signUp }
                    .buttonStyle(SecondaryActionStyle())
                    .accessibilityIdentifier("mine.account.signUp")
            }
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
    }

    /// 已登录：头像、名字，一排数字（金币 / 连续签到 / 未读消息），下面今天的签到
    private var signedInCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            HStack(spacing: Theme.Space.md + 2) {
                avatar(size: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.user?.displayName ?? "HPlayer 用户")
                        .font(.display(20))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let user = account.user, user.isVip {
                        TagBadge(text: "VIP", style: .accent)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                stat("\(account.user?.coin ?? 0)", "金币")
                stat("\(account.user?.signDays ?? 0)", "连续签到")
                stat("\(account.totalUnread)", "未读消息")
            }
            .padding(.top, Theme.Space.md)
            .overlay(alignment: .top) { Theme.rule.frame(height: Theme.Stroke.hairline) }
            signStrip
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
        .animation(reduceMotion ? nil : Motion.smooth, value: account.user)
    }

    private func stat(_ value: String, _ title: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.display(22))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .rollingNumber()
            Text(title)
                .font(Theme.Typo.meta)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var signStrip: some View {
        HStack(spacing: Theme.Space.md) {
            Image(icon: .checkIn)
                .font(.scaled(18, weight: Theme.iconWeight))
                .foregroundStyle(account.signedToday ? Theme.textTertiary : Theme.accent)
            Text(account.signedToday ? "今天已签到" : "今天还没签到")
                .font(Theme.Typo.row)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: Theme.Space.sm)
            if !account.signedToday {
                Button {
                    signing = true
                    Task {
                        defer { signing = false }
                        do { try await account.signToday() } catch { account.lastError = error.localizedDescription }
                    }
                } label: {
                    Text(signing ? "签到中" : "签到 +\(account.signCoin)")
                        .font(Theme.Typo.meta.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.onPrimary)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(Theme.primaryAction, in: Capsule())
                }
                .buttonStyle(.pressable(scale: 0.95))
                .disabled(signing)
                .accessibilityIdentifier("mine.signToday")
            }
        }
        .padding(.leading, Theme.Space.md + 2)
        .padding(.trailing, Theme.Space.sm)
        .frame(minHeight: 48)
        .background(Theme.tileTint, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }

    /// 正在下载的个数（含排队）；没有下载时显示视频数
    private var activeDownloads: Int {
        downloads.items.filter { $0.state == .downloading || $0.state == .queued }.count
    }

    /// 任务中心、消息通知（登录后才有）、追番收藏、本机视频
    private var activityGroup: some View {
        SettingsSection(title: "") {
            if account.isSignedIn {
                NavigationLink(value: MineRoute.tasks) {
                    LibraryActionRow(symbol: AppIcon.checklist.name, title: "任务中心",
                                     value: account.signedToday ? "" : "可签到",
                                     valueHighlighted: !account.signedToday)
                }
                .buttonStyle(.pressable(scale: 0.985))
                .accessibilityIdentifier("mine.tasks")
                NavigationLink(value: MineRoute.messages) {
                    LibraryActionRow(symbol: AppIcon.bell.name, title: "消息通知",
                                     value: account.totalUnread > 0 ? "\(account.totalUnread)" : "",
                                     valueHighlighted: account.totalUnread > 0)
                }
                .buttonStyle(.pressable(scale: 0.985))
                .accessibilityIdentifier("mine.messages")
            }
            NavigationLink(value: MineRoute.watchlist) {
                LibraryActionRow(symbol: AppIcon.follow.name, title: "追番收藏",
                                 value: watchlist.items.isEmpty ? "" : "\(watchlist.items.count)")
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("mine.watchlist")
            NavigationLink(value: MineRoute.page(.localVideos)) {
                LibraryActionRow(symbol: AppIcon.device.name, title: "本机视频",
                                 value: activeDownloads > 0 ? "\(activeDownloads) 个下载中"
                                     : (localStore.files.isEmpty ? "" : "\(localStore.files.count)"),
                                 valueHighlighted: activeDownloads > 0)
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("mine.local")
        }
    }

    private var signOutRow: some View {
        Button { confirmSignOut = true } label: {
            Text("退出登录")
                .font(Theme.Typo.row.weight(.medium))
                .foregroundStyle(Theme.danger)
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.985))
        .surfaceCard()
        .accessibilityIdentifier("mine.account.signOut")
        .confirmationDialog("退出 HPlayer 账号？", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { Task { await account.signOut() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出后不能发评论和弹幕；115 网盘不受影响。")
        }
    }

    // MARK: 设置

    /// 设置收成一组：播放、弹幕、外观、媒体库管理、关于，各自推进二级页
    private var settingsGroup: some View {
        SettingsSection(title: "设置") {
            NavigationLink { PlaybackSettingsView() } label: {
                LibraryActionRow(symbol: AppIcon.playback.name, title: "播放")
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("mine.playback")
            NavigationLink { DanmakuStyleView() } label: {
                LibraryActionRow(symbol: AppIcon.danmaku.name, title: "弹幕",
                                 value: danmakuEnabled ? DanmakuStyleView.summary(area: danmakuArea, opacity: danmakuOpacity) : "已关闭")
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("mine.danmaku.style")
            NavigationLink { AppearanceSettingsView() } label: {
                LibraryActionRow(symbol: AppIcon.appearance.name, title: "外观", value: appearance.title)
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("settings.appearance")
            // 和其他二级页面一样从右侧推入，用系统返回键；资料来源在媒体库管理里
            NavigationLink { LibraryManagementView(pushed: true) } label: {
                LibraryActionRow(symbol: AppIcon.folderSettings.name, title: "媒体库管理")
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("mine.manage")
            NavigationLink { AboutView() } label: {
                LibraryActionRow(symbol: AppIcon.info.name, title: "关于", value: AboutView.shortVersion)
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("settings.about")
        }
    }
}

// MARK: - 播放设置

/// 「我的 › 播放」：自动连播、自动小窗、字幕样式、边播边存、解码方式。和播放页用的是同一组偏好。
struct PlaybackSettingsView: View {
    @AppStorage("player.autoPlayNext") private var autoPlayNext = true
    @State private var decoding = VideoDecoding.saved
    @State private var readahead = ReadaheadLevel.saved
    @State private var subtitleStyle = SubtitleStyle.saved
    @State private var autoPictureInPicture = PictureInPictureSettings.automatic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
        SettingsSection(title: "", footnote: "从下一次打开播放器开始生效。播放时也可以在播放页的「更多」里临时调整。") {
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
                SettingsMenuPicker(label: "字幕样式", selection: $subtitleStyle, options: SubtitleStyle.allCases,
                                   title: \.title, identifier: "mine.playback.subtitle")
            }
            SettingRow(icon: .readahead, title: "边播边存") {
                SettingsMenuPicker(label: "边播边存", selection: $readahead, options: ReadaheadLevel.allCases,
                                   title: \.title, identifier: "mine.playback.readahead")
            }
            SettingRow(icon: .decoder, title: "解码方式") {
                SettingsMenuPicker(label: "解码方式", selection: $decoding, options: VideoDecoding.allCases,
                                   title: \.title, identifier: "mine.playback.decoding")
            }
        }
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.contentInset)
            .padding(.vertical, Theme.Space.lg)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("播放")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .designScreen("playback-settings")
        // 播放页里也能改这几项：回到这一页时重新读一遍
        .onAppear {
            decoding = VideoDecoding.saved
            readahead = ReadaheadLevel.saved
            subtitleStyle = SubtitleStyle.saved
            autoPictureInPicture = PictureInPictureSettings.automatic
        }
        .onChange(of: decoding) { VideoDecoding.saved = $0 }
        .onChange(of: readahead) { ReadaheadLevel.saved = $0 }
        .onChange(of: subtitleStyle) { SubtitleStyle.saved = $0 }
        .onChange(of: autoPictureInPicture) { PictureInPictureSettings.automatic = $0 }
    }
}

// MARK: - 关于

/// 「我的 › 关于」：版本（长按进接口诊断）、开源许可
struct AboutView: View {
    @State private var showDiagnostics = false

    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                SettingsSection(title: "") {
                    // 长按版本号进入接口诊断：登录后对一下账号接口的真实返回
                    LibraryActionRow(symbol: AppIcon.version.name, title: "版本", value: appVersion, showsChevron: false)
                        .contentShape(Rectangle())
                        .onLongPressGesture(minimumDuration: 0.8) {
                            Haptics.success()
                            showDiagnostics = true
                        }
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
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.contentInset)
            .padding(.vertical, Theme.Space.lg)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .navigationDestination(isPresented: $showDiagnostics) { AnimeDiagnosticsView() }
        .designScreen("about")
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version)（\(build)）"
    }
}

/// 行尾的下拉选择：系统菜单样式，显示当前值
private struct SettingsMenuPicker<Option: Hashable & Identifiable>: View {
    let label: String
    @Binding var selection: Option
    let options: [Option]
    let title: KeyPath<Option, String>
    let identifier: String

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(options) { option in
                Text(option[keyPath: title]).tag(option)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .tint(Theme.textSecondary)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - 弹幕样式

/// 弹幕样式：上面一块固定的实时预览，下面是区域、不透明度、字号、速度。
/// 和播放页的弹幕设置读写同一组偏好。
struct DanmakuStyleView: View {
    @AppStorage(DanmakuPrefs.enabled) private var enabled = true
    @AppStorage(DanmakuPrefs.area) private var area = 0.5
    @AppStorage(DanmakuPrefs.opacity) private var opacity = 0.9
    @AppStorage(DanmakuPrefs.scale) private var scale = 1.0
    @AppStorage(DanmakuPrefs.speed) private var speed = 1.0

    static func summary(area: Double, opacity: Double) -> String {
        let name: String
        switch area {
        case ..<0.3: name = "1/4 屏"
        case ..<0.6: name = "半屏"
        case ..<0.9: name = "3/4 屏"
        default: name = "全屏"
        }
        return "\(name) · \(Int((opacity * 100).rounded()))%"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                SettingsSection(title: "") {
                    SettingRow(icon: .danmaku, title: "显示弹幕") {
                        Toggle("显示弹幕", isOn: $enabled)
                            .labelsHidden()
                            .tint(Theme.accentFill)
                            .accessibilityIdentifier("mine.danmaku")
                    }
                }
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    DanmakuPreview(area: area, opacity: opacity, scale: scale, enabled: enabled)
                    if !enabled {
                        Text("弹幕已关闭，预览里不显示。打开上面的开关即可。")
                            .font(Theme.Typo.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, Theme.Space.xs)
                    }
                }

                SettingsSection(title: "显示区域") {
                    Picker("显示区域", selection: $area) {
                        Text("1/4").tag(0.25)
                        Text("半屏").tag(0.5)
                        Text("3/4").tag(0.75)
                        Text("全屏").tag(1.0)
                    }
                    .pickerStyle(.segmented)
                    .padding(Theme.Space.md)
                    .accessibilityIdentifier("mine.danmaku.area")
                }

                SettingsSection(title: "外观", footnote: "和播放页里的弹幕设置是同一组，改哪边都一样。") {
                    sliderRow("不透明度", value: $opacity, range: 0.2...1, step: 0.05,
                              text: "\(Int((opacity * 100).rounded()))%", identifier: "mine.danmaku.opacity")
                    sliderRow("字号", value: $scale, range: 0.7...1.5, step: 0.1,
                              text: String(format: "%.1f×", scale), identifier: "mine.danmaku.scale")
                    sliderRow("速度", value: $speed, range: 0.6...1.6, step: 0.1,
                              text: String(format: "%.1f×", speed), identifier: "mine.danmaku.speed")
                }
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.contentInset)
            .padding(.vertical, Theme.Space.lg)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("弹幕")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .designScreen("danmaku-style")
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
            }
            Slider(value: value, in: range, step: step)
                .tint(Theme.accentFill)
                .accessibilityLabel(title)
                .accessibilityValue(text)
                .accessibilityIdentifier(identifier)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
    }
}

/// 弹幕样式的实时预览：一块 16:9 的深色「画面」，按当前的区域、不透明度和字号摆几条示例弹幕。
/// 弹幕能用的区域在上面，下沿一条虚线。示例弹幕按轨道排，不会叠在一起。
private struct DanmakuPreview: View {
    let area: Double
    let opacity: Double
    let scale: Double
    let enabled: Bool

    private static let samples = ["前方高能", "这一段配乐太好了", "第一次看到这里", "名场面", "哈哈哈哈", "终于更新了", "已三刷", "BGM 是什么"]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let fontSize = DanmakuPrefs.baseFontSize * CGFloat(scale) * 0.8
            let lane = fontSize + 10
            let usable = size.height * CGFloat(area)
            let lanes = max(1, Int((usable - 6) / lane))
            ZStack(alignment: .topLeading) {
                Theme.ink
                Rectangle()
                    .fill(Theme.paper.opacity(Theme.Opacity.hint))
                    .frame(height: usable)
                Rectangle()
                    .fill(Theme.paper.opacity(Theme.Opacity.soft))
                    .frame(height: 1)
                    .offset(y: usable - 1)
                if enabled {
                    ForEach(0..<min(lanes, Self.samples.count), id: \.self) { index in
                        Text(Self.samples[index])
                            .font(.system(size: fontSize, weight: .semibold))
                            .foregroundStyle(Theme.paper)
                            .shadow(color: .black.opacity(Theme.Opacity.strong), radius: 1, x: 0, y: 1)
                            .lineLimit(1)
                            .fixedSize()
                            .opacity(opacity)
                            .offset(x: index.isMultiple(of: 2) ? size.width * 0.08 + CGFloat(index) * 10
                                                               : size.width * 0.42 + CGFloat(index) * 6,
                                    y: 6 + CGFloat(index) * lane)
                    }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline)
        }
        .animation(Motion.quick, value: area)
        .animation(Motion.quick, value: scale)
        .accessibilityElement()
        .accessibilityLabel("弹幕预览")
    }
}

// MARK: - 外观

/// 外观：三张手机小预览（跟随系统 / 浅色 / 深色），下面是单选圈，和系统「显示与亮度」一样的选法。
struct AppearanceSettingsView: View {
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                SettingsSection(title: "显示方式",
                                footnote: "「跟随系统」会随 iPhone 的深浅色设置自动切换。播放页始终是深色，看片时不受亮色界面干扰。") {
                    AppearancePicker(selection: $appearance)
                        .padding(.horizontal, Theme.Space.lg)
                        .padding(.vertical, Theme.Space.page)
                }
                SettingsSection(title: "") {
                    NavigationLink { AppIconSettingsView() } label: {
                        LibraryActionRow(symbol: AppIcon.appIconStyle.name, title: "应用图标")
                    }
                    .buttonStyle(.pressable(scale: 0.985))
                    .accessibilityIdentifier("settings.appIcon")
                }
            }
            .frame(maxWidth: 620).frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.contentInset)
            .padding(.vertical, Theme.Space.lg)
        }
        .scrollIndicators(.hidden)
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

/// 外观选择：三张手机小预览 + 名称 + 单选圈。大字号时改成竖排。
private struct AppearancePicker: View {
    @Binding var selection: AppearanceMode
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: Theme.Space.lg))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Theme.Space.md))
        layout {
            ForEach(AppearanceMode.allCases) { mode in option(mode) }
        }
    }

    private func option(_ mode: AppearanceMode) -> some View {
        let selected = selection == mode
        return Button {
            guard selection != mode else { return }
            Haptics.select()
            withAnimation(reduceMotion ? nil : Motion.snappy) { selection = mode }
        } label: {
            VStack(spacing: Theme.Space.md) {
                AppearancePreview(mode: mode)
                    .aspectRatio(0.62, contentMode: .fit)
                    .frame(maxWidth: 96)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .strokeBorder(selected ? Theme.primaryAction : Theme.rule,
                                          lineWidth: selected ? 2 : Theme.Stroke.hairline)
                    }
                Text(mode.title)
                    .font(Theme.Typo.meta.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                CheckBadge(selected: selected, size: 22)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.97))
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.appearance.\(mode.rawValue)")
    }
}

/// 外观预览：画一部很小的手机——标题条、一排三张海报、一条琥珀进度线、底部标签栏胶囊。
/// 「跟随系统」左半浅色、右半深色。颜色取 `Theme.Preview` 的两套固定值。
private struct AppearancePreview: View {
    let mode: AppearanceMode

    var body: some View {
        Group {
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
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func miniScreen(dark: Bool) -> some View {
        let background = dark ? Theme.Preview.darkPage : Theme.Preview.lightPage
        let card = dark ? Theme.Preview.darkCard : Theme.Preview.lightCard
        let line = dark ? Theme.Preview.darkLine : Theme.Preview.lightLine
        return GeometryReader { proxy in
            let width = proxy.size.width
            let unit = width / 12
            ZStack(alignment: .top) {
                background
                VStack(alignment: .leading, spacing: unit * 0.8) {
                    // 标题
                    Capsule().fill(line).frame(width: width * 0.42, height: unit * 0.9)
                        .padding(.top, unit * 1.6)
                    // 一张横卡和进度线
                    VStack(alignment: .leading, spacing: unit * 0.4) {
                        RoundedRectangle(cornerRadius: unit * 0.6, style: .continuous)
                            .fill(card)
                            .frame(height: unit * 4.2)
                        Capsule().fill(Theme.Preview.accent).frame(width: width * 0.38, height: unit * 0.35)
                    }
                    // 一排三张海报
                    HStack(spacing: unit * 0.5) {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: unit * 0.4, style: .continuous)
                                .fill(card)
                                .aspectRatio(2 / 3, contentMode: .fit)
                        }
                    }
                    Spacer(minLength: 0)
                    // 底部标签栏
                    Capsule().fill(card)
                        .frame(height: unit * 1.6)
                        .padding(.bottom, unit * 0.8)
                }
                .padding(.horizontal, unit)
            }
        }
    }
}

/// 「我的」页里压进导航栈的页面
enum MineRoute: Hashable {
    case watchlist
    case tasks
    case messages
    case page(ManagementPage)
}
