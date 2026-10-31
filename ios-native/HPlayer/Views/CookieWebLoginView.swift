import SwiftUI
import WebKit

/// 在独立的网页会话内登录 115。
struct CookieWebLoginView: View {
    let onConnected: () -> Void
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showingWeb = false
    @State private var candidate = ""
    @State private var lastAttempt = ""
    @State private var checking = false
    @State private var pageLoading = true
    @State private var error = ""

    var body: some View {
        DesignPage(eyebrow: "Connect your collection", title: "连接 115 网盘", subtitle: "让云端收藏，成为随时可看的片库。") {
            VStack(spacing: 18) {
                Text("115").font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(.white).frame(width: 88, height: 88)
                    .background(Theme.primaryAction, in: RoundedRectangle(cornerRadius: 24))
                Text("使用 115 官方网页登录").font(.headline)
                Text("完成登录后自动验证并连接，无需手动复制 Cookie。")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { error = ""; showingWeb = true } label: { Label("打开官方登录页面", systemImage: "arrow.up.right.square") }
                    .buttonStyle(PrimaryActionStyle()).accessibilityIdentifier("connect115.openWeb")
            }.padding(24).surfaceCard()
            DesignGroup {
                LibraryActionRow(symbol: "folder", title: "浏览网盘文件", subtitle: "按目录查找你的影片")
                Divider().padding(.leading, 62)
                LibraryActionRow(symbol: "play.rectangle", title: "直接播放原文件", subtitle: "播放时读取所需的视频数据")
                Divider().padding(.leading, 62)
                LibraryActionRow(symbol: "rectangle.stack", title: "建立自己的片库", subtitle: "将选中的文件整理到首页")
            }
            DesignNotice(symbol: "lock.shield", text: "登录凭证仅保存在本机钥匙串。退出账号会移除本机凭证，不会删除你的网盘文件。")
            if !error.isEmpty { DesignNotice(symbol: "exclamationmark.circle", text: error, warning: true) }
        }
        .navigationTitle("连接 115")
        .designScreen("connect115")
        .sheet(isPresented: $showingWeb) {
            NavigationStack {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        if checking || pageLoading { ProgressView() }
                        Text(checking ? "正在验证登录状态…" : "完成官方网页登录后，会自动连接。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(12)
                    if !error.isEmpty {
                        VStack(spacing: 8) {
                            Text(error).font(.caption).foregroundStyle(Theme.warning)
                            if !candidate.isEmpty { Button("重新验证") { Task { await connect(candidate) } }.disabled(checking) }
                        }.padding(.horizontal)
                    }
                    OfficialLoginWebView(onCookie: received, onLoading: { pageLoading = $0 }, onError: { error = $0 })
                }
                .navigationTitle("115 官方登录").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showingWeb = false } } }
            }
        }
        .onDisappear { candidate = ""; lastAttempt = "" }
    }

    private func received(_ cookie: String) {
        candidate = cookie
        guard !checking, cookie != lastAttempt else { return }
        Task { await connect(cookie) }
    }

    private func connect(_ cookie: String) async {
        guard !checking else { return }
        checking = true
        lastAttempt = cookie
        error = ""
        defer { checking = false }
        do {
            try await appState.connectDirect(cookie: cookie)
            candidate = ""
            lastAttempt = ""
            showingWeb = false
            onConnected()
            dismiss()
        } catch {
            self.error = "暂时无法验证登录状态，请确认已登录后重试：\(error.localizedDescription)"
        }
    }
}

private struct OfficialLoginWebView: UIViewRepresentable {
    let onCookie: (String) -> Void
    let onLoading: (Bool) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCookie: onCookie, onLoading: onLoading, onError: onError) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        // 115 的移动首页主要引导下载 App；使用其提供登录表单的网页版。
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        configuration.websiteDataStore.httpCookieStore.add(context.coordinator)
        view.load(URLRequest(url: URL(string: "https://115.com/")!))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onCookie = onCookie
        context.coordinator.onLoading = onLoading
        context.coordinator.onError = onError
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.websiteDataStore.httpCookieStore.remove(coordinator)
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        var onCookie: (String) -> Void
        var onLoading: (Bool) -> Void
        var onError: (String) -> Void

        init(onCookie: @escaping (String) -> Void, onLoading: @escaping (Bool) -> Void, onError: @escaping (String) -> Void) {
            self.onCookie = onCookie; self.onLoading = onLoading; self.onError = onError
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { inspect(cookieStore) }

        private func inspect(_ store: WKHTTPCookieStore) {
            store.getAllCookies { [weak self] cookies in
                let names = ["UID", "CID", "SEID", "KID"]
                var values: [String: HTTPCookie] = [:]
                for cookie in cookies {
                    let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    guard (domain == "115.com" || domain.hasSuffix(".115.com")), names.contains(cookie.name),
                          !cookie.value.isEmpty, !cookie.value.contains(";"), !cookie.value.contains("\r"), !cookie.value.contains("\n"),
                          cookie.expiresDate.map({ $0 > Date() }) ?? true else { continue }
                    // Prefer a root-domain cookie if the same name also exists on a subdomain.
                    if values[cookie.name] == nil || domain == "115.com" { values[cookie.name] = cookie }
                }
                guard names.allSatisfy({ values[$0] != nil }) else { return }
                let header = names.compactMap { name in values[name].map { "\(name)=\($0.value)" } }.joined(separator: "; ")
                DispatchQueue.main.async { self?.onCookie(header) }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { onLoading(true) }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoading(false)
            inspect(webView.configuration.websiteDataStore.httpCookieStore)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onLoading(false)
            if (error as NSError).code != NSURLErrorCancelled { onError("无法打开 115 登录页，请检查网络后重试。") }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.targetFrame?.isMainFrame ?? true else { decisionHandler(.allow); return }
            guard let url = navigationAction.request.url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), host == "115.com" || host.hasSuffix(".115.com") else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), host == "115.com" || host.hasSuffix(".115.com") {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}
