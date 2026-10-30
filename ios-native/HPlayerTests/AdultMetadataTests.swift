import XCTest
@testable import HPlayer

final class AdultMetadataTests: XCTestCase {
    func testExtractsOneCodeBeforeFilenameCleanup() {
        XCTAssertEqual(AVCatalogCode.extract("[ABC-123] 标题.1080p.mp4"), "ABC-123")
        XCTAssertEqual(AVCatalogCode.extract("abc001.mkv"), "ABC-001")
        XCTAssertEqual(AVCatalogCode.extract("abc_00001-c.mkv"), "ABC-001")
        XCTAssertEqual(AVCatalogCode.extract("[example123.com] ABC-123.mp4"), "ABC-123")
        XCTAssertEqual(MediaNameParser.parse("[ABC-123] 同名影片.mp4").catalogCode, "ABC-123")
        XCTAssertNil(AVCatalogCode.extract("[ABC-123] [DEF-456].mp4"))
        XCTAssertNil(AVCatalogCode.extract("Movie.2024.1080p.WEB-DL.x265.mkv"))
        XCTAssertNil(AVCatalogCode.extract("FC2-PPV-1234567.mp4"))
        XCTAssertNil(AVCatalogCode.extract("ABC-000.mp4"))
        for name in ["凡人修仙传.EP120.2160p.WEB-DL.mp4", "仙逆.EP078.mp4", "One.Piece.1100.1080p.mkv",
                     "Detective.Conan.1120.mkv", "Naruto Episode 100.mp4", "名侦探柯南 Vol 001.mkv", "Gundam.0079.E01.mkv"] {
            XCTAssertNil(AVCatalogCode.extract(name), name)
        }
    }

    func testDecodesCurrentR18DevFormatWithDigitPrefixedContentID() throws {
        let body: [String: Any] = [
            "content_id": "1start00656", "dvd_id": "START-656", "title_en": "English title", "title_ja": "日本語",
            "jacket_full_url": "https://pics.dmm.co.jp/mono/movie/adult/1start00656/1start00656pl.jpg",
            "release_date": "2025-03-04",
            "actresses": [["name_kanji": "演员甲", "name_romaji": "A"]],
        ]
        let match = try XCTUnwrap(R18DevClient.decode(JSONSerialization.data(withJSONObject: body), requestedCode: "START-656"))
        XCTAssertEqual(match.imdbID, "r18dev:START-656")
        XCTAssertTrue(match.posterURL.hasSuffix("1start00656pl.jpg"))
        XCTAssertEqual(match.title, "START-656 · English title")
        XCTAssertEqual(match.performers, ["演员甲"])
        XCTAssertEqual(AVCatalogCode.contentID("h_1234abc00123"), "ABC-123")
        XCTAssertEqual(AVCatalogCode.contentID("118abp00123"), "ABP-123")
        XCTAssertNil(AVCatalogCode.contentID("start00655x"))
        XCTAssertEqual(R18DevClient.request(for: "START-656", hyphenated: true)?.url?.absoluteString,
                       "https://r18.dev/videos/vod/movies/detail/-/dvd_id=start-656/json")
        XCTAssertEqual(AVCatalogCode.extract("[START-656] 标题.mp4"), "START-656")
    }

    func testDecodesPerformerNamesWithoutDuplicates() throws {
        let body: [String: Any] = [
            "content_id": "abc00123", "dvd_id": "ABC-123", "title": "T",
            "images": ["jacket_image": ["large": "https://images.example/c.jpg"]],
            "actresses": [["name_kanji": "演员甲", "name_romaji": "A"], ["name_kanji": "", "name_romaji": "Bee"], ["name_kanji": "演员甲"]],
        ]
        let match = try XCTUnwrap(R18DevClient.decode(JSONSerialization.data(withJSONObject: body), requestedCode: "ABC-123"))
        XCTAssertEqual(match.performers, ["演员甲", "Bee"])
    }

    func testRequiresMatchingSourceIdentityAndAUsableHTTPSPoster() throws {
        func decode(contentID: String, dvdID: String? = nil, poster: String = "https://images.example/cover.jpg") -> MediaMetadata? {
            let body: [String: Any] = [
                "content_id": contentID,
                "dvd_id": dvdID as Any? ?? NSNull(),
                "title": "Fixture title",
                "release_date": "2024-01-02",
                "images": ["jacket_image": ["large": " ", "large2": poster]],
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return R18DevClient.decode(data, requestedCode: "ABC-123")
        }
        let match = try XCTUnwrap(decode(contentID: "abc00123", dvdID: "ABC-123"))
        XCTAssertEqual(match.imdbID, "r18dev:ABC-123")
        XCTAssertEqual(match.sourceKind, .r18dev)
        XCTAssertEqual(match.year, "2024")
        XCTAssertEqual(match.posterURL, "https://images.example/cover.jpg")
        XCTAssertNil(decode(contentID: "abc00124"))
        XCTAssertNil(decode(contentID: "prefixabc00123"))
        XCTAssertNil(decode(contentID: "abc00123", dvdID: "ABC-124"))
        XCTAssertNil(decode(contentID: "abc00123", poster: ""))
        XCTAssertNil(decode(contentID: "abc00123", poster: "http://images.example/cover.jpg"))
    }

    func testRequestContainsOnlyCanonicalCodeAndNoCookies() throws {
        let request = try XCTUnwrap(R18DevClient.request(for: "ABC-123"))
        XCTAssertEqual(request.url?.absoluteString, "https://r18.dev/videos/vod/movies/detail/-/dvd_id=abc123/json")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(R18DevClient.request(for: "ABC-123 private filename"))
    }

    func testAutomaticAndManualSearchUseOnlyTheNumberWhenEnabled() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AdultMetadataURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        AdultMetadataURLProtocol.reset()
        let search = MetadataSearch(r18dev: R18DevClient(session: session), adultEnabled: { true })
        let parsed = MediaNameParser.parse("[ABC-123] private filename.mp4")
        let result = await search.lookup(parsed)
        XCTAssertEqual(result?.imdbID, "r18dev:ABC-123")
        let ordinary = await search.candidates(from: .bangumi, query: "ABC-123 private filename")
        XCTAssertTrue(ordinary.isEmpty)
        let manual = await search.candidates(from: .r18dev, query: "ABC-123 private filename")
        XCTAssertEqual(manual.first?.imdbID, "r18dev:ABC-123")
        let request = try XCTUnwrap(AdultMetadataURLProtocol.requests().first)
        XCTAssertEqual(request.url?.host, "r18.dev")
        XCTAssertFalse(request.url?.absoluteString.contains("private") ?? true)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))

        let disabled = MetadataSearch(r18dev: R18DevClient(session: session), adultEnabled: { false })
        let noAdultSearch = await disabled.candidates(from: .r18dev, query: "ABC-123")
        XCTAssertTrue(noAdultSearch.isEmpty)
        XCTAssertEqual(AdultMetadataURLProtocol.requests().count, 2)
    }

    func testCancelledWaitingLookupDoesNotSendAnotherRequest() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AdultMetadataURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        AdultMetadataURLProtocol.reset()
        let client = R18DevClient(session: session)
        let first = await client.lookup("ABC-123")
        XCTAssertNotNil(first)
        let waiting = Task { await client.lookup("ABC-123") }
        waiting.cancel()
        let cancelled = await waiting.value
        XCTAssertNil(cancelled)
        XCTAssertEqual(AdultMetadataURLProtocol.requests().count, 1)
    }
}

final class R18PerformerLookupTests: XCTestCase {
    /// r18.dev 的两层接口：按番号查只给 content_id（可能带封面），演员在按 content_id 查的详情里。
    private func route(codeBody: [String: Any]?, detailBody: [String: Any]?, detailStatus: Int = 404) -> (URLRequest) -> RoutedURLProtocol.Reply {
        { request in
            let path = request.url?.absoluteString ?? ""
            if path.contains("dvd_id="), let codeBody { return RoutedURLProtocol.Reply.json(codeBody) }
            if path.contains("combined=") {
                if let detailBody { return RoutedURLProtocol.Reply.json(detailBody) }
                return RoutedURLProtocol.Reply(status: detailStatus)
            }
            return RoutedURLProtocol.Reply(status: 404)
        }
    }

    private let detail: [String: Any] = [
        "content_id": "1abc00123", "dvd_id": "ABC-123", "title_en": "Detail title",
        "jacket_full_url": "https://pics.dmm.co.jp/digital/video/1abc00123/1abc00123pl.jpg", "release_date": "2024-05-06",
        "actresses": [["name_kanji": "演员甲", "name_romaji": "A"], ["name_kanji": "", "name_romaji": "Bee"], ["name_kanji": "演员甲 "]],
    ]

    func testMatchingFallsBackToTheDetailWhenTheCodeEndpointHasNoCover() async throws {
        RoutedURLProtocol.install(route(codeBody: ["content_id": "1abc00123", "dvd_id": "ABC-123"], detailBody: detail))
        let client = R18DevClient(session: RoutedURLProtocol.session(), minimumInterval: 0)
        let found = await client.lookup("ABC-123")
        let match = try XCTUnwrap(found)
        XCTAssertEqual(match.posterURL, "https://pics.dmm.co.jp/digital/video/1abc00123/1abc00123pl.jpg")
        XCTAssertEqual(match.performers, ["演员甲", "Bee"])
        XCTAssertEqual(match.contentID, "1abc00123")
        XCTAssertEqual(match.catalogCode, "ABC-123")
        let urls = RoutedURLProtocol.requests().compactMap { $0.url?.absoluteString }
        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(urls[0].hasSuffix("dvd_id=abc-123/json"))
        XCTAssertTrue(urls[1].hasSuffix("combined=1abc00123/json"))
    }

    func testMatchingNeedsOnlyOneRequestWhenTheCodeEndpointAlreadyHasACover() async throws {
        var full = detail
        full.removeValue(forKey: "actresses")
        RoutedURLProtocol.install(route(codeBody: full, detailBody: detail))
        let client = R18DevClient(session: RoutedURLProtocol.session(), minimumInterval: 0)
        let found = await client.lookup("ABC-123")
        let match = try XCTUnwrap(found)
        XCTAssertNil(match.performers, "Performers are filled in later by the background pass")
        XCTAssertEqual(match.contentID, "1abc00123")
        XCTAssertEqual(RoutedURLProtocol.requests().count, 1)
    }

    func testPerformersComeFromTheDetailWhenTheCodeEndpointHasNone() async {
        var full = detail
        full.removeValue(forKey: "actresses")
        RoutedURLProtocol.install(route(codeBody: full, detailBody: detail))
        let client = R18DevClient(session: RoutedURLProtocol.session(), minimumInterval: 0)
        let result = await client.performers(for: "ABC-123")
        XCTAssertEqual(result, .found(["演员甲", "Bee"]))
        XCTAssertEqual(RoutedURLProtocol.requests().count, 2)
    }

    func testKnownContentIDGoesStraightToTheDetailEndpoint() async {
        RoutedURLProtocol.install(route(codeBody: nil, detailBody: detail))
        let client = R18DevClient(session: RoutedURLProtocol.session(), minimumInterval: 0)
        let result = await client.performers(for: "ABC-123", contentID: "1abc00123")
        XCTAssertEqual(result, .found(["演员甲", "Bee"]))
        let urls = RoutedURLProtocol.requests().compactMap { $0.url?.absoluteString }
        XCTAssertEqual(urls.count, 1)
        XCTAssertTrue(urls[0].hasSuffix("combined=1abc00123/json"))
        XCTAssertNil(R18DevClient.detailRequest(contentID: "1abc00123/../../x"), "Only letters, digits and underscores may be put into the path")
    }

    func testStaleContentIDFallsBackToTheCodeEndpoint() async {
        let wrong: [String: Any] = ["content_id": "1xyz99999", "dvd_id": "XYZ-999", "actresses": [["name_kanji": "别人"]]]
        RoutedURLProtocol.install { request in
            let path = request.url?.absoluteString ?? ""
            if path.contains("combined=1stale00001") { return .json(wrong) }
            if path.contains("dvd_id=") { return .json(["content_id": "1abc00123", "dvd_id": "ABC-123"]) }
            if path.contains("combined=1abc00123") { return .json(self.detail) }
            return .init(status: 404)
        }
        let client = R18DevClient(session: RoutedURLProtocol.session(), minimumInterval: 0)
        let result = await client.performers(for: "ABC-123", contentID: "1stale00001")
        XCTAssertEqual(result, .found(["演员甲", "Bee"]), "A wrong content_id must never attach another title's performers")
    }

    func testNoActressesMissingCodeAndNetworkErrorsAreDistinguished() async {
        var empty = detail
        empty["actresses"] = [Any]()
        RoutedURLProtocol.install(route(codeBody: ["content_id": "1abc00123", "dvd_id": "ABC-123"], detailBody: empty))
        let client = R18DevClient(session: RoutedURLProtocol.session(), minimumInterval: 0)
        let noActresses = await client.performers(for: "ABC-123")
        XCTAssertEqual(noActresses, .none)

        RoutedURLProtocol.install { _ in .init(status: 404) }
        let missing = await R18DevClient(session: RoutedURLProtocol.session(), minimumInterval: 0).performers(for: "ABC-123")
        XCTAssertEqual(missing, .none)
        XCTAssertEqual(RoutedURLProtocol.requests().count, 2, "Both dvd_id spellings are tried before giving up")

        RoutedURLProtocol.install { _ in .init(status: 500) }
        let failed = await R18DevClient(session: RoutedURLProtocol.session(), minimumInterval: 0).performers(for: "ABC-123")
        XCTAssertEqual(failed, .unavailable)

        RoutedURLProtocol.install(route(codeBody: ["content_id": "1abc00123", "dvd_id": "ABC-123"], detailBody: nil, detailStatus: 500))
        let detailDown = await R18DevClient(session: RoutedURLProtocol.session(), minimumInterval: 0).performers(for: "ABC-123")
        XCTAssertEqual(detailDown, .unavailable, "A failed detail request must not be recorded as 'has no performers'")
    }

    func testMalformedActressListKeepsTheCover() throws {
        let body: [String: Any] = [
            "content_id": "abc00123", "dvd_id": "ABC-123",
            "jacket_full_url": "https://images.example/c.jpg", "actresses": "unexpected",
        ]
        let parsed = try XCTUnwrap(R18DevClient.parse(JSONSerialization.data(withJSONObject: body), requestedCode: "ABC-123"))
        XCTAssertNotNil(parsed.metadata)
        XCTAssertNil(parsed.performers)
    }

    func testMissingOrMalformedActressDataIsRetryable() async {
        var incomplete = detail
        incomplete.removeValue(forKey: "actresses")
        RoutedURLProtocol.install(route(codeBody: nil, detailBody: incomplete))
        let cachedID = await R18DevClient(session: RoutedURLProtocol.session(), minimumInterval: 0)
            .performers(for: "ABC-123", contentID: "1abc00123")
        XCTAssertEqual(cachedID, .unavailable, "An absent list must not be cached as no performers")

        incomplete["actresses"] = "unexpected"
        RoutedURLProtocol.install(route(codeBody: ["content_id": "1abc00123", "dvd_id": "ABC-123"], detailBody: incomplete))
        let lookup = await R18DevClient(session: RoutedURLProtocol.session(), minimumInterval: 0)
            .performers(for: "ABC-123")
        XCTAssertEqual(lookup, .unavailable, "A malformed detail list must remain retryable")
    }

    func testSearchFallsBackToTheDMMAPIWhenR18HasNoPerformers() async {
        RoutedURLProtocol.install { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("r18.dev") { return .init(status: 404) }
            return .json(["result": ["status": 200, "items": [
                ["content_id": "1abc00123", "product_id": "abc00123", "title": "T",
                 "imageURL": ["large": "https://pics.dmm.co.jp/digital/video/1abc00123/1abc00123pl.jpg"],
                 "iteminfo": ["actress": [["id": 1, "name": "演员乙"]]]],
            ]]])
        }
        let session = RoutedURLProtocol.session()
        let search = MetadataSearch(r18dev: R18DevClient(session: session, minimumInterval: 0),
                                    dmm: DMMClient(session: session, credentials: { ("api", "aff") }), adultEnabled: { true })
        let found = await search.performers(for: "ABC-123")
        XCTAssertEqual(found, .found(["演员乙"]))
        let disabled = MetadataSearch(r18dev: R18DevClient(session: session, minimumInterval: 0), adultEnabled: { false })
        let off = await disabled.performers(for: "ABC-123")
        XCTAssertEqual(off, .unavailable)
    }
}

final class PerformerNameTests: XCTestCase {
    func testKeyIgnoresSpacingWidthCaseAndMiddleDots() {
        XCTAssertEqual(PerformerName.key("葵 つかさ"), PerformerName.key("葵つかさ"))
        XCTAssertEqual(PerformerName.key("Ａｂｃ　Ｄ"), PerformerName.key("abc d"))
        XCTAssertEqual(PerformerName.key("サラ・マリア"), PerformerName.key("サラ マリア"))
        XCTAssertNotEqual(PerformerName.key("葵つかさ"), PerformerName.key("葵つぐみ"))
        XCTAssertTrue(PerformerName.key(" ・ ").isEmpty)
    }

    func testUniqueKeepsOrderAndTidiesSpacing() {
        XCTAssertEqual(PerformerName.unique(["Tsukasa  Aoi", " 葵 ", "tsukasa aoi", "", "葵"]), ["Tsukasa Aoi", "葵"])
    }
}

final class MatchDiagnosticsTests: XCTestCase {
    func testKeepsOnlyTheLatestLinesAndListsTopLevelKeys() {
        let diagnostics = MatchDiagnostics()
        for index in 0..<350 { diagnostics.record("line \(index)") }
        XCTAssertEqual(diagnostics.snapshot.count, 300)
        XCTAssertTrue(diagnostics.snapshot.last?.hasSuffix("line 349") == true)
        XCTAssertEqual(MatchDiagnostics.keys(of: Data("{\"b\":1,\"a\":2}".utf8)), "字段：a,b")
        XCTAssertTrue(MatchDiagnostics.keys(of: Data("<html>".utf8)).hasPrefix("不是 JSON"))
        diagnostics.clear()
        XCTAssertTrue(diagnostics.snapshot.isEmpty)
    }
}

final class DMMSourceTests: XCTestCase {
    func testCoverURLsCoverPlainAndDigitPrefixedContentIDs() throws {
        let urls = try XCTUnwrap(DMMClient.coverURLs(for: "START-656")).map(\.absoluteString)
        XCTAssertEqual(urls, [
            "https://pics.dmm.co.jp/digital/video/start00656/start00656pl.jpg",
            "https://pics.dmm.co.jp/digital/video/1start00656/1start00656pl.jpg",
            "https://pics.dmm.co.jp/mono/movie/adult/start00656/start00656pl.jpg",
            "https://pics.dmm.co.jp/mono/movie/adult/1start00656/1start00656pl.jpg",
        ])
        XCTAssertNil(DMMClient.coverURLs(for: "START-656 private filename"))
    }

    func testCoverLookupUsesHeadRequestsAndPicksTheExistingImage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DMMURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        DMMURLProtocol.reset()
        let client = DMMClient(session: session, credentials: { nil })
        let found = await client.lookup("START-656")
        let match = try XCTUnwrap(found)
        XCTAssertEqual(match.imdbID, "dmm:START-656")
        XCTAssertEqual(match.sourceKind, .dmm)
        XCTAssertTrue(match.posterURL.hasSuffix("/digital/video/1start00656/1start00656pl.jpg"))
        XCTAssertTrue(match.isWideJacket)
        let recorded = DMMURLProtocol.requests()
        XCTAssertEqual(recorded.count, 4)
        XCTAssertTrue(recorded.allSatisfy { $0.httpMethod == "HEAD" && $0.url?.host == "pics.dmm.co.jp" })
        XCTAssertTrue(recorded.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
        let missing = await client.lookup("ZZZ-999")
        XCTAssertNil(missing)
    }

    func testAPIRequestAndIdentityCheckedDecode() throws {
        let request = try XCTUnwrap(DMMClient.apiRequest(code: "START-656", credentials: ("api123", "me-990")))
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        XCTAssertEqual(request.url?.host, "api.dmm.com")
        XCTAssertEqual(value("keyword"), "START-656")
        XCTAssertEqual(value("api_id"), "api123")
        XCTAssertEqual(value("floor"), "videoa")
        XCTAssertFalse(request.httpShouldHandleCookies)

        let body: [String: Any] = ["result": ["status": 200, "items": [
            ["content_id": "1start00655", "product_id": "start00655", "title": "Other",
             "imageURL": ["large": "https://pics.dmm.co.jp/digital/video/1start00655/1start00655pl.jpg"]],
            ["content_id": "1start00656", "product_id": "start00656", "title": "Target", "date": "2025-03-04 10:00:00",
             "imageURL": ["large": "https://pics.dmm.co.jp/digital/video/1start00656/1start00656pl.jpg"],
             "iteminfo": ["actress": [["id": 1, "name": "演员甲"], ["id": 2, "name": "演员乙"], ["id": 1, "name": "演员甲"]]]],
        ]]]
        let data = try JSONSerialization.data(withJSONObject: body)
        let match = try XCTUnwrap(DMMClient.decodeAPI(data, requestedCode: "START-656"))
        XCTAssertEqual(match.title, "START-656 · Target")
        XCTAssertEqual(match.year, "2025")
        XCTAssertEqual(match.performers, ["演员甲", "演员乙"])
        XCTAssertTrue(match.posterURL.contains("1start00656"))
        XCTAssertNil(DMMClient.decodeAPI(data, requestedCode: "START-700"))
        XCTAssertNil(DMMClient.decodeAPI(Data("{\"result\":{\"status\":401}}".utf8), requestedCode: "START-656"))
    }
}

private final class DMMURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recorded: [URLRequest] = []

    static func reset() { lock.lock(); defer { lock.unlock() }; recorded = [] }
    static func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        Self.lock.unlock()
        let exists = request.url?.absoluteString.contains("/digital/video/1start00656/") == true
        let response = HTTPURLResponse(url: request.url!, statusCode: exists ? 200 : 404, httpVersion: nil,
                                       headerFields: ["Content-Type": exists ? "image/jpeg" : "text/html"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class AdultMetadataURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recorded: [URLRequest] = []

    static func reset() { lock.lock(); defer { lock.unlock() }; recorded = [] }
    static func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        Self.lock.unlock()
        let body = try! JSONSerialization.data(withJSONObject: [
            "content_id": "abc00123", "title": "Fixture title",
            "images": ["jacket_image": ["large2": "https://images.example/cover.jpg"]],
        ])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
