import XCTest
import WebKit
@testable import HPlayer

@MainActor
final class JableTests: XCTestCase {
    func testVideoRefRoundTripsThroughRecordURL() {
        let ref = JableVideoRef(videoId: "ssis-123", title: "测试标题", coverUrl: "https://example.com/cover.jpg")
        XCTAssertEqual(ref.recordURL, "hpjable://video/ssis-123")
        let restored = JableVideoRef(recordURL: ref.recordURL, title: ref.episodeTitle)
        XCTAssertEqual(restored?.videoId, "ssis-123")
        XCTAssertEqual(restored?.title, "测试标题")
        XCTAssertNil(JableVideoRef(recordURL: "https://example.com/video/ssis-123", title: "x"))
        XCTAssertNil(JableVideoRef(recordURL: "hpjable://video/", title: "x"))
    }

    func testRecentStoreKeepsJablePositionAndRestoresSource() {
        let suite = "jable-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentStore(defaults: defaults)
        let source = PlaybackSource.jable(JableVideoRef(videoId: "ipx-456", title: "测试片名"))

        store.record(source)
        store.record(source)
        XCTAssertEqual(store.items.count, 1, "同一部视频只保留一条记录")

        store.savePosition(for: source, seconds: 60, duration: 240)
        XCTAssertEqual(store.progress(for: source) ?? 0, 0.25, accuracy: 0.001)

        let item = store.items[0]
        XCTAssertTrue(item.isJable)
        XCTAssertFalse(item.isAnime)
        XCTAssertFalse(item.isDrama)

        let restoredSource = store.source(for: item)
        XCTAssertEqual(restoredSource, source)
    }

    func testCardJsonParsing() throws {
        let json = """
        [
            {
                "id": "ssis-001",
                "title": "测试视频 1",
                "url": "https://jable.tv/videos/ssis-001/",
                "coverUrl": "https://assets.jable.tv/cover1.jpg",
                "duration": "01:50:20",
                "views": "1.2万次播放"
            },
            {
                "id": "",
                "title": "无效视频",
                "url": "",
                "coverUrl": ""
            }
        ]
        """
        let cards = try JableClient.parseVideoCards(json: json)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].id, "ssis-001")
        XCTAssertEqual(cards[0].title, "测试视频 1")
        XCTAssertEqual(cards[0].duration, "01:50:20")
        XCTAssertEqual(cards[0].views, "1.2万次播放")
    }

    func testDetailJsonParsing() throws {
        let json = """
        {
            "hlsUrl": "https://stream.jable.tv/hls/test.m3u8",
            "title": "详细片名",
            "coverUrl": "https://assets.jable.tv/detail_cover.jpg",
            "models": ["三上悠亚", "河北彩花"],
            "tags": ["中文字幕", "巨乳"],
            "related": [
                {
                    "id": "rel-001",
                    "title": "相关视频",
                    "url": "https://jable.tv/videos/rel-001/",
                    "coverUrl": "https://assets.jable.tv/rel.jpg",
                    "duration": "02:10:00",
                    "views": "5000次播放"
                }
            ]
        }
        """
        let detail = try JableClient.parseVideoDetail(json: json, fallbackId: "main-001")
        XCTAssertEqual(detail.id, "main-001")
        XCTAssertEqual(detail.title, "详细片名")
        XCTAssertEqual(detail.hlsUrl, "https://stream.jable.tv/hls/test.m3u8")
        XCTAssertEqual(detail.models, ["三上悠亚", "河北彩花"])
        XCTAssertEqual(detail.tags, ["中文字幕", "巨乳"])
        XCTAssertEqual(detail.related.count, 1)
        XCTAssertEqual(detail.related[0].id, "rel-001")
    }

    func testImagePipelineJableHeaders() {
        let jableURL = URL(string: "https://mushroomtrack.com/cover/ssis-123.jpg")!
        let headers = ImagePipeline.defaultImageHeaders(for: jableURL)
        XCTAssertEqual(headers["Referer"], "https://jable.tv/")
        XCTAssertNotNil(headers["User-Agent"])

        let normalURL = URL(string: "https://example.com/image.png")!
        let normalHeaders = ImagePipeline.defaultImageHeaders(for: normalURL)
        XCTAssertNil(normalHeaders["Referer"])
    }

    private let listHTML = """
    <html><head><title>测试列表</title></head><body>
      <div class="cf-turnstile"></div>
      <script src="/cdn-cgi/challenge-platform/scripts/jsd/main.js"></script>
      <script>window.__jableUnwantedScriptRan = true;</script>
      <div class="video-img-box">
        <a href="/videos/ssis-001/"><img data-src="https://example.com/cover.jpg"></a>
        <h6 class="title">测试影片</h6>
        <span class="label">01:20:00</span>
        <span class="sub-title">1234 50</span>
      </div>
    </body></html>
    """

    func testListLoadsThroughHTTPWithBrowserCookiesAndHeaders() async throws {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let clearance = try XCTUnwrap(HTTPCookie(properties: [
            .name: "cf_clearance", .value: "test-clearance", .domain: ".jable.tv", .path: "/", .secure: "TRUE",
        ]))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            dataStore.httpCookieStore.setCookie(clearance) { continuation.resume() }
        }
        let body = Data(listHTML.utf8)
        RoutedURLProtocol.install { _ in .init(headers: ["Content-Type": "text/html"], body: body) }
        let session = RoutedURLProtocol.session()
        let client = JableClient(session: session, websiteDataStore: dataStore)

        let cards = try await client.list(category: .latest)
        XCTAssertEqual(cards.map(\.id), ["ssis-001"])
        XCTAssertEqual(cards.first?.url, "https://jable.tv/videos/ssis-001/")
        XCTAssertEqual(cards.first?.duration, "01:20:00")
        let requests = RoutedURLProtocol.requests()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), JableClient.userAgent)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://jable.tv/")
        // URLProtocol 替代了系统 HTTP 协议，不会经过系统自动添加 Cookie 头的步骤。
        // 默认会话验证 Cookie 已同步到存储；无 Cookie 存储的手动加头路径另测。
        let storedCookies = session.configuration.httpCookieStorage?.cookies(for: request.url!) ?? []
        XCTAssertTrue(storedCookies.contains { $0.name == "cf_clearance" && $0.value == "test-clearance" })

        _ = try await client.list(category: .hot)
        XCTAssertEqual(RoutedURLProtocol.requests().count, 2, "后续分类继续复用会话，不重开验证网页")
    }

    func testHTTPWithoutCookieStorageSendsBrowserCookieHeader() async throws {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let clearance = try XCTUnwrap(HTTPCookie(properties: [
            .name: "cf_clearance", .value: "test-clearance", .domain: ".jable.tv", .path: "/", .secure: "TRUE",
        ]))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            dataStore.httpCookieStore.setCookie(clearance) { continuation.resume() }
        }
        let body = Data(listHTML.utf8)
        RoutedURLProtocol.install { _ in .init(headers: ["Content-Type": "text/html"], body: body) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoutedURLProtocol.self]
        configuration.httpCookieStorage = nil
        let client = JableClient(session: URLSession(configuration: configuration), websiteDataStore: dataStore)

        _ = try await client.list(category: .latest)
        let request = try XCTUnwrap(RoutedURLProtocol.requests().first)
        XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("cf_clearance=test-clearance") == true)
    }

    func testHTMLParsingDoesNotRunPageScriptsOrTreatWidgetsAsChallenge() async throws {
        let webView = WKWebView()
        let result = try await parseHTML(listHTML, with: webView, extractor: JableClient.listExtractorScript)
        XCTAssertEqual(result["challenge"] as? Bool, false)
        let json = try XCTUnwrap(result["json"] as? String)
        XCTAssertEqual(try JableClient.parseVideoCards(json: json).count, 1)
        let ran = try await webView.evaluateJavaScript("window.__jableUnwantedScriptRan === true") as? Bool
        XCTAssertEqual(ran, false)
    }

    func testLocalizedInterstitialIsNotParsedAsAnEmptyList() async throws {
        let fixtures = [
            "<html><head><title>请稍候…</title></head><body><form id='challenge-form'></form></body></html>",
            "<html><head><title>Just a moment...</title></head><body><script src='/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1'></script></body></html>",
        ]
        let webView = WKWebView()
        for html in fixtures {
            let result = try await parseHTML(html, with: webView, extractor: JableClient.listExtractorScript)
            XCTAssertEqual(result["challenge"] as? Bool, true)
            XCTAssertNil(result["json"], "验证页必须留给浏览器处理，不能缓存为空列表")
        }
    }

    func testHTMLParserResolvesRelativeVideoLinks() async throws {
        let html = listHTML.replacingOccurrences(of: "href=\"/videos/ssis-001/\"", with: "href=\"videos/ssis-001/\"")
        let result = try await parseHTML(html, with: WKWebView(), extractor: JableClient.listExtractorScript)
        let json = try XCTUnwrap(result["json"] as? String)
        let cards = try JableClient.parseVideoCards(json: json)
        XCTAssertEqual(cards.first?.url, "https://jable.tv/videos/ssis-001/")
    }

    func testHTTPDetailReadsStreamWithoutExecutingPlayerScript() async throws {
        let html = """
        <html><head><meta property="og:title" content="测试详情"></head><body>
          <video></video>
          <script>var hlsUrl = 'https://cdn.example.test/jable/manifest.m3u8?token=fixture';</script>
        </body></html>
        """
        RoutedURLProtocol.install { _ in .init(headers: ["Content-Type": "text/html"], body: Data(html.utf8)) }
        let client = JableClient(session: RoutedURLProtocol.session(), websiteDataStore: .nonPersistent())

        let detail = try await client.detail(videoId: "ssis-001")
        XCTAssertEqual(detail.title, "测试详情")
        XCTAssertEqual(detail.hlsUrl, "https://cdn.example.test/jable/manifest.m3u8?token=fixture")
        let playback = try await client.resolvePlayback(videoId: "ssis-001")
        XCTAssertEqual(playback.url.absoluteString, detail.hlsUrl)
        XCTAssertEqual(RoutedURLProtocol.requests().count, 1, "点播放直接使用刚才缓存的详情")
    }

    func testBrowserCookieReuseRespectsDomainPathExpiryAndHTTPS() throws {
        func cookie(_ name: String, domain: String = ".jable.tv", path: String = "/", expires: Date? = nil) throws -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: "test", .domain: domain, .path: path, .secure: "TRUE",
            ]
            if let expires { properties[.expires] = expires }
            return try XCTUnwrap(HTTPCookie(properties: properties))
        }
        let cookies = try [
            cookie("clearance"), cookie("unrelated", domain: ".example.com"),
            cookie("wrong-path", path: "/latest"), cookie("expired", expires: Date(timeIntervalSinceNow: -60)),
        ]
        XCTAssertEqual(JableClient.cookies(cookies, matching: URL(string: "https://jable.tv/latest-updates")!).map(\.name), ["clearance"])
        XCTAssertEqual(JableClient.cookies(cookies, matching: URL(string: "https://jable.tv.example.com/")!).map(\.name), ["unrelated"],
                       "相似域名只匹配它自己的 example.com Cookie，不得带上 Jable Cookie")
        XCTAssertTrue(JableClient.cookies(cookies, matching: URL(string: "http://jable.tv/")!).isEmpty)
    }

    func testActiveAndQueuedRequestsCanBothBeCancelledPromptly() async {
        let started = expectation(description: "HTTP request started")
        JableWaitingURLProtocol.onStart = { started.fulfill() }
        defer { JableWaitingURLProtocol.onStart = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JableWaitingURLProtocol.self]
        let client = JableClient(session: URLSession(configuration: configuration), websiteDataStore: .nonPersistent())
        let activeFinished = expectation(description: "Active request cancelled")
        let active = Task {
            do {
                _ = try await client.list(category: .latest)
                XCTFail("Expected cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            activeFinished.fulfill()
        }
        await fulfillment(of: [started], timeout: 5)

        let queuedFinished = expectation(description: "Queued request cancelled")
        let queued = Task {
            do {
                _ = try await client.list(category: .hot)
                XCTFail("Expected cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            queuedFinished.fulfill()
        }
        await Task.yield()
        queued.cancel()
        active.cancel()
        await fulfillment(of: [activeFinished, queuedFinished], timeout: 2)
    }

    private func parseHTML(_ html: String, with webView: WKWebView, extractor: String) async throws -> [String: Any] {
        let result = try await webView.callAsyncJavaScript(
            JableClient.htmlExtractionScript(extractorJS: extractor),
            arguments: ["html": html, "baseURL": "https://jable.tv/latest-updates"],
            in: nil, contentWorld: .defaultClient
        )
        return try XCTUnwrap(result as? [String: Any])
    }
}

private final class JableWaitingURLProtocol: URLProtocol {
    static var onStart: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.onStart?() }
    override func stopLoading() {}
}
