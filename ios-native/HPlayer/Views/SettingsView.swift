import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var status: P115Status?
    @State private var cookie = ""
    @State private var message = ""
    @State private var error = ""
    @State private var saving = false
    @State private var serverURL = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器地址") {
                    TextField("https://...", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("保存地址") {
                        appState.setServer(serverURL)
                        Task { await appState.checkAuth() }
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

                Section {
                    Button("退出登录", role: .destructive) {
                        appState.logout()
                        dismiss()
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
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
        if let status {
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

    private func loadStatus() async {
        guard let client = appState.client() else { return }
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
