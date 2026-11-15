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

/// Cloudflare 人机验证上下文
struct JableChallenge: Identifiable {
    let id = UUID()
    let url: URL
    let webView: WKWebView
    let onDismiss: () -> Void
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

    /// 当前是否有正在等待用户交互的 Cloudflare 验证
    @Published var activeChallenge: JableChallenge?

    private var webView: WKWebView!
    private var isProcessing = false
    private var queue: [QueuedTask] = []
    private var currentTask: QueuedTask?
    private var timeoutTimer: Timer?
    private var challengeCheckTimer: Timer?

    private struct QueuedTask {
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
    func detail(videoId: String, pageUrl: String? = nil) async throws -> JableVideoDetail {
        let targetString: String
        if let pageUrl, !pageUrl.isEmpty {
            targetString = pageUrl
        } else {
            targetString = "\(Self.baseURL)/videos/\(videoId)/"
        }
        guard let url = URL(string: targetString) else { throw JableError.invalidURL }
        let json = try await execute(url: url, extractorJS: Self.detailExtractorScript)
        return try Self.parseVideoDetail(json: json, fallbackId: videoId)
    }

    /// 解析视频播放信息
    func resolvePlayback(videoId: String) async throws -> JablePlayback {
        let detail = try await self.detail(videoId: videoId)
        guard let streamURL = URL(string: detail.hlsUrl), !detail.hlsUrl.isEmpty else {
            throw JableError.noStreamFound
        }
        return JablePlayback(url: streamURL, headers: Self.mediaHeaders)
    }

    // MARK: - 内部请求调度

    private func execute(url: URL, extractorJS: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.append(QueuedTask(url: url, extractorJS: extractorJS, continuation: continuation))
            processNextTaskIfNeeded()
        }
    }

    private func processNextTaskIfNeeded() {
        guard !isProcessing, !queue.isEmpty else { return }
        isProcessing = true
        let task = queue.removeFirst()
        currentTask = task

        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.currentTask != nil else { return }
                // 如果正在展示安全验证页面，不立刻超时，延长等待用户操作
                if self.activeChallenge != nil { return }
                self.failCurrent(with: JableError.timeout)
            }
        }

        var request = URLRequest(url: task.url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 25)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        webView.load(request)
    }

    private func failCurrent(with error: Error) {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        challengeCheckTimer?.invalidate()
        challengeCheckTimer = nil
        activeChallenge = nil

        let task = currentTask
        currentTask = nil
        isProcessing = false

        task?.continuation.resume(throwing: error)
        processNextTaskIfNeeded()
    }

    private func finishCurrent(with result: String) {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        challengeCheckTimer?.invalidate()
        challengeCheckTimer = nil
        activeChallenge = nil

        let task = currentTask
        currentTask = nil
        isProcessing = false

        task?.continuation.resume(returning: result)
        processNextTaskIfNeeded()
    }

    private func inspectAndHandlePage() {
        let checkScript = """
        (() => {
            const title = document.title || '';
            const body = document.body ? document.body.innerText : '';
            const hasTurnstile = document.querySelector('#challenge-running, #challenge-form, iframe[src*="challenges.cloudflare.com"], .cf-turnstile') !== null;
            const isChallenge = title.includes("Just a moment") || title.includes("Attention Required") || body.includes("Verify you are human") || hasTurnstile;
            return isChallenge;
        })()
        """
        webView.evaluateJavaScript(checkScript) { [weak self] result, _ in
            guard let self = self, let task = self.currentTask else { return }
            let isChallenge = (result as? Bool) ?? false

            if isChallenge {
                if self.activeChallenge == nil {
                    self.activeChallenge = JableChallenge(url: task.url, webView: self.webView) { [weak self] in
                        self?.failCurrent(with: JableError.challengeCancelled)
                    }
                    self.startChallengePolling()
                }
            } else {
                self.challengeCheckTimer?.invalidate()
                self.challengeCheckTimer = nil
                self.activeChallenge = nil

                // 提取页面内容
                self.webView.evaluateJavaScript(task.extractorJS) { [weak self] res, err in
                    guard let self = self else { return }
                    if let err = err {
                        self.failCurrent(with: JableError.parsingFailed(err.localizedDescription))
                    } else if let jsonString = res as? String {
                        self.finishCurrent(with: jsonString)
                    } else {
                        self.failCurrent(with: JableError.parsingFailed("页面未返回提取结果"))
                    }
                }
            }
        }
    }

    private func startChallengePolling() {
        challengeCheckTimer?.invalidate()
        challengeCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.currentTask != nil else { return }
                self.inspectAndHandlePage()
            }
        }
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

            const subEl = item.querySelector('.sub-title');
            const views = subEl ? subEl.textContent.trim() : '';

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
        let hls = '';
        const scripts = document.getElementsByTagName('script');
        for (let i = 0; i < scripts.length; i++) {
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
            const v = vEl ? vEl.textContent.trim() : '';

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
            self.inspectAndHandlePage()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            let nsErr = error as NSError
            if nsErr.code == NSURLErrorCancelled { return }
            self.failCurrent(with: error)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            let nsErr = error as NSError
            if nsErr.code == NSURLErrorCancelled { return }
            self.failCurrent(with: error)
        }
    }
}
