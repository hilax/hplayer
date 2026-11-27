import Foundation
import WebKit
import Combine

enum MissAVError: LocalizedError {
    case invalidURL
    case noStreamFound
    case timeout
    case challengeCancelled
    case serverError(Int)
    case network(Error)
    case parsingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的 MissAV 地址"
        case .noStreamFound: return "未能从页面中提取到播放流地址（.m3u8）"
        case .timeout: return "页面加载超时，请检查网络或完成安全验证"
        case .challengeCancelled: return "已取消安全验证"
        case .serverError(let status): return "MissAV 服务器响应异常（\(status)）"
        case .network(let err): return "网络请求失败：\(err.userMessage)"
        case .parsingFailed(let msg): return "解析页面失败：\(NetworkErrorFormatter.localizeRawMessage(msg))"
        }
    }
}

/// 播放信息：包含 HLS 播放地址与必须携带的请求头（Referer / User-Agent）
struct MissAVPlayback {
    let url: URL
    let headers: [String: String]
}

@MainActor
final class MissAVClient: NSObject, ObservableObject {
    static let shared = MissAVClient()

    static let baseURL = "https://missav.ws"
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    /// 媒体流播放及图片加载所需请求头
    static var mediaHeaders: [String: String] {
        [
            "User-Agent": userAgent,
            "Referer": "\(baseURL)/"
        ]
    }

    private var webView: WKWebView!
    private let session: URLSession
    private let websiteDataStore: WKWebsiteDataStore
    private var requestTask: Task<Void, Never>?
    private var loadingWebPage = false
    private var isProcessing = false
    private var queue: [QueuedTask] = []
    private var currentTask: QueuedTask?
    private var timeoutTimer: Timer?
    private var challengeCheckTimer: Timer?
    /// 当前这个请求已经在提取页面内容了：轮询和页面加载完的回调不会再提取第二次
    private var extracting = false
    /// 正在显示的安全验证页（盖在当前最上层页面）
    private var challengeController: UIViewController?
    /// 这个请求第一次看到验证页的时间：先在后台等 CloudflareChallenge.silentWait，让能自动放行的验证自己过
    private var challengeSeenAt: Date?
    /// 当前请求开始加载的时间：导航开始得比它早的页面是上一个请求的，不拿它的数据
    private var currentStartedAt = Date()
    /// 详情短时间缓存：详情页刚解析过，点播放时不用再重新加载一遍网页
    private var detailCache: [String: (detail: MissAVVideoDetail, at: Date)] = [:]
    private static let detailCacheLifetime: TimeInterval = 10 * 60

    private struct QueuedTask {
        let id: UUID
        let url: URL
        let extractorJS: String
        let continuation: CheckedContinuation<String, Error>
    }

    init(session: URLSession? = nil, websiteDataStore: WKWebsiteDataStore? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 25
            self.session = URLSession(configuration: configuration)
        }
        self.websiteDataStore = websiteDataStore ?? .default()
        super.init()
        setupWebView()
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.websiteDataStore = websiteDataStore
        // 页面骨架就绪就提取、不下载图片视频字体（见 BackgroundWebPage）
        config.userContentController.addUserScript(BackgroundWebPage.domReadyScript)
        config.userContentController.add(self, name: BackgroundWebPage.domReadyHandler)
        BackgroundWebPage.installResourceBlocking(on: config.userContentController)

        // 注入网络监听脚本，在页面网络请求 m3u8 时直接捕获
        let interceptorScript = WKUserScript(source: """
        (function() {
            window.__missavM3U8 = '';
            const origFetch = window.fetch;
            if (origFetch) {
                window.fetch = function(...args) {
                    const u = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url ? args[0].url : '');
                    if (u && (u.includes('.m3u8') || u.includes('surrit.com'))) {
                        window.__missavM3U8 = u;
                    }
                    return origFetch.apply(this, args);
                };
            }
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(interceptorScript)

        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 667), configuration: config)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self
    }

    // MARK: - 业务接口

    /// 获取分类列表
    func list(category: MissAVCategory, page: Int = 1) async throws -> [MissAVVideoCard] {
        let urlString: String
        if page <= 1 {
            urlString = "\(Self.baseURL)/\(category.path)"
        } else {
            urlString = "\(Self.baseURL)/\(category.path)?page=\(page)"
        }
        guard let url = URL(string: urlString) else { throw MissAVError.invalidURL }
        let json = try await execute(url: url, extractorJS: Self.listExtractorScript)
        return try Self.parseVideoCards(json: json)
    }

    /// 搜索视频
    func search(query: String, page: Int = 1) async throws -> [MissAVVideoCard] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        let urlString: String
        if page <= 1 {
            urlString = "\(Self.baseURL)/search/\(encoded)"
        } else {
            urlString = "\(Self.baseURL)/search/\(encoded)?page=\(page)"
        }
        guard let url = URL(string: urlString) else { throw MissAVError.invalidURL }
        let json = try await execute(url: url, extractorJS: Self.listExtractorScript)
        return try Self.parseVideoCards(json: json)
    }

    /// 获取视频详情
    func detail(videoId: String, pageUrl: String? = nil, useCache: Bool = true) async throws -> MissAVVideoDetail {
        if useCache, let cached = detailCache[videoId],
           Date().timeIntervalSince(cached.at) < Self.detailCacheLifetime {
            return cached.detail
        }
        let targetString: String
        if let pageUrl, !pageUrl.isEmpty {
            targetString = pageUrl
        } else {
            targetString = "\(Self.baseURL)/\(videoId)"
        }
        guard let url = URL(string: targetString) else { throw MissAVError.invalidURL }
        let json = try await execute(url: url, extractorJS: Self.detailExtractorScript)
        let detail = try Self.parseVideoDetail(json: json, fallbackId: videoId)
        if !detail.hlsUrl.isEmpty { detailCache[videoId] = (detail, Date()) }
        return detail
    }

    /// 解析视频播放信息：若详情页刚取过，直接使用缓存地址
    func resolvePlayback(videoId: String) async throws -> MissAVPlayback {
        let detail = try await self.detail(videoId: videoId)
        guard let streamURL = URL(string: detail.hlsUrl), !detail.hlsUrl.isEmpty else {
            throw MissAVError.noStreamFound
        }
        return MissAVPlayback(url: streamURL, headers: Self.mediaHeaders)
    }

    // MARK: - 内部请求调度

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
        if currentTask?.id == id {
            complete(id, with: .failure(CancellationError()))
            return
        }
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
        requestTask = Task { [weak self] in
            await self?.fetchPage(for: task)
        }
    }

    /// 和 JavBus 一样先用普通网络会话取 HTML，不执行站点的广告、跳转及额外验证脚本。
    /// 真正被拦截或播放地址需要网页脚本生成时，才回到浏览器处理。
    private func fetchPage(for task: QueuedTask) async {
        do {
            let browserCookies: [HTTPCookie] = await withCheckedContinuation { continuation in
                websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
            }
            guard currentTask?.id == task.id, !Task.isCancelled else { return }
            let storage = session.configuration.httpCookieStorage
            let cookies = Self.cookies(browserCookies, matching: task.url)
            cookies.forEach { storage?.setCookie($0) }

            var request = pageRequest(for: task.url)
            if storage == nil {
                for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                    request.setValue(value, forHTTPHeaderField: name)
                }
            }
            let (data, response) = try await session.data(for: request)
            guard currentTask?.id == task.id, !Task.isCancelled else { return }
            let finalURL = response.url ?? task.url
            await copySessionCookiesToBrowser(for: finalURL)
            guard currentTask?.id == task.id, !Task.isCancelled else { return }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            if status == 403 || status == 503 {
                loadWebPage(for: task)
                return
            }
            guard (200...299).contains(status) else { throw MissAVError.serverError(status) }

            // DOMParser 的文档不运行页面脚本；仍复用现有提取器和 Packer 解包逻辑。
            let result = try await webView.callAsyncJavaScript(
                Self.htmlExtractionScript(extractorJS: task.extractorJS),
                arguments: ["html": String(decoding: data, as: UTF8.self), "baseURL": finalURL.absoluteString],
                in: nil, contentWorld: .defaultClient
            ) as? [String: Any]
            guard currentTask?.id == task.id, !Task.isCancelled else { return }
            guard result?["challenge"] as? Bool != true,
                  let json = result?["json"] as? String,
                  Self.hasUsableExtraction(json, extractorJS: task.extractorJS) else {
                loadWebPage(for: task)
                return
            }
            complete(task.id, with: .success(json))
        } catch {
            guard currentTask?.id == task.id else { return }
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                complete(task.id, with: .failure(CancellationError()))
            } else if error is WKError {
                loadWebPage(for: task)
            } else if error is MissAVError {
                complete(task.id, with: .failure(error))
            } else {
                complete(task.id, with: .failure(MissAVError.network(error)))
            }
        }
    }

    private func pageRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 25)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.baseURL + "/", forHTTPHeaderField: "Referer")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh-Hans;q=0.9,ja;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        return request
    }

    static func cookies(_ cookies: [HTTPCookie], matching url: URL) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        return cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let path = url.path.isEmpty ? "/" : url.path
            let matchesPath = path == cookie.path || (path.hasPrefix(cookie.path) &&
                (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/")))
            return (host == domain || (cookie.domain.hasPrefix(".") && host.hasSuffix("." + domain))) &&
                matchesPath && (!cookie.isSecure || url.scheme?.lowercased() == "https") &&
                (cookie.expiresDate.map { $0 > Date() } ?? true)
        }
    }

    private func copySessionCookiesToBrowser(for url: URL) async {
        for cookie in session.configuration.httpCookieStorage?.cookies(for: url) ?? [] {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                websiteDataStore.httpCookieStore.setCookie(cookie) { continuation.resume() }
            }
        }
    }

    private func loadWebPage(for task: QueuedTask) {
        guard currentTask?.id == task.id else { return }
        loadingWebPage = true
        armTimeout(for: task.id)
        currentStartedAt = Date()
        webView.load(pageRequest(for: task.url))
    }

    private func armTimeout(for id: UUID) {
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentTask?.id == id, self.challengeController == nil else { return }
                self.complete(id, with: .failure(MissAVError.timeout))
            }
        }
    }

    private func complete(_ id: UUID, with result: Result<String, Error>) {
        guard let task = currentTask, task.id == id else { return }
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        challengeCheckTimer?.invalidate()
        challengeCheckTimer = nil
        requestTask?.cancel()
        requestTask = nil
        loadingWebPage = false
        webView.stopLoading()
        currentTask = nil
        extracting = false
        challengeSeenAt = nil

        task.continuation.resume(with: result)
        dismissChallenge { [weak self] in
            guard let self else { return }
            self.isProcessing = false
            self.processNextTaskIfNeeded()
        }
    }

    private func inspectAndHandlePage(afterLoad: Bool = false) {
        guard loadingWebPage, let task = currentTask, !extracting else { return }
        let id = task.id
        let startedAt = currentStartedAt
        webView.evaluateJavaScript(Self.pageStateScript) { [weak self] result, _ in
            guard let self, self.currentTask?.id == id, !self.extracting else { return }
            // 现在页面骨架一就绪就提取，上一个请求的页面回调可能晚到：导航比这次请求还早的不处理
            guard BackgroundWebPage.isCurrentPage(result, startedAt: startedAt) else { return }
            if BackgroundWebPage.isChallenge(result) {
                self.presentChallenge(for: id)
                return
            }

            guard afterLoad || !self.webView.isLoading else { return }
            self.challengeCheckTimer?.invalidate()
            self.challengeCheckTimer = nil
            self.extracting = true
            self.webView.evaluateJavaScript(task.extractorJS) { [weak self] res, err in
                guard let self, self.currentTask?.id == id else { return }
                if let err {
                    self.complete(id, with: .failure(MissAVError.parsingFailed(err.userMessage)))
                } else if let jsonString = res as? String {
                    self.complete(id, with: .success(jsonString))
                } else {
                    self.complete(id, with: .failure(MissAVError.parsingFailed("页面未返回提取结果")))
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

    private func presentChallenge(for id: UUID) {
        startChallengePolling()
        guard challengeController == nil else { return }
        // 先不弹：轮询会继续检查，过了静默等待还在验证页才弹出来让用户点
        let seen = challengeSeenAt ?? Date()
        challengeSeenAt = seen
        guard Date().timeIntervalSince(seen) >= CloudflareChallenge.silentWait else { return }
        guard let presenter = Self.topViewController() else {
            complete(id, with: .failure(MissAVError.challengeCancelled))
            return
        }
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        let page = MissAVChallengeViewController(webView: webView) { [weak self] in
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

    private func dismissChallenge(completion: @escaping () -> Void) {
        guard let controller = challengeController else { completion(); return }
        challengeController = nil
        if controller.presentingViewController != nil {
            controller.dismiss(animated: true, completion: completion)
        } else {
            completion()
        }
    }

    private func cancelChallenge(_ id: UUID) {
        guard currentTask?.id == id else { return }
        // 首页会同时排队取多个分类；取消一次验证后，不让后面的请求逐个再弹同一个框。
        let pending = queue
        queue.removeAll()
        complete(id, with: .failure(MissAVError.challengeCancelled))
        pending.forEach { $0.continuation.resume(throwing: MissAVError.challengeCancelled) }
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

    nonisolated static func parseVideoCards(json: String) throws -> [MissAVVideoCard] {
        guard let data = json.data(using: .utf8) else { throw MissAVError.parsingFailed("JSON 数据格式不正确") }
        let rawCards = try JSONDecoder().decode([RawCard].self, from: data)
        return rawCards.compactMap { raw in
            guard !raw.id.isEmpty, !raw.title.isEmpty else { return nil }
            return MissAVVideoCard(
                id: raw.id,
                title: raw.title,
                url: raw.url,
                coverUrl: raw.coverUrl,
                duration: raw.duration ?? "",
                views: raw.views ?? ""
            )
        }
    }

    nonisolated static func parseVideoDetail(json: String, fallbackId: String) throws -> MissAVVideoDetail {
        guard let data = json.data(using: .utf8) else { throw MissAVError.parsingFailed("JSON 数据格式不正确") }
        let raw = try JSONDecoder().decode(RawDetail.self, from: data)
        let relatedCards = (raw.related ?? []).compactMap { r -> MissAVVideoCard? in
            guard !r.id.isEmpty, !r.title.isEmpty else { return nil }
            return MissAVVideoCard(id: r.id, title: r.title, url: r.url, coverUrl: r.coverUrl, duration: r.duration ?? "", views: r.views ?? "")
        }
        return MissAVVideoDetail(
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

    /// 正常内容页也可能带 Turnstile 小组件，不能因此打断已经能读取的列表或视频。
    static let challengeDetectionScript = """
    (() => {
        if (document.querySelector('div.thumbnail, video, .plyr, #player')) return false;
        return \(CloudflareChallenge.detectionScript);
    })()
    """

    private static let pageStateScript = "(() => ({ challenge: \(challengeDetectionScript), origin: performance.timeOrigin }))()"

    static func htmlExtractionScript(extractorJS: String) -> String {
        """
        const document = new DOMParser().parseFromString(html, 'text/html');
        const window = {};
        document.querySelectorAll('base').forEach(base => base.remove());
        const base = document.createElement('base');
        base.href = baseURL;
        document.head.prepend(base);
        if (\(challengeDetectionScript)) return { challenge: true };
        return { challenge: false, json: \(extractorJS) };
        """
    }

    private static func hasUsableExtraction(_ json: String, extractorJS: String) -> Bool {
        if extractorJS == detailExtractorScript {
            return (try? parseVideoDetail(json: json, fallbackId: "").hlsUrl.isEmpty) == false
        }
        return (try? parseVideoCards(json: json)) != nil
    }

    static let listExtractorScript = """
    (() => {
        const list = [];
        const seen = new Set();
        // 只认视频卡片（div.thumbnail）。以前还匹配 `.grid > div`，会把页脚「联系我们」这类链接当成视频
        const cards = document.querySelectorAll('div.thumbnail');
        const reserved = new Set(['genres', 'actresses', 'makers', 'tags', 'login', 'register', 'vip', 'search', 'dm', 'new', 'release', 'today-hot', 'weekly-hot', 'monthly-hot', 'chinese-subtitle', 'uncensored-leak']);

        for (let i = 0; i < cards.length; i++) {
            const card = cards[i];
            const links = card.querySelectorAll('a[href]');
            let videoHref = '';
            let videoId = '';

            for (let j = 0; j < links.length; j++) {
                const h = links[j].href || '';
                const clean = h.replace(/\\/$/, '');
                const parts = clean.split('/');
                const last = parts[parts.length - 1] || '';
                // 番号形如 pppe-454、fc2-ppv-1234567、xxx-123-uncensored-leak：带连字符和数字
                if (last && /-/.test(last) && /\\d/.test(last) && !reserved.has(last.toLowerCase()) && !h.includes('/genres/') && !h.includes('/actresses/') && !h.includes('/makers/')) {
                    videoHref = clean;
                    videoId = last;
                    break;
                }
            }
            if (!videoId || seen.has(videoId)) continue;
            seen.add(videoId);

            const img = card.querySelector('img');
            let cover = '';
            if (img) {
                cover = img.getAttribute('data-src') || img.getAttribute('data-original') || img.src || '';
            }

            const titleEl = card.querySelector('a.text-secondary, a[class*="text-secondary"], .my-2 a, a.font-medium, h4, h5, h6') || card.querySelector('a');
            const title = titleEl ? titleEl.textContent.trim() : (img ? img.alt || '' : videoId.toUpperCase());

            const durationEl = card.querySelector('span[class*="duration"], span.absolute, span[class*="bottom-"], .duration');
            const duration = durationEl ? durationEl.textContent.trim() : '';

            if (title && videoId) {
                list.push({
                    id: videoId,
                    title: title,
                    url: videoHref,
                    coverUrl: cover,
                    duration: duration,
                    views: ""
                });
            }
        }
        return JSON.stringify(list);
    })()
    """

    static let detailExtractorScript = """
    (() => {
        let hls = window.__missavM3U8 || '';

        // 1. 检查 video 元素
        if (!hls) {
            const vid = document.querySelector('video source, video');
            if (vid && vid.src && (vid.src.includes('.m3u8') || vid.src.includes('surrit.com'))) {
                hls = vid.src;
            }
        }

        // 2. 解包 Dean Edwards Packer 脚本
        function unpackDean(text) {
            const m = text.match(/}\\s*\\('(.*?)'\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)\\s*,\\s*'(.*?)'\\.split/);
            if (!m) return "";
            let payload = m[1];
            const radix = parseInt(m[2], 10);
            let count = parseInt(m[3], 10);
            const keywords = m[4].split('|');
            function e(c) {
                return (c < radix ? '' : e(parseInt(c / radix, 10))) + ((c = c % radix) > 35 ? String.fromCharCode(c + 29) : c.toString(36));
            }
            while (count--) {
                if (keywords[count]) {
                    payload = payload.replace(new RegExp('\\\\b' + e(count) + '\\\\b', 'g'), keywords[count]);
                }
            }
            return payload;
        }

        const scripts = document.getElementsByTagName('script');
        let fullScriptText = '';
        for (let i = 0; i < scripts.length; i++) {
            const t = scripts[i].textContent || '';
            fullScriptText += ' ' + t;
            if (t.includes('eval(function(p,a,c,k,e,d)')) {
                const unpacked = unpackDean(t);
                if (unpacked) fullScriptText += ' ' + unpacked;
            }
        }

        // 3. 正则扫描 surrit / m3u8
        if (!hls) {
            const m1 = fullScriptText.match(/https?:\\/\\/[^\\s"'<>]*surrit\\.com[^\\s"'<>]+\\.m3u8/);
            if (m1) {
                hls = m1[0];
            }
        }
        if (!hls) {
            // 字符集里排除反斜杠：脚本里的地址常带转义，以前会把末尾的反斜杠一起截进来
            const m2 = fullScriptText.match(/https?:\\/\\/[^\\s"'<>\\\\]+\\.m3u8[^\\s"'<>\\\\]*/);
            if (m2) {
                hls = m2[0];
            }
        }

        // 4. 扫描 36 位 UUID 组合 surrit playlist 地址
        if (!hls) {
            const m3 = fullScriptText.match(/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/);
            if (m3) {
                hls = `https://surrit.com/${m3[0]}/playlist.m3u8`;
            }
        }

        // 5. 提取元信息
        const ogTitle = document.querySelector('meta[property="og:title"]')?.content;
        const h1 = document.querySelector('h1')?.textContent?.trim();
        const title = ogTitle || h1 || document.title || '';

        const ogImage = document.querySelector('meta[property="og:image"]')?.content || '';

        // 女优、类型在视频信息区（div.space-y-2 下一行一个 .text-secondary：「女優:」「類型:」…）；
        // 不能全页找：导航菜单里也有「女優排行」这类 /actresses/ 链接，类型也会重复
        const infoRows = document.querySelectorAll('.space-y-2 > .text-secondary');
        const pick = (selector) => {
            const scoped = Array.from(infoRows).flatMap(row => Array.from(row.querySelectorAll(selector)));
            return Array.from(new Set(scoped.map(el => el.textContent.trim()).filter(Boolean)));
        };
        const models = pick('a[href*="/actresses/"]');
        const tags = pick('a[href*="/genres/"]');

        const related = [];
        const seen = new Set();
        const relatedItems = document.querySelectorAll('div.thumbnail');
        const reserved = new Set(['genres', 'actresses', 'makers', 'tags', 'login', 'register', 'vip', 'search', 'dm', 'new', 'release', 'today-hot', 'weekly-hot', 'monthly-hot', 'chinese-subtitle', 'uncensored-leak']);

        for (let i = 0; i < relatedItems.length; i++) {
            const card = relatedItems[i];
            const links = card.querySelectorAll('a[href]');
            let rHref = '';
            let rId = '';
            for (let j = 0; j < links.length; j++) {
                const h = links[j].href || '';
                const clean = h.replace(/\\/$/, '');
                const parts = clean.split('/');
                const last = parts[parts.length - 1] || '';
                if (last && /-/.test(last) && /\\d/.test(last) && !reserved.has(last.toLowerCase()) && !h.includes('/genres/') && !h.includes('/actresses/')) {
                    rHref = clean;
                    rId = last;
                    break;
                }
            }
            if (!rId || seen.has(rId)) continue;
            seen.add(rId);

            const img = card.querySelector('img');
            const cover = img ? (img.getAttribute('data-src') || img.getAttribute('data-original') || img.src || '') : '';
            const tEl = card.querySelector('a.text-secondary, a[class*="text-secondary"], .my-2 a, h4, h5, h6') || card.querySelector('a');
            const t = tEl ? tEl.textContent.trim() : rId.toUpperCase();
            const dEl = card.querySelector('span[class*="duration"], span.absolute, .duration');
            const d = dEl ? dEl.textContent.trim() : '';

            if (t && rId) {
                related.push({
                    id: rId,
                    title: t,
                    url: rHref,
                    coverUrl: cover,
                    duration: d,
                    views: ""
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

extension MissAVClient: WKNavigationDelegate {
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
        guard loadingWebPage, let id = currentTask?.id, challengeController == nil else { return }
        complete(id, with: .failure(MissAVError.network(error)))
    }
}

// MARK: - 独立安全验证控制器

private final class MissAVChallengeViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    private let webView: WKWebView
    private let onCancel: () -> Void

    init(webView: WKWebView, onCancel: @escaping () -> Void) {
        self.webView = webView
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "安全验证"
        view.backgroundColor = .systemBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(refresh))

        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    @objc private func cancel() {
        dismiss(animated: true) { [onCancel] in onCancel() }
    }

    @objc private func refresh() {
        webView.reload()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 网页还要留给后台继续加载用：从验证页上拿下来，恢复成后台时的大小
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = CGRect(x: 0, y: 0, width: 375, height: 667)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        onCancel()
    }
}

// MARK: - 页面骨架就绪

extension MissAVClient: WKScriptMessageHandler {
    /// DOMContentLoaded：列表和播放地址已经在页面里了，马上提取，不等图片、广告加载完
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in self.inspectAndHandlePage(afterLoad: true) }
    }
}
