import SwiftUI

struct SettingsTab: View {
    var body: some View {
        SettingsView()
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var status: P115Status?
    @State private var cookie = ""
    @State private var message = ""
    @State private var error = ""
    @State private var saving = false
    @State private var serverURL = ""
    @State private var password = ""
    @State private var loggingIn = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://hplayer.example.com", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

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
                            .textContentType(.password)
                        Button(loggingIn ? "登录中…" : "登录") {
                            Task { await login() }
                        }
                        .disabled(password.isEmpty || loggingIn || !appState.hasServer)
                    }
                }

                Section("115 账号") {
                    statusRow
                }

                Section("更新 Cookie") {
                    TextEditor(text: $cookie)
                        .frame(minHeight: 100)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button(saving ? "验证中…" : "保存并验证") {
                        Task { await saveCookie() }
                    }
                    .disabled(cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
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
            .navigationTitle("设置")
            .task {
                await loadStatus()
            }
            .onAppear {
                serverURL = appState.serverURLString
            }
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
        } catch let err {
            error = err.localizedDescription
        }
        loggingIn = false
    }

    private func loadStatus() async {
        guard appState.isAuthenticated, let client = appState.client() else { return }
        do {
            status = try await client.get("/api/115/status")
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
}
