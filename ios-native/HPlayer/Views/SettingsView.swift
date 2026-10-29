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
                    Picker("连接方式", selection: Binding(get: { appState.mode }, set: { mode in
                        appState.setMode(mode)
                        status = nil
                        error = ""
                        Task { await appState.checkAuth(); await loadStatus() }
                    })) {
                        Text("手机直连").tag(AppState.ConnectionMode.device)
                        Text("服务器").tag(AppState.ConnectionMode.server)
                    }
                    .pickerStyle(.segmented)

                    if !appState.isDirect {
                        NavigationLink {
                            ServerSettingsView(onChanged: { Task { await loadStatus() } })
                        } label: {
                            HStack(spacing: 12) {
                                IconTile(systemImage: "server.rack", colors: [Theme.brandBlue, Theme.brandViolet], size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("服务器设置")
                                    Text("地址 · 访问密码 · Cookie · 开放平台授权")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("连接方式")
                } footer: {
                    Text(appState.isDirect ? "115 登录、浏览和在线播放直接在手机进行，无需电脑开机。" : "连接自己的后端，可使用服务器转封装与开放平台功能。")
                }

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
                    Text("播放内核使用 VideoLAN VLCKit（LGPL-2.1），磁力播放使用 Nuvio Engine（GPL-3.0）。")
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

            if appState.isDirect {
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
            }
        } footer: {
            if appState.isDirect {
                Text("手机直连播放使用 115 在线画质，具体可播格式和清晰度取决于 115 账号及片源。")
            }
        }
    }

    private var accountState: (text: String, color: Color) {
        let mode = appState.isDirect ? "手机直连" : "服务器模式"
        let idle = Color(uiColor: .systemGray3)
        guard appState.isAuthenticated else {
            return (appState.isDirect ? "尚未登录 115" : "\(mode) · 未登录服务器", idle)
        }
        guard let status else { return (loadingStatus ? "\(mode) · 检查中" : mode, idle) }
        if !status.configured {
            return ("\(mode) · \(status.message ?? "等待授权")", Theme.warning)
        }
        if status.error != nil {
            return ("\(mode) · \(status.message ?? "Cookie 可能已失效")", Theme.warning)
        }
        return ("已连接 · \(mode)", Theme.success)
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
            if appState.isDirect, let direct = appState.directClient() {
                status = try await direct.user()
            } else if let client = appState.client() {
                status = try await client.get("/api/115/status")
            }
            error = ""
        } catch let err {
            error = err.localizedDescription
        }
    }
}

/// 服务器模式的二级页：后端地址、访问密码、当前 115 账号、开放平台授权和 Cookie。
struct ServerSettingsView: View {
    var onChanged: () -> Void = { }

    @EnvironmentObject private var appState: AppState
    private enum Field: Hashable { case server, password, cookie }
    @FocusState private var focusedField: Field?

    @State private var status: P115Status?
    @State private var cookie = ""
    @State private var message = ""
    @State private var error = ""
    @State private var saving = false
    @State private var serverURL = ""
    @State private var password = ""
    @State private var loggingIn = false

    var body: some View {
        Form {
            Section {
                TextField("https://hplayer.example.com", text: $serverURL)
                    .focused($focusedField, equals: .server)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { focusedField = nil }

                Button("保存地址") {
                    appState.setServer(serverURL)
                    Task { await appState.checkAuth(); onChanged() }
                }
            } header: {
                Text("服务器")
            } footer: {
                Text("HPlayer 后端地址，需要以 http:// 或 https:// 开头")
            }

            Section("登录") {
                if appState.isAuthenticated {
                    HStack {
                        Text("已登录")
                        Spacer()
                        Button("退出", role: .destructive) {
                            appState.logout()
                            status = nil
                            onChanged()
                        }
                    }
                } else {
                    SecureField("访问密码", text: $password)
                        .focused($focusedField, equals: .password)
                        .textContentType(.password)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                    Button(loggingIn ? "登录中…" : "登录") {
                        Task { await login() }
                    }
                    .disabled(password.isEmpty || loggingIn || !appState.hasServer)
                }
            }

            Section("当前 115 账号") {
                statusRow
            }

            Section("115 开放平台") {
                NavigationLink {
                    Official115SettingsView(onSourceChanged: {
                        Task { await loadStatus() }
                    })
                } label: {
                    Label("115 开放平台授权", systemImage: "key.horizontal")
                }
                .disabled(!appState.isAuthenticated)
            }

            Section("更新 Cookie") {
                TextEditor(text: $cookie)
                    .focused($focusedField, equals: .cookie)
                    .frame(minHeight: 100)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button(saving ? "验证中…" : "保存并验证") {
                    Task { await saveCookie() }
                }
                .disabled(cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                Button("使用已保存的 Cookie") {
                    Task { await useSavedCookie() }
                }
                .disabled(!appState.isAuthenticated || saving)
            }

            if !error.isEmpty {
                Section {
                    Text(error).foregroundColor(.red)
                }
            }

            if !message.isEmpty {
                Section {
                    Text(message).foregroundColor(.green)
                }
            }
        }
        .listRowSeparator(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = nil }
            }
        }
        .navigationTitle("服务器设置")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadStatus()
        }
        .onAppear {
            serverURL = appState.serverURLString
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if !appState.isAuthenticated {
            Text("登录后可查看").foregroundColor(.secondary)
        } else if let status {
            if !status.configured {
                Text(status.message ?? "未配置 Cookie")
                    .foregroundColor(.secondary)
            } else if let detail = status.error {
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.message ?? "Cookie 可能已失效")
                        .foregroundColor(.red)
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("已连接：\(status.userName ?? "")")
            }
        } else {
            ProgressView()
        }
    }

    private func login() async {
        loggingIn = true
        error = ""
        do {
            try await appState.login(password: password)
            password = ""
            await loadStatus()
            onChanged()
        } catch let err {
            error = err.localizedDescription
        }
        loggingIn = false
    }

    private func loadStatus() async {
        guard appState.isAuthenticated else { return }
        do {
            if let client = appState.client() {
                status = try await client.get("/api/115/status")
            }
        } catch let err {
            error = err.localizedDescription
        }
    }

    private func saveCookie() async {
        guard let client = appState.client() else { return }
        saving = true
        error = ""
        message = ""
        do {
            let result: CookieResponse = try await client.post(
                "/api/115/cookie",
                body: ["cookie": cookie]
            )
            message = "已连接：\(result.userName)"
            cookie = ""
            await loadStatus()
            onChanged()
        } catch let err {
            error = err.localizedDescription
        }
        saving = false
    }

    private func useSavedCookie() async {
        guard let client = appState.client() else { return }
        saving = true
        error = ""
        message = ""
        defer { saving = false }
        do {
            let _: SourceResponse = try await client.post("/api/115/open/source", body: ["source": "cookie"])
            message = "已切换到 Cookie"
            await loadStatus()
            onChanged()
        } catch {
            self.error = error.localizedDescription
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
            ("VLCKit-COPYING", "txt", "VideoLAN VLCKit"),
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
                ?? Bundle.main.url(forResource: file.name, withExtension: file.ext, subdirectory: "VLCLicenses")
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

private struct SourceResponse: Decodable {
    let ok: Bool
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
