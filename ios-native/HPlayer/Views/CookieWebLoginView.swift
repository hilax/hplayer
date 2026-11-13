import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import WebKit

/// 登录 115：默认用 115 App 扫码登录，也可以打开官方网页登录（在独立的网页会话里）。
struct CookieWebLoginView: View {
    var dismissOnConnected = true
    let onConnected: () -> Void
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showingWeb = false
    @State private var candidate = ""
    @State private var lastAttempt = ""
    @State private var checking = false
    @State private var pageLoading = true
    @State private var error = ""
    @State private var connectionTask: Task<Void, Never>?
    @State private var connectionID = UUID()
    @State private var pendingConnected = false

    // 扫码登录
    private enum QRPhase: Equatable {
        case idle, loading, waiting, scanned, connecting
        case ended(String)
    }
    @State private var qrPhase: QRPhase = .idle
    @State private var qrImage: UIImage?
    @State private var qrContent = ""
    @State private var qrTask: Task<Void, Never>?
    @State private var qrRequestID = UUID()
    @State private var qrNotice = ""
    @Environment(\.openURL) private var openURL

    var body: some View {
        DesignPage(eyebrow: "Connect your collection", title: "连接 115 网盘", subtitle: "让云端收藏，成为随时可看的片库。") {
            qrCard.reveal(0)
            VStack(spacing: 12) {
                Text("也可以用 115 官方网页登录").font(.subheadline.weight(.semibold))
                Text("在网页里输入账号密码，登录后自动连接。")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button {
                    error = ""; candidate = ""; lastAttempt = ""; pageLoading = true
                    pendingConnected = false; showingWeb = true
                } label: { Label("打开官方登录页面", systemImage: AppIcon.openExternal.name) }
                    .buttonStyle(SecondaryActionStyle()).accessibilityIdentifier("connect115.openWeb")
            }.frame(maxWidth: .infinity).padding(20).surfaceCard()
            DesignNotice(symbol: AppIcon.privacy.name, text: "登录凭证仅保存在本机钥匙串。退出账号会移除本机凭证，不会删除你的网盘文件。")
            if !error.isEmpty { DesignNotice(symbol: AppIcon.alert.name, text: error, warning: true) }
        }
        .navigationTitle("连接 115 网盘")
        .designScreen("connect115")
        .sheet(isPresented: $showingWeb, onDismiss: finishWebSession) {
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
                            if !candidate.isEmpty { Button("重新验证") { connect(candidate) }.disabled(checking) }
                        }.padding(.horizontal)
                    }
                    OfficialLoginWebView(onCookie: received, onLoading: { pageLoading = $0 }, onError: { error = $0 })
                }
                .navigationTitle("115 官方登录").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showingWeb = false } } }
            }
        }
        .onChange(of: showingWeb) { visible in
            if !visible { cancelConnection() }
        }
        .task { if !InterfacePreview.active, qrPhase == .idle { startQR() } }
        .onDisappear { cancelConnection(); stopQR() }
    }

    // MARK: 扫码登录

    private var qrCard: some View {
        VStack(spacing: 14) {
            Text("用 115 App 扫码登录").font(.headline)
            Text("打开手机上的 115 App，用「扫一扫」扫描下面的二维码，在手机上确认后自动连接。")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Color.white)
                if let qrImage {
                    Image(uiImage: qrImage).interpolation(.none).resizable().scaledToFit()
                        .padding(14)
                        .opacity(qrDimmed ? 0.12 : 1)
                        .accessibilityLabel("115 登录二维码")
                        .accessibilityIdentifier("connect115.qr")
                }
                switch qrPhase {
                case .idle, .loading:
                    ProgressView().tint(.gray)
                case .scanned, .connecting:
                    VStack(spacing: 8) {
                        if qrPhase == .connecting { ProgressView().tint(.gray) }
                        else { Image(systemName: AppIcon.success.name).font(.scaled(38, weight: Theme.iconWeight)) }
                        Text(qrPhase == .connecting ? "正在连接…" : "已扫码").font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Theme.accent)
                case .ended:
                    Button { startQR() } label: {
                        VStack(spacing: 8) {
                            Image(systemName: AppIcon.refresh.name).font(.scaled(30, weight: Theme.iconWeight))
                            Text("刷新二维码").font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("connect115.qrRefresh")
                case .waiting:
                    EmptyView()
                }
            }
            .frame(width: 210, height: 210)
            .overlay { RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5) }

            Text(qrStatusText)
                .font(.subheadline)
                .foregroundStyle(qrFailed ? Theme.warning : Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("connect115.qrStatus")

            // 二维码显示在这台手机上时，可以存到相册，再用 115 App 扫一扫里的「相册」识别
            if qrImage != nil, qrPhase == .waiting || qrPhase == .scanned {
                HStack(spacing: 10) {
                    Button { saveQR() } label: { Label("存到相册", systemImage: AppIcon.download.name) }
                        .buttonStyle(SecondaryActionStyle())
                    if let url = URL(string: qrContent), url.scheme?.hasPrefix("http") == true {
                        Button { openURL(url) } label: { Label("用 115 打开", systemImage: AppIcon.openExternal.name) }
                            .buttonStyle(SecondaryActionStyle())
                    }
                }
                Text(qrNotice.isEmpty ? "二维码就在这台手机上？存到相册后，在 115 App 的扫一扫里从相册选它。" : qrNotice)
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .surfaceCard()
    }

    private var qrDimmed: Bool {
        switch qrPhase {
        case .scanned, .connecting, .ended: return true
        default: return false
        }
    }

    private var qrFailed: Bool {
        if case .ended = qrPhase { return true }
        return false
    }

    private var qrStatusText: String {
        switch qrPhase {
        case .idle, .loading: return "正在生成二维码…"
        case .waiting: return "等待扫码"
        case .scanned: return "已扫码，请在手机上的 115 App 里点「确认登录」"
        case .connecting: return "已确认，正在连接 115…"
        case .ended(let message): return message
        }
    }

    private func startQR() {
        qrTask?.cancel()
        let request = UUID()
        qrRequestID = request
        qrPhase = .loading
        qrImage = nil
        qrContent = ""
        qrNotice = ""
        qrTask = Task { await runQR(request) }
    }

    private func stopQR() {
        qrTask?.cancel()
        qrTask = nil
        qrRequestID = UUID()
        if qrPhase != .idle { qrPhase = .idle }
    }

    private func isCurrentQR(_ request: UUID) -> Bool {
        !Task.isCancelled && qrRequestID == request
    }

    private func runQR(_ request: UUID) async {
        let login = Direct115QRLogin()
        do {
            let ticket = try await login.start()
            guard isCurrentQR(request) else { return }
            qrContent = ticket.content
            qrImage = Self.makeQRImage(ticket.content)
            qrPhase = .waiting
            let started = Date()
            var failures = 0
            while isCurrentQR(request) {
                // 115 的二维码几分钟后失效；服务器没告诉我们时也按过期处理
                if Date().timeIntervalSince(started) > 300 {
                    qrPhase = .ended("二维码已过期，点上面刷新")
                    return
                }
                let status: Direct115QRLogin.Status
                do {
                    status = try await login.status(of: ticket)
                    failures = 0
                } catch {
                    guard isCurrentQR(request) else { return }
                    failures += 1
                    if failures >= 3 { throw error }
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                guard isCurrentQR(request) else { return }
                switch status {
                case .waiting:
                    if qrPhase != .waiting { qrPhase = .waiting }
                case .scanned:
                    if qrPhase != .scanned { qrPhase = .scanned; Haptics.tap() }
                case .expired:
                    qrPhase = .ended("二维码已过期，点上面刷新")
                    return
                case .canceled:
                    qrPhase = .ended("已在手机上取消登录，点上面刷新重新扫码")
                    return
                case .confirmed:
                    qrPhase = .connecting
                    let cookie = try await login.cookie(for: ticket)
                    guard isCurrentQR(request) else { return }
                    try await appState.connectDirect(cookie: cookie)
                    guard isCurrentQR(request) else { return }
                    qrTask = nil
                    onConnected()
                    if dismissOnConnected { dismiss() }
                    return
                }
                // 服务器一般会挂着请求等到有变化才回；万一马上就回了，稍等一下再问，免得请求太密
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } catch {
            guard isCurrentQR(request), !(error is CancellationError) else { return }
            qrPhase = .ended("扫码登录没有成功：\(error.localizedDescription)。点上面刷新再试，或改用网页登录。")
        }
    }

    private func saveQR() {
        guard let qrImage else { return }
        // 四周留白，115 扫一扫从相册识别时更容易认出来
        let side: CGFloat = 720
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: side, height: side))
            let context = UIGraphicsGetCurrentContext()
            context?.interpolationQuality = .none
            qrImage.draw(in: CGRect(x: 60, y: 60, width: side - 120, height: side - 120))
        }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        qrNotice = "已存到相册。打开 115 App 的扫一扫，从相册里选这张二维码。"
    }

    private static func makeQRImage(_ value: String) -> UIImage? {
        guard !value.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: image)
    }

    private func received(_ cookie: String) {
        guard showingWeb else { return }
        candidate = cookie
        guard !checking, cookie != lastAttempt else { return }
        connect(cookie)
    }

    private func connect(_ cookie: String) {
        guard showingWeb, !checking else { return }
        let request = UUID()
        connectionID = request
        checking = true
        lastAttempt = cookie
        error = ""
        connectionTask = Task {
            defer {
                if connectionID == request { checking = false; connectionTask = nil }
            }
            do {
                try await appState.connectDirect(cookie: cookie)
                guard !Task.isCancelled, connectionID == request else { return }
                pendingConnected = true
                showingWeb = false
            } catch {
                guard !Task.isCancelled, connectionID == request, !(error is CancellationError) else { return }
                self.error = "暂时无法验证登录状态，请确认已登录后重试：\(error.localizedDescription)"
            }
        }
    }

    private func cancelConnection() {
        connectionTask?.cancel()
        connectionTask = nil
        connectionID = UUID()
        checking = false
    }

    private func finishWebSession() {
        cancelConnection()
        candidate = ""; lastAttempt = ""
        guard pendingConnected else { return }
        pendingConnected = false
        // 等网页子 sheet 关闭后再切换父级，避免同时关闭两层呈现。
        onConnected()
        if dismissOnConnected { dismiss() }
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
