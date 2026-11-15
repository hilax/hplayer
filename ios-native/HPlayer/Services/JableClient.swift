import Foundation
import WebKit
import Combine

enum JableError: LocalizedError {
    case invalidURL
    case noStreamFound
    case timeout
    case challengeCancelled
    case parsingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的 Jable 地址"
        case .noStreamFound: return "未能从页面中提取到播放流地址（.m3u8）"
        case .timeout: return "页面加载超时，请检查网络或完成安全验证"
        case .challengeCancelled: return "已取消安全验证"
        case .parsingFailed(let msg): return "解析页面失败: \(msg)"
        }
    }
}

/// 播放信息：包含 HLS 播放地址与必须携带的请求头（Referer / User-Agent）
struct JablePlayback {
    let url: URL
    let headers: [String: String]
}

@MainActor
final class JableClient: NSObject, ObservableObject {
    static let shared = JableClient()

    static let baseURL = "https://jable.tv"
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    /// 媒体流播放及图片加载所需请求头
    static var mediaHeaders: [String: String] {
        [
            "User-Agent": userAgent,
            "Referer": "\(baseURL)/"
        ]
    }

    private var webView: WKWebView!
    private var isProcessing = false
    private var queue: [QueuedTask] = []
    private var currentTask: QueuedTask?
    private var timeoutTimer: Timer?
    private var challengeCheckTimer: Timer?
    /// 当前这个请求已经在提取页面内容了：轮询和页面加载完的回调不会再提取第二次
    private var extracting = false
    /// 正在显示的安全验证页（由 JableClient 自己弹，盖在最上层，播放器窗口里也看得见）
    private var challengeController: UIViewController?
    /// 这个请求第一次看到验证页的时间：先在后台等 CloudflareChallenge.silentWait，让能自动放行的验证自己过
    private var challengeSeenAt: Date?
    /// 详情（含播放地址）短时间缓存：详情页刚解析过，点播放时不用再加载一遍网页
    private var detailCache: [String: (detail: JableVideoDetail, at: Date)] = [:]
    private static let detailCacheLifetime: TimeInterval = 10 * 60

    private struct QueuedTask {
        let id: UUID
        let url: URL
        let extractorJS: String
        let continuation: CheckedContinuation<String, Error>
    }

    override init() {
        super.init()
        setupWebView()
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.websiteDataStore = WKWebsiteDataStore.default()

        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 667), configuration: config)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self
    }

    // MARK: - 业务接口

    /// 获取分类列表
    func list(category: JableCategory, page: Int = 1) async throws -> [JableVideoCard] {
        let path: String
        if page <= 1 {
            path = "\(category.path)/"
        } else {
            path = "\(category.path)/\(page)/"
        }
        guard let url = URL(string: "\(Self.baseURL)/\(path)") else { throw JableError.invalidURL }
        let json = try await execute(url: url, extractorJS: Self.listExtractorScript)
        return try Self.parseVideoCards(json: json)
    }

    /// 搜索视频
    func search(query: String, page: Int = 1) async throws -> [JableVideoCard] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        let path: String
        if page <= 1 {
            path = "search/\(encoded)/"
        } else {
            path = "search/\(encoded)/\(page)/"
        }
        guard let url = URL(string: "\(Self.baseURL)/\(path)") else { throw JableError.invalidURL }
        let json = try await execute(url: url, extractorJS: Self.listExtractorScript)
        return try Self.parseVideoCards(json: json)
    }

    /// 获取视频详情
    func detail(videoId: String, pageUrl: String? = nil, useCache: Bool = true) async throws -> JableVideoDetail {
        if useCache, let cached = detailCache[videoId],
           Date().timeIntervalSince(cached.at) < Self.detailCacheLifetime {
            return cached.detail
        }
        let targetString: String
        if let pageUrl, !pageUrl.isEmpty {
            targetString = pageUrl
        } else {
            targetString = "\(Self.baseURL)/videos/\(videoId)/"
        }
        guard let url = URL(string: targetString) else { throw JableError.invalidURL }
        let json = try await execute(url: url, extractorJS: Self.detailExtractorScript)
        let detail = try Self.parseVideoDetail(json: json, fallbackId: videoId)
        if !detail.hlsUrl.isEmpty { detailCache[videoId] = (detail, Date()) }
        return detail
    }

    /// 解析视频播放信息：详情页刚取过就直接用缓存里的地址
    func resolvePlayback(videoId: String) async throws -> JablePlayback {
        var detail = try await self.detail(videoId: videoId)
        if detail.hlsUrl.isEmpty { detail = try await self.detail(videoId: videoId, useCache: false) }
        guard let streamURL = URL(string: detail.hlsUrl), !detail.hlsUrl.isEmpty else {
            throw JableError.noStreamFound
        }
        return JablePlayback(url: streamURL, headers: Self.mediaHeaders)
    }

    // MARK: - 内部请求调度

    /// 排队用同一个后台网页加载。调用方被取消时（离开页面、换分类），还在排队的请求直接取消，
    /// 不再占着队列让后面的请求干等；正在加载的那一个让它加载完（详情会进缓存）。
    private func execute(url: URL, extractorJS: String) async throws -> String {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                queue.append(QueuedTask(id: id, url: url, extractorJS: extractorJS, continuation: continuation))
                processNextTaskIfNeeded()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelQueued(id) }
        }
    }

    private func cancelQueued(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func processNextTaskIfNeeded() {
        guard !isProcessing, !queue.isEmpty else { return }
        isProcessing = true
        extracting = false
        challengeSeenAt = nil
        let task = queue.removeFirst()
        currentTask = task
        armTimeout(for: task.id)

        var request = URLRequest(url: task.url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 25)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        webView.load(request)
    }

    /// 30 秒没结果算超时；显示安全验证期间不计时（等用户自己点），验证页关掉后重新计时
    private func armTimeout(for id: UUID) {
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentTask?.id == id, self.challengeController == nil else { return }
                self.complete(id, with: .failure(JableError.timeout))
            }
        }
    }

    /// 结束一个请求。只认当前这个请求的 id：上一个请求迟到的回调（超时后页面才加载完、
    /// 轮询和加载完回调同时提取）不会把结果交给下一个请求，同一个请求也不会被结束两次。
    private func complete(_ id: UUID, with result: Result<String, Error>) {
        guard let task = currentTask, task.id == id else { return }
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        challengeCheckTimer?.invalidate()
        challengeCheckTimer = nil
        dismissChallenge()

        currentTask = nil
        isProcessing = false
        extracting = false
        challengeSeenAt = nil

        task.continuation.resume(with: result)
        processNextTaskIfNeeded()
    }

    /// 看看现在这页是安全验证还是正文。`afterLoad`：页面刚加载完（didFinish）时直接提取；
    /// 轮询调用时要等页面不在加载中，免得在半加载的页面上提取
    private func inspectAndHandlePage(afterLoad: Bool = false) {
        guard let task = currentTask, !extracting else { return }
        let id = task.id
        let checkScript = CloudflareChallenge.detectionScript
        webView.evaluateJavaScript(checkScript) { [weak self] result, _ in
            guard let self, self.currentTask?.id == id, !self.extracting else { return }
            if (result as? Bool) ?? false {
                self.presentChallenge(for: id)
                return
            }
            // 验证通过后页面会跳转：等新页面加载完（didFinish 会再来一次）再提取，
            // 不在半加载的页面上提取出空列表、找不到播放地址
            guard afterLoad || !self.webView.isLoading else { return }
            self.challengeCheckTimer?.invalidate()
            self.challengeCheckTimer = nil
            self.dismissChallenge()
            self.extracting = true
            self.webView.evaluateJavaScript(task.extractorJS) { [weak self] res, err in
                guard let self, self.currentTask?.id == id else { return }
                if let err {
                    self.complete(id, with: .failure(JableError.parsingFailed(err.localizedDescription)))
                } else if let jsonString = res as? String {
                    self.complete(id, with: .success(jsonString))
                } else {
                    self.complete(id, with: .failure(JableError.parsingFailed("页面未返回提取结果")))
                }
            }
        }
    }

    private func startChallengePolling() {
        guard challengeCheckTimer == nil else { return }
        challengeCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentTask != nil, !self.webView.isLoading else { return }
                self.inspectAndHandlePage()
            }
        }
    }

    // MARK: - 安全验证页

    /// 由 JableClient 自己弹在当前最上层的页面上（播放器窗口在前台时就弹在播放器上），
    /// 不靠各个页面各绑一个 sheet：以前首页频道和详情页会抢着弹，播放器里解析时弹在播放器下面看不见，
    /// 而验证期间不计超时，会一直卡在「正在解析」。下拉关掉验证页等同于取消。
    private func presentChallenge(for id: UUID) {
        startChallengePolling()
        guard challengeController == nil else { return }
        // 先不弹：轮询会继续检查，过了静默等待还在验证页才弹出来让用户点
        let seen = challengeSeenAt ?? Date()
        challengeSeenAt = seen
        guard Date().timeIntervalSince(seen) >= CloudflareChallenge.silentWait else { return }
        guard let presenter = Self.topViewController() else {
            complete(id, with: .failure(JableError.challengeCancelled))
            return
        }
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        let page = JableChallengeViewController(webView: webView) { [weak self] in
            self?.cancelChallenge(id)
        }
        let navigation = UINavigationController(rootViewController: page)
        navigation.presentationController?.delegate = page
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        challengeController = navigation
        presenter.present(navigation, animated: true)
    }

    private func dismissChallenge() {
        guard let controller = challengeController else { return }
        challengeController = nil
        if controller.presentingViewController != nil { controller.dismiss(animated: true) }
    }

    /// 用户点「取消」或下拉关掉了验证页
    private func cancelChallenge(_ id: UUID) {
        challengeController = nil
        complete(id, with: .failure(JableError.challengeCancelled))
    }

    private static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .filter { !$0.isHidden && $0.rootViewController != nil }
        let window = windows.first(where: \.isKeyWindow) ?? windows.max { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }

    // MARK: - JSON 解析

    private struct RawCard: Decodable {
        let id: String
        let title: String
        let url: String
        let coverUrl: String
        let duration: String?
        let views: String?
    }

    private struct RawDetail: Decodable {
        let hlsUrl: String?
        let title: String?
        let coverUrl: String?
        let models: [String]?
        let tags: [String]?
        let related: [RawCard]?
    }

    nonisolated static func parseVideoCards(json: String) throws -> [JableVideoCard] {
        guard let data = json.data(using: .utf8) else { throw JableError.parsingFailed("JSON 数据格式不正确") }
        let rawCards = try JSONDecoder().decode([RawCard].self, from: data)
        return rawCards.compactMap { raw in
            guard !raw.id.isEmpty, !raw.title.isEmpty else { return nil }
            return JableVideoCard(
                id: raw.id,
                title: raw.title,
                url: raw.url,
                coverUrl: raw.coverUrl,
                duration: raw.duration ?? "",
                views: raw.views ?? ""
            )
        }
    }

    nonisolated static func parseVideoDetail(json: String, fallbackId: String) throws -> JableVideoDetail {
        guard let data = json.data(using: .utf8) else { throw JableError.parsingFailed("JSON 数据格式不正确") }
        let raw = try JSONDecoder().decode(RawDetail.self, from: data)
        let relatedCards = (raw.related ?? []).compactMap { r -> JableVideoCard? in
            guard !r.id.isEmpty, !r.title.isEmpty else { return nil }
            return JableVideoCard(id: r.id, title: r.title, url: r.url, coverUrl: r.coverUrl, duration: r.duration ?? "", views: r.views ?? "")
        }
        return JableVideoDetail(
            id: fallbackId,
            title: raw.title ?? "",
            coverUrl: raw.coverUrl ?? "",
            hlsUrl: raw.hlsUrl ?? "",
            models: raw.models ?? [],
            tags: raw.tags ?? [],
            related: relatedCards
        )
    }

    // MARK: - 网页提取 JS 脚本

    static let listExtractorScript = """
    (() => {
        const list = [];
        const items = document.querySelectorAll('.video-img-box');
        for (let i = 0; i < items.length; i++) {
            const item = items[i];
            const a = item.querySelector('a[href*="/videos/"]');
            if (!a) continue;
            const href = a.href || '';
            const m = href.match(/\\/videos\\/([^\\/]+)\\/?/);
            const id = m ? m[1] : '';
            if (!id) continue;

            const img = item.querySelector('img');
            let cover = '';
            if (img) {
                cover = img.getAttribute('data-src') || img.src || '';
            }

            const titleEl = item.querySelector('.title, h6');
            const title = titleEl ? titleEl.textContent.trim() : (img ? img.alt || '' : '');

            const durationEl = item.querySelector('.label, .duration');
            const duration = durationEl ? durationEl.textContent.trim() : '';

            // sub-title 里是「眼睛图标 播放数 爱心图标 收藏数」，只取播放数
            const subEl = item.querySelector('.sub-title');
            const viewCount = subEl ? (subEl.textContent.trim().split(/\\s+/)[0] || '') : '';
            const views = /^[0-9.,KkMm万]+$/.test(viewCount) ? viewCount + ' 次观看' : '';

            if (title && id) {
                list.push({
                    id: id,
                    title: title,
                    url: href,
                    coverUrl: cover,
                    duration: duration,
                    views: views
                });
            }
        }
        return JSON.stringify(list);
    })()
    """

    static let detailExtractorScript = """
    (() => {
        // 页面里的 `var hlsUrl = '…'` 会成为全局变量，先直接读它，不受脚本写法变化影响
        let hls = (typeof window.hlsUrl === 'string') ? window.hlsUrl : '';
        const scripts = document.getElementsByTagName('script');
        for (let i = 0; i < scripts.length && !hls; i++) {
            const text = scripts[i].textContent || '';
            const match = text.match(/var\\s+hlsUrl\\s*=\\s*['"]([^'"]+)['"]/);
            if (match && match[1]) {
                hls = match[1];
                break;
            }
        }
        if (!hls) {
            for (let i = 0; i < scripts.length; i++) {
                const text = scripts[i].textContent || '';
                const match = text.match(/https?:\\/\\/[^\\s"'<>]+\\.m3u8[^\\s"'<>]*/);
                if (match && match[0]) {
                    hls = match[0];
                    break;
                }
            }
        }

        const ogTitle = document.querySelector('meta[property="og:title"]')?.content;
        const h4 = document.querySelector('h4')?.textContent?.trim();
        const title = ogTitle || h4 || document.title || '';

        const ogImage = document.querySelector('meta[property="og:image"]')?.content || '';

        const modelEls = document.querySelectorAll('.models-list a, .header-info a[href*="/models/"], .header-left a[href*="/models/"]');
        const models = Array.from(modelEls).map(el => el.textContent.trim()).filter(Boolean);

        const tagEls = document.querySelectorAll('.tags-list a, .header-info a[href*="/tags/"], .header-left a[href*="/tags/"]');
        const tags = Array.from(tagEls).map(el => el.textContent.trim()).filter(Boolean);

        const related = [];
        const relatedItems = document.querySelectorAll('.video-img-box');
        for (let i = 0; i < relatedItems.length; i++) {
            const item = relatedItems[i];
            const a = item.querySelector('a[href*="/videos/"]');
            if (!a) continue;
            const href = a.href || '';
            const m = href.match(/\\/videos\\/([^\\/]+)\\/?/);
            const id = m ? m[1] : '';
            if (!id) continue;

            const img = item.querySelector('img');
            const cover = img ? (img.getAttribute('data-src') || img.src || '') : '';
            const tEl = item.querySelector('.title, h6');
            const t = tEl ? tEl.textContent.trim() : '';
            const dEl = item.querySelector('.label, .duration');
            const d = dEl ? dEl.textContent.trim() : '';
            const vEl = item.querySelector('.sub-title');
            const vCount = vEl ? (vEl.textContent.trim().split(/\\s+/)[0] || '') : '';
            const v = /^[0-9.,KkMm万]+$/.test(vCount) ? vCount + ' 次观看' : '';

            if (t && id) {
                related.push({
                    id: id,
                    title: t,
                    url: href,
                    coverUrl: cover,
                    duration: d,
                    views: v
                });
            }
        }

        return JSON.stringify({
            hlsUrl: hls,
            title: title,
            coverUrl: ogImage,
            models: models,
            tags: tags,
            related: related
        });
    })()
    """
}

// MARK: - WKNavigationDelegate

extension JableClient: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.inspectAndHandlePage(afterLoad: true)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.navigationFailed(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.navigationFailed(error) }
    }

    private func navigationFailed(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        // 用户在验证页里操作时页面出错：留着验证页让他刷新重试，不直接判失败
        guard let id = currentTask?.id, challengeController == nil else { return }
        complete(id, with: .failure(error))
    }
}

// MARK: - 安全验证页（UIKit）

/// 显示后台那张网页，让用户自己完成 Cloudflare 验证。验证通过、页面跳转后由 JableClient 关掉。
final class JableChallengeViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    private let webView: WKWebView
    private let onCancel: () -> Void

    init(webView: WKWebView, onCancel: @escaping () -> Void) {
        self.webView = webView
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "安全验证"
        view.backgroundColor = .systemBackground
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
            self?.onCancel()
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .refresh, primaryAction: UIAction { [weak self] _ in
            self?.webView.reload()
        })
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 网页还要留给后台继续加载用：从验证页上拿下来，恢复成后台时的大小
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = CGRect(x: 0, y: 0, width: 375, height: 667)
    }

    /// 下拉关掉验证页 = 取消
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        onCancel()
    }
}
