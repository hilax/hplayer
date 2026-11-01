import SwiftUI

struct SettingsTab: View {
    var body: some View {
        SettingsView()
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var accountInfo: P115AccountInfoStore

    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system
    @State private var confirmLogout = false

    private var status: P115Status? { appState.isAuthenticated ? accountInfo.status(for: appState.sessionID) : nil }
    private var loadingStatus: Bool { appState.isAuthenticated && accountInfo.isLoading(for: appState.sessionID) }
    private var error: String { appState.isAuthenticated ? accountInfo.error(for: appState.sessionID) : "" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    accountSection
                    appearanceSection
                    aboutSection
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.contentInset)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .background(Theme.pageBackground.ignoresSafeArea())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .designScreen("settings")
            .confirmationDialog("退出后将断开 115 网盘连接", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("退出 115", role: .destructive) { appState.logout() }
                    .accessibilityIdentifier("settings.account.confirmLogout")
                Button("取消", role: .cancel) {}
            }
        }
    }

    // MARK: 115 账号

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupLabel(title: "账号与连接")
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "person")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 45, height: 45)
                        .background(Theme.tileTint, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(status?.userName ?? "115 网盘")
                            .font(.headline).lineLimit(1)
                        HStack(spacing: 5) {
                            if appState.isAuthenticated { Text("115 网盘 ·") }
                            Circle().fill(accountState.color).frame(width: 6, height: 6)
                            Text(accountState.text).lineLimit(1)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if loadingStatus && status == nil { ProgressView().controlSize(.small) }
                    NavigationLink {
                        CookieWebLoginView(onConnected: {})
                            .toolbar(.visible, for: .navigationBar)
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                    .accessibilityLabel(appState.isAuthenticated ? "重新登录 115" : "登录 115")
                    .accessibilityIdentifier("settings.account.login")
                    if appState.isAuthenticated {
                        Button { confirmLogout = true } label: {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).foregroundStyle(.red)
                        .accessibilityLabel("退出 115")
                        .accessibilityIdentifier("settings.account.logout")
                    }
                }
                .padding(.vertical, 16).padding(.leading, 14).padding(.trailing, 10)

                if !error.isEmpty {
                    Divider().padding(.horizontal, 16)
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                }
            }
            .surfaceCard()
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupLabel(title: "外观")
            NavigationLink { AppearanceSettingsView() } label: {
                LibraryActionRow(symbol: "moon", title: "显示方式", value: appearance.title)
                    .surfaceCard()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.appearance")
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupLabel(title: "关于")
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Theme.accent)
                        .frame(width: 32, height: 32)
                        .background(Theme.tileTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text("版本").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(appVersion).font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(minHeight: 52).padding(.horizontal, 16)
                Divider().padding(.horizontal, 16)
                NavigationLink {
                    LicensesView()
                        .toolbar(.visible, for: .navigationBar)
                } label: {
                    settingsRow(title: "开源许可", systemImage: "doc.text", tint: Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.licenses")
            }
            .surfaceCard()
            Text("播放功能使用的开源组件，可在开源许可中查看。")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 6)
        }
    }

    private func settingsRow(title: String, systemImage: String, tint: Color, chevron: Bool = true) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(chevron ? Color.primary : tint)
            Spacer(minLength: 8)
            if chevron {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
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
                        Image(systemName: "play.rectangle.fill")
                            .font(.largeTitle).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 7) {
                            Text("继续观看").font(.headline)
                            Text("回到上次的故事").font(.caption).foregroundStyle(.secondary)
                            ProgressView(value: 0.42).tint(Theme.accent)
                        }
                    }
                    .padding(18).surfaceCard()
                }
                Label("播放页面始终使用深色外观，避免观看时受到亮色界面干扰。", systemImage: "moon")
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
                        LibraryActionRow(symbol: "doc.text", title: entry.title, subtitle: entryDetail(entry.id))
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
            withAnimation(.easeInOut(duration: 0.2)) { selection = mode }
        } label: {
            VStack(spacing: 9) {
                AppearancePreview(mode: mode)
                    .frame(height: 116)
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Theme.accent)
                                .offset(x: 4, y: -4)
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
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.hairline, lineWidth: selected ? 2 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        let background = dark ? Color.black : Color(uiColor: UIColor(hex: 0xF2F2F7))
        let card = dark ? Color(uiColor: UIColor(hex: 0x2C2C2E)) : Color.white
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
