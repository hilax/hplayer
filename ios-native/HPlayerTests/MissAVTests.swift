import XCTest
import WebKit
@testable import HPlayer

@MainActor
final class MissAVTests: XCTestCase {
    func testVideoRefRoundTripsThroughRecordURL() {
        let ref = MissAVVideoRef(videoId: "sw-123", title: "测试标题", coverUrl: "https://example.com/cover.jpg")
        XCTAssertEqual(ref.recordURL, "hpmissav://video/sw-123")
        let restored = MissAVVideoRef(recordURL: ref.recordURL, title: ref.episodeTitle)
        XCTAssertEqual(restored?.videoId, "sw-123")
        XCTAssertEqual(restored?.title, "测试标题")
        XCTAssertNil(MissAVVideoRef(recordURL: "https://example.com/video/sw-123", title: "x"))
        XCTAssertNil(MissAVVideoRef(recordURL: "hpmissav://video/", title: "x"))
    }

    func testRecentStoreKeepsMissAVPositionAndRestoresSource() {
        let suite = "missav-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentStore(defaults: defaults)
        let source = PlaybackSource.missav(MissAVVideoRef(videoId: "fc2-456", title: "测试片名"))

        store.record(source)
        store.record(source)
        XCTAssertEqual(store.items.count, 1, "同一部视频只保留一条记录")

        store.savePosition(for: source, seconds: 120, duration: 480)
        XCTAssertEqual(store.progress(for: source) ?? 0, 0.25, accuracy: 0.001)

        let item = store.items[0]
        XCTAssertTrue(item.isMissAV)
        XCTAssertFalse(item.isAnime)
        XCTAssertFalse(item.isDrama)
        XCTAssertFalse(item.isJable)

        let restoredSource = store.source(for: item)
        XCTAssertEqual(restoredSource, source)
    }

    func testRecentPlaylistStoreHandlesMissAV() {
        let source = PlaybackSource.missav(MissAVVideoRef(videoId: "sw-999", title: "播放列表片名", coverUrl: "https://surrit.com/cover.jpg"))
        let stored = RecentPlaylistStore.StoredSource(source)
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.source, source)
    }

    func testCardJsonParsing() throws {
        let json = """
        [
            {
                "id": "sw-001",
                "title": "MissAV 视频 1",
                "url": "https://missav.ws/sw-001",
                "coverUrl": "https://eightyik.com/cover1.jpg",
                "duration": "02:10:15",
                "views": ""
            },
            {
                "id": "",
                "title": "无效视频",
                "url": "",
                "coverUrl": ""
            }
        ]
        """
        let cards = try MissAVClient.parseVideoCards(json: json)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].id, "sw-001")
        XCTAssertEqual(cards[0].title, "MissAV 视频 1")
        XCTAssertEqual(cards[0].duration, "02:10:15")
    }

    func testDetailJsonParsing() throws {
        let json = """
        {
            "hlsUrl": "https://surrit.com/12345678-1234-1234-1234-123456789abc/playlist.m3u8",
            "title": "MissAV 详细片名",
            "coverUrl": "https://eightyik.com/detail.jpg",
            "models": ["相泽南"],
            "tags": ["无码流出", "巨乳"],
            "related": [
                {
                    "id": "rel-002",
                    "title": "推荐视频",
                    "url": "https://missav.ws/rel-002",
                    "coverUrl": "https://eightyik.com/rel.jpg",
                    "duration": "01:30:00",
                    "views": ""
                }
            ]
        }
        """
        let detail = try MissAVClient.parseVideoDetail(json: json, fallbackId: "sw-001")
        XCTAssertEqual(detail.id, "sw-001")
        XCTAssertEqual(detail.title, "MissAV 详细片名")
        XCTAssertEqual(detail.hlsUrl, "https://surrit.com/12345678-1234-1234-1234-123456789abc/playlist.m3u8")
        XCTAssertEqual(detail.models, ["相泽南"])
        XCTAssertEqual(detail.tags, ["无码流出", "巨乳"])
        XCTAssertEqual(detail.related.count, 1)
        XCTAssertEqual(detail.related[0].id, "rel-002")
    }

    func testImagePipelineMissAVHeaders() {
        let missavURL = URL(string: "https://eightyik.com/cover/sw-123.jpg")!
        let headers = ImagePipeline.defaultImageHeaders(for: missavURL)
        XCTAssertEqual(headers["Referer"], "https://missav.ws/")
        XCTAssertNotNil(headers["User-Agent"])

        let surritURL = URL(string: "https://surrit.com/thumb/cover.jpg")!
        let surritHeaders = ImagePipeline.defaultImageHeaders(for: surritURL)
        XCTAssertEqual(surritHeaders["Referer"], "https://missav.ws/")
    }

    private let listHTML = """
    <html><head><title>测试列表</title></head><body>
      <div class="cf-turnstile"></div>
      <script src="/cdn-cgi/challenge-platform/scripts/jsd/main.js"></script>
      <script>window.__missavUnwantedScriptRan = true;</script>
      <div class="thumbnail">
        <a href="/sw-001"><img data-src="https://example.com/cover.jpg"></a>
        <a class="text-secondary" href="/sw-001">测试影片</a>
        <span class="duration">01:20:00</span>
      </div>
    </body></html>
    """

    func testListLoadsThroughHTTPWithBrowserCookiesAndHeaders() async throws {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let clearance = try XCTUnwrap(HTTPCookie(properties: [
            .name: "cf_clearance", .value: "test-clearance", .domain: ".missav.ws", .path: "/", .secure: "TRUE",
        ]))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            dataStore.httpCookieStore.setCookie(clearance) { continuation.resume() }
        }
        let body = Data(listHTML.utf8)
        RoutedURLProtocol.install { _ in .init(headers: ["Content-Type": "text/html"], body: body) }
        let client = MissAVClient(session: RoutedURLProtocol.session(), websiteDataStore: dataStore)

        let cards = try await client.list(category: .todayHot)
        XCTAssertEqual(cards.map(\.id), ["sw-001"])
        XCTAssertEqual(cards.first?.url, "https://missav.ws/sw-001")
        XCTAssertEqual(cards.first?.duration, "01:20:00")
        let requests = RoutedURLProtocol.requests()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), MissAVClient.userAgent)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://missav.ws/")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("cf_clearance=test-clearance") == true)

        _ = try await client.list(category: .weeklyHot)
        XCTAssertEqual(RoutedURLProtocol.requests().count, 2, "后续分类继续复用会话，不重开验证网页")
    }

    func testHTMLParsingDoesNotRunPageScriptsOrTreatWidgetsAsChallenge() async throws {
        let webView = WKWebView()
        let result = try await parseHTML(listHTML, with: webView, extractor: MissAVClient.listExtractorScript)
        XCTAssertEqual(result["challenge"] as? Bool, false)
        let json = try XCTUnwrap(result["json"] as? String)
        XCTAssertEqual(try MissAVClient.parseVideoCards(json: json).count, 1)
        let ran = try await webView.evaluateJavaScript("window.__missavUnwantedScriptRan === true") as? Bool
        XCTAssertEqual(ran, false)
    }

    func testLocalizedInterstitialIsNotParsedAsAnEmptyList() async throws {
        let fixtures = [
            "<html><head><title>请稍候…</title></head><body><form id='challenge-form'></form></body></html>",
            "<html><head><title>Just a moment...</title></head><body><script src='/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1'></script></body></html>",
        ]
        let webView = WKWebView()
        for html in fixtures {
            let result = try await parseHTML(html, with: webView, extractor: MissAVClient.listExtractorScript)
            XCTAssertEqual(result["challenge"] as? Bool, true)
            XCTAssertNil(result["json"], "验证页必须留给浏览器处理，不能缓存为空列表")
        }
    }

    func testHTTPDetailUnpacksStreamWithoutExecutingPlayerScript() async throws {
        let html = """
        <html><head><meta property="og:title" content="测试详情"></head><body>
          <video></video>
          <script>eval(function(p,a,c,k,e,d){return p;}('0="1://2/3.4";',5,5,'source|https|cdn.example.test|manifest|m3u8'.split('|'),0,{}));</script>
        </body></html>
        """
        RoutedURLProtocol.install { _ in .init(headers: ["Content-Type": "text/html"], body: Data(html.utf8)) }
        let client = MissAVClient(session: RoutedURLProtocol.session(), websiteDataStore: .nonPersistent())

        let detail = try await client.detail(videoId: "sw-001")
        XCTAssertEqual(detail.title, "测试详情")
        XCTAssertEqual(detail.hlsUrl, "https://cdn.example.test/manifest.m3u8")
        let playback = try await client.resolvePlayback(videoId: "sw-001")
        XCTAssertEqual(playback.url.absoluteString, detail.hlsUrl)
        XCTAssertEqual(RoutedURLProtocol.requests().count, 1, "点播放直接使用刚才缓存的详情")
    }

    func testBrowserCookieReuseRespectsDomainPathExpiryAndHTTPS() throws {
        func cookie(_ name: String, domain: String = ".missav.ws", path: String = "/", expires: Date? = nil) throws -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: "test", .domain: domain, .path: path, .secure: "TRUE",
            ]
            if let expires { properties[.expires] = expires }
            return try XCTUnwrap(HTTPCookie(properties: properties))
        }
        let cookies = try [
            cookie("clearance"), cookie("unrelated", domain: ".example.com"),
            cookie("wrong-path", path: "/today"), cookie("expired", expires: Date(timeIntervalSinceNow: -60)),
        ]
        XCTAssertEqual(MissAVClient.cookies(cookies, matching: URL(string: "https://missav.ws/today-hot")!).map(\.name), ["clearance"])
        XCTAssertTrue(MissAVClient.cookies(cookies, matching: URL(string: "https://missav.ws.example.com/")!).isEmpty)
        XCTAssertTrue(MissAVClient.cookies(cookies, matching: URL(string: "http://missav.ws/")!).isEmpty)
    }

    func testActiveAndQueuedRequestsCanBothBeCancelledPromptly() async {
        let started = expectation(description: "HTTP request started")
        MissAVWaitingURLProtocol.onStart = { started.fulfill() }
        defer { MissAVWaitingURLProtocol.onStart = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MissAVWaitingURLProtocol.self]
        let client = MissAVClient(session: URLSession(configuration: configuration), websiteDataStore: .nonPersistent())
        let activeFinished = expectation(description: "Active request cancelled")
        let active = Task {
            do {
                _ = try await client.list(category: .todayHot)
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
                _ = try await client.list(category: .weeklyHot)
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
            MissAVClient.htmlExtractionScript(extractorJS: extractor),
            arguments: ["html": html, "baseURL": "https://missav.ws/today-hot"],
            in: nil, contentWorld: .defaultClient
        )
        return try XCTUnwrap(result as? [String: Any])
    }
}

private final class MissAVWaitingURLProtocol: URLProtocol {
    static var onStart: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.onStart?() }
    override func stopLoading() {}
}
