import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

private struct Open115Status: Decodable {
    let configured: Bool
    let authorized: Bool
    let message: String?
    let userName: String?
}

private struct Open115Start: Decodable {
    let verificationUri: String
    let userCode: String?
    let expiresIn: Int
}

private struct Open115Poll: Decodable {
    let status: String
    let message: String?
}

private struct Open115ConfigResponse: Decodable {
    let ok: Bool
}

private struct Open115WebStart: Decodable {
    let authorizationUrl: String
    let expiresIn: Int
}

struct Official115SettingsView: View {
    private enum Field: Hashable { case clientId, clientSecret, redirectURI, cookie }
    @FocusState private var focusedField: Field?
    let onSourceChanged: () -> Void
    @EnvironmentObject private var appState: AppState
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var status: Open115Status?
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var redirectURI = ""
    @State private var cookie = ""
    @State private var authorization: Open115Start?
    @State private var pollTask: Task<Void, Never>?
    @State private var webDeadline: Date?
    @State private var busy = false
    @State private var message = ""
    @State private var error = ""

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: status?.authorized == true ? "checkmark.shield.fill" : "lock.shield")
                        .font(.title2)
                        .foregroundStyle(Theme.accentGradient)
                        .frame(width: 42, height: 42)
                        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(statusTitle).font(.headline)
                        Text(statusDetail).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            } header: {
                Text("连接状态")
            }

            if !appState.isDirect { Section {
                NavigationLink {
                    CookieWebLoginView(onConnected: onSourceChanged)
                } label: {
                    Label("打开 115 登录并自动连接", systemImage: "person.badge.key.fill")
                }
                TextEditor(text: $cookie)
                    .focused($focusedField, equals: .cookie)
                    .frame(minHeight: 90)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await connectCookie() }
                } label: {
                    Label("连接已登录的 115 Cookie", systemImage: "link")
                }
                .disabled(busy || cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Cookie 连接（无需 AppID）")
            } footer: {
                Text("可在应用内登录并自动连接，也可以手动粘贴包含 UID、CID、SEID、KID 的 Cookie。Cookie 可能过期，仅保存在你的服务器；BT 云下载使用下方官方授权。")
            } }

            Section {
                TextField("AppID / Client ID", text: $clientId)
                    .focused($focusedField, equals: .clientId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { focusedField = nil }
                Button(busy ? "处理中…" : "保存应用凭证") {
                    Task { await saveConfiguration() }
                }
                .disabled(busy || clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("应用凭证")
            } footer: {
                Text("填写开放平台批准的 AppID。扫码授权使用 PKCE，无需提供 AppSecret。")
            }

            if !appState.isDirect { Section {
                SecureField("AppSecret", text: $clientSecret)
                    .focused($focusedField, equals: .clientSecret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { focusedField = nil }
                TextField("已登记的 HTTPS 回调地址", text: $redirectURI)
                    .focused($focusedField, equals: .redirectURI)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { focusedField = nil }
                Button {
                    Task { await startWebAuthorization() }
                } label: {
                    Label("打开 115 登录并授权", systemImage: "arrow.up.right.square")
                }
                .disabled(busy || status?.configured != true || clientSecret.isEmpty || redirectURI.isEmpty)
            } header: {
                Text("115 官方登录")
            } footer: {
                Text("需要已获批的 AppSecret，以及在 115 平台登记过的 HTTPS 回调域名。登录后返回 HPlayer；AppSecret 仅用于本次授权。")
            } }

            Section {
                Button(authorization == nil ? "开始 115 授权" : "重新获取授权码") {
                    Task { await startAuthorization() }
                }
                .disabled(busy || status?.configured != true)

                if let authorization {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("使用 115 扫描二维码完成授权；也可复制授权内容在其他设备打开。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        if let image = qrImage(authorization.verificationUri) {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 180, height: 180)
                                .padding(12)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel("115 授权二维码")
                        }
                        if let code = authorization.userCode, !code.isEmpty {
                            HStack {
                                Text(code)
                                    .font(.system(.title2, design: .monospaced).weight(.bold))
                                    .textSelection(.enabled)
                                Spacer()
                                Button {
                                    UIPasteboard.general.string = code
                                    message = "验证码已复制"
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .accessibilityLabel("复制验证码")
                            }
                            .padding(14)
                            .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        }
                        if let url = URL(string: authorization.verificationUri), url.scheme?.lowercased() == "https", url.host != nil {
                            Button {
                                openURL(url)
                            } label: {
                                Label("打开 115 授权页面", systemImage: "arrow.up.right.square")
                            }
                        }
                        Button {
                            UIPasteboard.general.string = authorization.verificationUri
                            message = "授权内容已复制"
                        } label: {
                            Label("复制授权内容", systemImage: "doc.on.doc")
                        }
                        Text("完成授权后返回此页面，连接状态会自动更新。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            } header: {
                Text("扫码授权")
            } footer: {
                Text("无需 AppSecret 或回调域名。授权码有有效期，如果失效可重新获取。")
            }

            if !appState.isDirect { Section {
                Button {
                    Task { await selectOfficialSource() }
                } label: {
                    Label("使用官方授权", systemImage: "checkmark.shield")
                }
                .disabled(busy || status?.authorized != true)
            } footer: {
                Text("授权成功后，切换到官方接口浏览和播放。")
            } }

            if !message.isEmpty {
                Section { Label(message, systemImage: "checkmark.circle").foregroundColor(.green) }
            }
            if !error.isEmpty {
                Section { Label(error, systemImage: "exclamationmark.circle").foregroundColor(.red) }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = nil }
            }
        }
        .navigationTitle("115 官方授权")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let server = appState.serverURL, server.scheme?.lowercased() == "https",
               let callback = URL(string: "/api/115/open/auth/callback", relativeTo: server) {
                redirectURI = callback.absoluteURL.absoluteString
            }
            await loadStatus()
        }
        .onDisappear { pollTask?.cancel() }
        .onChange(of: scenePhase) { phase in
            guard phase == .active, let deadline = webDeadline, let client = appState.client() else { return }
            pollTask?.cancel()
            pollTask = Task { await pollWebAuthorization(client: client, expiresIn: max(0, Int(deadline.timeIntervalSinceNow))) }
        }
    }

    private var statusTitle: String {
        guard let status else { return "正在检查连接" }
        if status.authorized { return status.message == nil ? "已授权" : "已保存授权，暂无法验证" }
        return status.configured ? "等待账号授权" : "等待配置应用凭证"
    }

    private func qrImage(_ value: String) -> UIImage? {
        guard !value.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: image)
    }

    private var statusDetail: String {
        guard let status else { return "请稍候" }
        if status.authorized, let name = status.userName, !name.isEmpty { return name }
        return status.message ?? (status.authorized ? "115 开放平台已连接" : "完成下方步骤以连接 115")
    }

    private func loadStatus() async {
        guard let client = appState.client() else { return }
        do {
            status = try await client.get("/api/115/open/status")
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveConfiguration() async {
        guard let client = appState.client() else { return }
        busy = true
        error = ""
        message = ""
        defer { busy = false }
        do {
            let _: Open115ConfigResponse = try await client.post(
                "/api/115/open/config",
                body: ["clientId": clientId.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
            clientId = ""
            pollTask?.cancel()
            webDeadline = nil
            authorization = nil
            message = "应用凭证已保存，请继续授权账号"
            await loadStatus()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func connectCookie() async {
        guard let client = appState.client() else { return }
        busy = true; error = ""; message = ""
        defer { busy = false }
        do {
            let _: CookieResponse = try await client.post("/api/115/cookie", body: ["cookie": cookie])
            cookie = ""
            focusedField = nil
            onSourceChanged()
        } catch { self.error = error.localizedDescription }
    }

    private func startAuthorization() async {
        guard let client = appState.client() else { return }
        busy = true
        error = ""
        message = ""
        pollTask?.cancel()
        webDeadline = nil
        authorization = nil
        defer { busy = false }
        do {
            let result: Open115Start = try await client.post("/api/115/open/auth/start", body: [:])
            authorization = result
            pollTask = Task { await pollAuthorization(client: client, expiresIn: result.expiresIn) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startWebAuthorization() async {
        guard let client = appState.client() else { return }
        guard appState.serverURL?.scheme?.lowercased() == "https" else {
            error = "网页登录需要通过 HTTPS 连接后端，或使用下方扫码授权。"
            return
        }
        busy = true
        error = ""
        message = ""
        pollTask?.cancel()
        webDeadline = nil
        authorization = nil
        defer { busy = false }
        do {
            let result: Open115WebStart = try await client.post("/api/115/open/auth/web/start", body: [
                "clientSecret": clientSecret,
                "redirectUri": redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
            ])
            clientSecret = ""
            guard let url = URL(string: result.authorizationUrl), url.scheme == "https", url.host == "passportapi.115.com" else {
                throw APIError.badURL
            }
            message = "请在 115 完成登录和授权，然后返回 HPlayer。"
            webDeadline = Date().addingTimeInterval(TimeInterval(result.expiresIn))
            pollTask = Task { await pollWebAuthorization(client: client, expiresIn: result.expiresIn) }
            openURL(url)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func pollWebAuthorization(client: APIClient, expiresIn: Int) async {
        let deadline = Date().addingTimeInterval(TimeInterval(max(0, expiresIn)))
        while !Task.isCancelled && Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                let result: Open115Poll = try await client.get("/api/115/open/auth/web/status")
                guard !Task.isCancelled else { return }
                switch result.status {
                case "authorized":
                    webDeadline = nil
                    message = "115 账号授权成功"
                    await loadStatus()
                    onSourceChanged()
                    return
                case "failed":
                    webDeadline = nil
                    error = "授权未完成，请检查 AppSecret、接口权限和回调域名后重试。"
                    return
                case "expired":
                    webDeadline = nil
                    error = "授权已过期，请重新发起。"
                    return
                default: break
                }
            } catch is CancellationError { return }
            catch {
                self.error = error.localizedDescription
                return
            }
        }
        if !Task.isCancelled { webDeadline = nil; error = "授权已过期，请重新发起。" }
    }

    private func selectOfficialSource() async {
        guard let client = appState.client() else { return }
        busy = true
        error = ""
        message = ""
        defer { busy = false }
        do {
            let _: Open115ConfigResponse = try await client.post("/api/115/open/source", body: ["source": "open"])
            message = "已切换到官方授权"
            onSourceChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func pollAuthorization(client: APIClient, expiresIn: Int) async {
        let deadline = Date().addingTimeInterval(TimeInterval(max(0, expiresIn)))
        while !Task.isCancelled && Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                let result: Open115Poll = try await client.post("/api/115/open/auth/poll", body: [:])
                guard !Task.isCancelled else { return }
                switch result.status {
                case "authorized":
                    authorization = nil
                    message = result.message ?? "115 账号授权成功"
                    await loadStatus()
                    onSourceChanged()
                    return
                case "expired":
                    authorization = nil
                    error = result.message ?? "授权码已失效，请重新获取"
                    return
                case "pending":
                    break
                default:
                    error = result.message ?? "无法确认授权状态，请重新获取授权码"
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
        if !Task.isCancelled {
            authorization = nil
            error = "授权码已失效，请重新获取"
        }
    }
}
