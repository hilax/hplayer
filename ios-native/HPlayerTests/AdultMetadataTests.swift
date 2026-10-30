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
