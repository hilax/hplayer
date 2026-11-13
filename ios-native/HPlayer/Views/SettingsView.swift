import SwiftUI

struct SettingsTab: View {
    var body: some View {
        SettingsView()
    }
}

/// 「我的」：账号，然后是播放、弹幕、外观、媒体库、关于。
/// 追番在动漫频道、观看记录在首页「继续观看」、传输中心在网盘页，这里都不重复。
/// 播放和弹幕两组直接读写播放器已有的偏好，下次打开播放器时生效；这里只是界面，不碰播放器内核。
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var accountInfo: P115AccountInfoStore

    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system
    @State private var confirmLogout = false
    @State private var titleAway = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    private var status: P115Status? { appState.isAuthenticated ? accountInfo.status(for: appState.sessionID) : nil }
    private var loadingStatus: Bool { appState.isAuthenticated && accountInfo.isLoading(for: appState.sessionID) }
    private var error: String { appState.isAuthenticated ? accountInfo.error(for: appState.sessionID) : "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                ScreenTitleBar("我的")
                    .padding(.horizontal, -Theme.contentInset)
                    .scrolledAway($titleAway)
                profileCard.reveal(0)
                playbackGroup.reveal(1)
                danmakuGroup.reveal(2)
                appearanceGroup.reveal(3)
                mediaGroup.reveal(4)
                aboutGroup.reveal(5)
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

    // MARK: 播放

    private var playbackGroup: some View {
        SettingsSection(title: "播放", footnote: "从下一次打开播放器开始生效。播放时也可以在播放页的「更多」里临时调整。") {
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

    // MARK: 弹幕

    /// 弹幕：开关在这里；样式（区域、不透明度、字号、速度）放进单独一页，带实时预览。
    private var danmakuGroup: some View {
        SettingsSection(title: "弹幕") {
            SettingRow(icon: .danmaku, title: "显示弹幕") {
                Toggle("显示弹幕", isOn: $danmakuEnabled)
                    .labelsHidden()
                    .tint(Theme.accentFill)
                    .accessibilityIdentifier("mine.danmaku")
            }
            NavigationLink { DanmakuStyleView() } label: {
                LibraryActionRow(symbol: AppIcon.danmakuStyle.name, title: "弹幕样式", value: DanmakuStyleView.summary(area: danmakuArea, opacity: danmakuOpacity))
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("mine.danmaku.style")
        }
    }

    // MARK: 外观、媒体库、关于

    private var appearanceGroup: some View {
        SettingsSection(title: "外观") {
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
        SettingsSection(title: "媒体库") {
            // 和其他二级页面一样从右侧推入，用系统返回键
            NavigationLink { LibraryManagementView(pushed: true) } label: {
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
        SettingsSection(title: "关于") {
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
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    DanmakuPreview(area: area, opacity: opacity, scale: scale, enabled: enabled)
                    if !enabled {
                        Text("弹幕已关闭，预览里不显示。可以在「我的」里打开。")
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
        .navigationTitle("弹幕样式")
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
    case transfers
    case page(ManagementPage)
}
