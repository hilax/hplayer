import SwiftUI

struct SettingsTab: View {
    var body: some View {
        SettingsView()
    }
}

struct SettingsView: View {
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
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AppearancePicker(selection: $appearance)
                        .listRowInsets(EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
                } header: {
                    Text("外观")
                } footer: {
                    Text("播放页始终使用深色，避免画面周围的亮光分散注意力。")
                }

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
                } footer: {
                    Text(appState.isDirect ? "115 登录、浏览和在线播放直接在手机进行，无需电脑开机。" : "连接自己的后端，可使用服务器转封装与原有开放平台功能。")
                }

                if appState.isDirect {
                    Section("115 账号") {
                        statusRow
                        NavigationLink {
                            CookieWebLoginView(onConnected: { Task { await loadStatus() } })
                        } label: {
                            Label(appState.isAuthenticated ? "重新登录 115" : "登录 115", systemImage: "person.badge.key.fill")
                        }
                        if appState.isAuthenticated {
                            Button("退出 115", role: .destructive) { appState.logout(); status = nil }
                        }
                    }
                    Section {
                        Text("手机直连播放使用 115 在线画质，具体可播格式和清晰度取决于 115 账号及片源。")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                } else {
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
                        Task { await appState.checkAuth() }
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
                } header: {
                    Text("关于")
                } footer: {
                    Text("播放内核使用 VideoLAN VLCKit（LGPL-2.1），磁力播放使用 Nuvio Engine（GPL-3.0）。")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
                }
            }
            .navigationTitle("设置")
            .task {
                await loadStatus()
            }
            .onAppear {
                serverURL = appState.serverURLString
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version)（\(build)）"
    }

    @ViewBuilder
    private var statusRow: some View {
        if !appState.isAuthenticated {
            Text(appState.isDirect ? "尚未登录 115" : "登录后可查看").foregroundColor(.secondary)
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
        } catch let err {
            error = err.localizedDescription
        }
        loggingIn = false
    }

    private func loadStatus() async {
        guard appState.isAuthenticated else { return }
        do {
            if appState.isDirect, let direct = appState.directClient() {
                status = try await direct.user()
            } else if let client = appState.client() {
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
        } catch {
            self.error = error.localizedDescription
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
