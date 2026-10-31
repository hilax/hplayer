import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

struct Open115Status: Decodable {
    let configured: Bool
    let authorized: Bool
    let message: String?
    let userName: String?
}

struct Open115Start: Decodable {
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

struct Official115SettingsView: View {
    private enum Field: Hashable { case clientId }
    @FocusState private var focusedField: Field?
    let onSourceChanged: () -> Void
    @EnvironmentObject private var appState: AppState
    @Environment(\.openURL) private var openURL

    @State private var status: Open115Status?
    @State private var clientId = ""
    @State private var authorization: Open115Start?
    @State private var pollTask: Task<Void, Never>?
    @State private var busy = false
    @State private var message = ""
    @State private var error = ""

    init(onSourceChanged: @escaping () -> Void, initialStatus: Open115Status? = nil, initialAuthorization: Open115Start? = nil) {
        self.onSourceChanged = onSourceChanged
        _status = State(initialValue: initialStatus)
        _authorization = State(initialValue: initialAuthorization)
    }

    var body: some View {
        DesignPage(eyebrow: "Official authorization", title: "115 官方授权", subtitle: "为 BT 云下载连接开放平台能力。") {
            HStack(spacing: 14) {
                Image(systemName: status?.authorized == true ? "checkmark.shield.fill" : "lock.shield")
                    .font(.title).foregroundStyle(Theme.accent)
                    .frame(width: 52, height: 52).background(Theme.tileTint, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 6) {
                    Text(statusTitle).font(.headline)
                    Text(statusDetail).font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18).surfaceCard()
            VStack(alignment: .leading, spacing: 16) {
                Label("1 · 配置应用凭证", systemImage: "key").font(.headline)
                DesignField(label: "AppID / Client ID", placeholder: "输入开放平台批准的 AppID", text: $clientId)
                    .focused($focusedField, equals: .clientId).submitLabel(.done).onSubmit { focusedField = nil }
                Button(busy ? "处理中…" : "保存应用凭证") { Task { await saveConfiguration() } }
                    .buttonStyle(SecondaryActionStyle())
                    .disabled(busy || clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                DesignNotice(text: "填写已获批的 AppID，扫码授权使用 PKCE，无需提供 AppSecret。")
            }.padding(18).surfaceCard()
            VStack(alignment: .leading, spacing: 18) {
                Label("2 · 扫码授权", systemImage: "qrcode.viewfinder").font(.headline)
                if let authorization {
                    if let image = qrImage(authorization.verificationUri) {
                        Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                            .frame(width: 180, height: 180).padding(14)
                            .background(.white, in: RoundedRectangle(cornerRadius: 16))
                            .frame(maxWidth: .infinity).accessibilityLabel("115 授权二维码")
                    }
                    if let code = authorization.userCode, !code.isEmpty {
                        HStack {
                            Text(code).font(.system(.title2, design: .monospaced).bold()).textSelection(.enabled)
                            Spacer()
                            Button { UIPasteboard.general.string = code; message = "验证码已复制" } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("复制验证码")
                        }.padding(14).background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if let url = URL(string: authorization.verificationUri), url.scheme?.lowercased() == "https", url.host != nil {
                        Button { openURL(url) } label: { Label("打开 115 授权页面", systemImage: "arrow.up.right.square") }.buttonStyle(PrimaryActionStyle())
                    }
                    Button { UIPasteboard.general.string = authorization.verificationUri; message = "授权内容已复制" } label: { Label("复制授权内容", systemImage: "doc.on.doc") }.buttonStyle(SecondaryActionStyle())
                    DesignNotice(text: "用 115 扫码完成授权。返回此页面后，连接状态会自动更新。")
                }
                Button(authorization == nil ? "开始 115 授权" : "重新获取授权码") { Task { await startAuthorization() } }
                    .buttonStyle(SecondaryActionStyle()).disabled(busy || status?.configured != true)
            }.padding(18).surfaceCard()
            if !message.isEmpty { DesignNotice(symbol: "checkmark.circle", text: message) }
            if !error.isEmpty { DesignNotice(symbol: "exclamationmark.circle", text: error, warning: true) }
            DesignNotice(symbol: "lock.shield", text: "授权码在有效期内使用。失效后可重新获取，不需要 AppSecret 或回调域名。")
        }
        .navigationTitle("115 官方授权")
        .designScreen("official")
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { focusedField = nil } } }
        .task { if !InterfacePreview.active { await loadStatus() } }
        .onDisappear { pollTask?.cancel() }
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
            authorization = nil
            message = "应用凭证已保存，请继续授权账号"
            await loadStatus()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startAuthorization() async {
        guard let client = appState.client() else { return }
        busy = true
        error = ""
        message = ""
        pollTask?.cancel()
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
