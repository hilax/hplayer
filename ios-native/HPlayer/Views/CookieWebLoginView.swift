import SwiftUI
import WebKit

/// 在独立的网页会话内登录 115，仅把该域名的必要 Cookie 交给自己的后端。
struct CookieWebLoginView: View {
    let onConnected: () -> Void
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var candidate = ""
    @State private var lastAttempt = ""
    @State private var checking = false
    @State private var pageLoading = true
    @State private var error = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("在下方的 115 官方网页登录")
                    .font(.subheadline.weight(.semibold))
                Text("完成登录后会自动连接，无需手动复制 Cookie。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            if checking {
                HStack(spacing: 8) { ProgressView(); Text("正在验证 115 登录状态…").font(.caption) }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            } else if pageLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 6)
            }

            if !error.isEmpty {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Spacer()
                    if !candidate.isEmpty {
                        Button("重试") { Task { await connect(candidate) } }.font(.caption)
                    }
                }.padding(.horizontal).padding(.bottom, 8)
            }

            OfficialLoginWebView(onCookie: received, onLoading: { pageLoading = $0 }, onError: { error = $0 })
        }
        .navigationTitle("登录 115")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { candidate = ""; lastAttempt = "" }
    }

    private func received(_ cookie: String) {
        candidate = cookie
        guard !checking, cookie != lastAttempt else { return }
        Task { await connect(cookie) }
    }

    private func connect(_ cookie: String) async {
        guard !checking, let client = appState.client(), appState.isAuthenticated else {
            error = "请先连接服务器并登录 HPlayer"
            return
        }
        checking = true
        lastAttempt = cookie
        error = ""
        defer { checking = false }
        do {
            let _: CookieResponse = try await client.post("/api/115/cookie", body: ["cookie": cookie])
            candidate = ""
            lastAttempt = ""
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
