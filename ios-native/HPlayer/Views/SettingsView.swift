import SwiftUI

struct SettingsTab: View {
    var body: some View {
        SettingsView()
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var status: P115Status?
    @State private var loadingStatus = false
    @State private var error = ""
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system

    var body: some View {
        NavigationStack {
            Form {
                accountSection

                Section {
                    AppearancePicker(selection: $appearance)
                        .listRowInsets(EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
                } header: {
                    Text("外观")
                } footer: {
                    Text("播放页始终使用深色，避免画面周围的亮光分散注意力。")
                }

                if !error.isEmpty {
                    Section {
                        Text(error).foregroundColor(.red)
                    }
                }

                Section {
                    HStack(spacing: 14) {
                        BrandLogo(size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("HPlayer")
                                .font(.headline)
                            Text("版本 \(appVersion)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)

                    NavigationLink {
                        LicensesView()
                    } label: {
                        Text("开源许可")
                    }
                } header: {
                    Text("关于")
                } footer: {
                    Text("播放内核使用 mpv / MPVKit（LGPL-3.0），磁力播放使用 Nuvio Engine（GPL-3.0）。")
                }
            }
            .listRowSeparator(.hidden)
            .navigationTitle("设置")
            .task {
                await loadStatus()
            }
            .onChange(of: appState.isAuthenticated) { _ in
                Task { await loadStatus() }
            }
        }
    }

    // MARK: 115 账号

    @ViewBuilder
    private var accountSection: some View {
        Section {
            HStack(spacing: 14) {
                Text("115")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(status?.userName ?? "115 网盘")
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(accountState.color)
                            .frame(width: 7, height: 7)
                        Text(accountState.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)

                if loadingStatus {
                    ProgressView()
                }
            }
            .padding(.vertical, 6)

            NavigationLink {
                CookieWebLoginView(onConnected: { Task { await loadStatus() } })
            } label: {
                Text(appState.isAuthenticated ? "重新登录 115" : "登录 115")
            }
            if appState.isAuthenticated {
                Button("退出 115", role: .destructive) {
                    appState.logout()
                    status = nil
                }
            }
        } footer: {
            Text("115 的登录、浏览和播放都直接在手机上完成，默认播放原画，可在播放页切换 115 转码画质。")
        }
    }

    private var accountState: (text: String, color: Color) {
        let idle = Color(uiColor: .systemGray3)
        guard appState.isAuthenticated else { return ("尚未登录 115", idle) }
        guard let status else { return (loadingStatus ? "检查中" : "已登录", idle) }
        if !status.configured {
            return (status.message ?? "等待授权", Theme.warning)
        }
        if status.error != nil {
            return (status.message ?? "Cookie 可能已失效", Theme.warning)
        }
        return ("已连接", Theme.success)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version)（\(build)）"
    }

    private func loadStatus() async {
        guard appState.isAuthenticated else {
            status = nil
            return
        }
        loadingStatus = true
        defer { loadingStatus = false }
        do {
            if let direct = appState.directClient() {
                status = try await direct.user()
            }
            error = ""
        } catch let err {
            error = err.localizedDescription
        }
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
        List {
            if entries.isEmpty {
                Text("这个版本没有打包许可文件。")
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                NavigationLink {
                    LicenseTextView(title: entry.title, url: entry.url)
                } label: {
                    Text(entry.title)
                }
            }
        }
        .navigationTitle("开源许可")
        .navigationBarTitleDisplayMode(.inline)
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

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AppearanceMode.allCases) { mode in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selection = mode }
                } label: {
                    VStack(spacing: 9) {
                        AppearancePreview(mode: mode)
                            .frame(height: 76)
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(selection == mode ? Theme.accent : Theme.hairline, lineWidth: selection == mode ? 2 : 1)
                            }
                        HStack(spacing: 5) {
                            Image(systemName: selection == mode ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection == mode ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                            Text(mode.title)
                                .foregroundStyle(.primary)
                        }
                        .font(.caption.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
                .accessibilityIdentifier("settings.appearance.\(mode.rawValue)")
            }
        }
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
