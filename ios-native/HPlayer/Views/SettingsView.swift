import SwiftUI

struct SettingsTab: View {
    var body: some View {
        SettingsView()
    }
}

/// 「我的」：账号卡片、三项统计，以及媒体库、外观、关于三组设置。
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var accountInfo: P115AccountInfoStore
    @EnvironmentObject private var recents: RecentStore
    @EnvironmentObject private var localStore: LocalMediaStore
    @EnvironmentObject private var mediaLibrary: MediaLibraryStore

    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system
    @State private var confirmLogout = false
    @State private var showManagement = false

    private var status: P115Status? { appState.isAuthenticated ? accountInfo.status(for: appState.sessionID) : nil }
    private var quota: QuotaResponse? { appState.isAuthenticated ? accountInfo.quota(for: appState.sessionID) : nil }
    private var loadingStatus: Bool { appState.isAuthenticated && accountInfo.isLoading(for: appState.sessionID) }
    private var error: String { appState.isAuthenticated ? accountInfo.error(for: appState.sessionID) : "" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            // 标题栏固定在顶部，内容在它下面滚动
            ScreenTitleBar("我的")
                .padding(.top, 6)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    profileCard.reveal(0)
                    statsRow.reveal(1)
                    mediaGroup.reveal(2)
                    appearanceGroup.reveal(3)
                    aboutGroup.reveal(4)
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.contentInset)
                .padding(.top, 10)
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
            }
            .background(Theme.pageBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .designScreen("settings")
            .confirmationDialog("退出后将断开 115 网盘连接", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("退出 115", role: .destructive) { appState.logout() }
                    .accessibilityIdentifier("settings.account.confirmLogout")
                Button("取消", role: .cancel) {}
            }
        }
        .fullScreenCover(isPresented: $showManagement) { LibraryManagementView() }
    }

    // MARK: 账号卡片

    private var avatarLetter: String? {
        guard appState.isAuthenticated, let name = status?.userName, let first = name.first else { return nil }
        return String(first)
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(Theme.tileTint)
            Circle().strokeBorder(Theme.accentGradient, lineWidth: 2)
            if let letter = avatarLetter {
                Text(letter).font(.display(26)).foregroundStyle(Theme.accent)
            } else {
                Image(systemName: AppIcon.mine.name)
                    .font(.system(size: 26, weight: Theme.iconWeight))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(width: 64, height: 64)
        .animation(Motion.smooth, value: avatarLetter)
        .accessibilityHidden(true)
    }

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                avatar
                VStack(alignment: .leading, spacing: 6) {
                    Text(status?.userName ?? "115 网盘")
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if appState.isAuthenticated { Text("115 网盘 ·") }
                        Circle().fill(accountState.color).frame(width: 6, height: 6)
                        Text(accountState.text).lineLimit(1)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if loadingStatus && status == nil { ProgressView().controlSize(.small) }
                NavigationLink {
                    CookieWebLoginView(onConnected: {})
                        .toolbar(.visible, for: .navigationBar)
                        .hidesTabBar()
                } label: {
                    Image(systemName: AppIcon.switchAccount.name)
                        .font(.system(size: 18, weight: Theme.iconWeight))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.pressable(scale: 0.88)).foregroundStyle(Theme.accent)
                .accessibilityLabel(appState.isAuthenticated ? "重新登录 115" : "登录 115")
                .accessibilityIdentifier("settings.account.login")
                if appState.isAuthenticated {
                    Button { confirmLogout = true } label: {
                        Image(systemName: AppIcon.logout.name)
                            .font(.system(size: 18, weight: Theme.iconWeight))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable(scale: 0.88)).foregroundStyle(Theme.danger)
                    .accessibilityLabel("退出 115")
                    .accessibilityIdentifier("settings.account.logout")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.vertical, 16).padding(.leading, 16).padding(.trailing, 8)

            if !error.isEmpty {
                Divider().padding(.horizontal, 16)
                Label(error, systemImage: AppIcon.alert.name)
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
        .animation(Motion.snappy, value: appState.isAuthenticated)
    }

    // MARK: 统计

    private var statsRow: some View {
        let videos = localStore.files.count + mediaLibrary.files(for: appState).count
        return HStack(spacing: 0) {
            stat("\(videos)", "视频")
            Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 28)
            stat("\(recents.items.count)", "观看记录")
            Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 28)
            stat(quota?.usedText ?? "—", "网盘已用")
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .surfaceCard()
    }

    private func stat(_ value: String, _ title: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.display(20))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .rollingNumber()
                .animation(Motion.smooth, value: value)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: 设置分组

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            GroupLabel(title: title)
            DesignGroup { content() }
        }
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 60)
    }

    private var mediaGroup: some View {
        group("媒体库") {
            Button { showManagement = true } label: {
                LibraryActionRow(symbol: AppIcon.folderSettings.name, title: "媒体库管理",
                                 subtitle: "扫描网盘、匹配封面、整理未匹配影片")
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("mine.manage")
            rowDivider
            NavigationLink {
                MetadataSourcesView().hidesTabBar()
            } label: {
                LibraryActionRow(symbol: AppIcon.tune.name, title: "资料来源",
                                 subtitle: "番组计划、IMDb、TMDB 与番号资料")
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("mine.sources")
            rowDivider
            NavigationLink {
                Official115SettingsView(onSourceChanged: {}).hidesTabBar()
            } label: {
                LibraryActionRow(symbol: AppIcon.verified.name, title: "115 官方授权",
                                 subtitle: "BT 云下载等官方接口使用")
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("mine.official")
        }
    }

    private var appearanceGroup: some View {
        group("外观") {
            NavigationLink { AppearanceSettingsView().hidesTabBar() } label: {
                LibraryActionRow(symbol: AppIcon.appearance.name, title: "显示方式", value: appearance.title)
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("settings.appearance")
        }
    }

    private var aboutGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            group("关于") {
                LibraryActionRow(symbol: AppIcon.info.name, title: "版本", value: appVersion, showsChevron: false)
                rowDivider
                NavigationLink {
                    LicensesView()
                        .toolbar(.visible, for: .navigationBar)
                        .hidesTabBar()
                } label: {
                    LibraryActionRow(symbol: AppIcon.document.name, title: "开源许可")
                }
                .buttonStyle(.pressable(scale: 0.985))
                .accessibilityIdentifier("settings.licenses")
            }
            Text("播放功能使用的开源组件，可在开源许可中查看。")
                .font(.caption).foregroundStyle(Theme.textTertiary)
                .padding(.leading, 6)
        }
    }

    private var accountState: (text: String, color: Color) {
        let idle = Color(uiColor: .systemGray3)
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

struct AppearanceSettingsView: View {
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageIntroduction(eyebrow: "Appearance", title: "你喜欢的观看氛围", subtitle: "选择 HPlayer 的显示方式。", showsTitle: false)
                AppearancePicker(selection: $appearance)
                VStack(alignment: .leading, spacing: 14) {
                    GroupLabel(title: "界面预览")
                    HStack(spacing: 12) {
                        IconTile(icon: .playback, size: 52)
                        VStack(alignment: .leading, spacing: 7) {
                            Text("继续观看").font(.system(size: 15, weight: .semibold))
                            Text("回到上次的故事").font(.caption).foregroundStyle(Theme.textSecondary)
                            ProgressView(value: 0.42).tint(Theme.gold)
                        }
                    }
                    .padding(18).surfaceCard()
                }
                Label("播放页面始终使用深色外观，避免观看时受到亮色界面干扰。", systemImage: AppIcon.appearance.name)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 620).frame(maxWidth: .infinity)
            .padding(Theme.contentInset)
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
                    }.buttonStyle(.plain)
                    if entry.id != entries.last?.id { Divider().padding(.leading, 62) }
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
                                .font(.system(size: 18, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Theme.onPrimary, Theme.gold)
                                .offset(x: 4, y: -4)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                Text(mode.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.hairline, lineWidth: selected ? 2 : 1)
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
        let background = dark ? Color(uiColor: UIColor(hex: 0x0B0C10)) : Color(uiColor: UIColor(hex: 0xF6F3ED))
        let card = dark ? Color(uiColor: UIColor(hex: 0x1E2028)) : Color.white
        let line = dark ? Color.white.opacity(0.3) : Color.black.opacity(0.14)
        return ZStack(alignment: .topLeading) {
            background
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.accentGradient)
                    .frame(height: 24)
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
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
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
