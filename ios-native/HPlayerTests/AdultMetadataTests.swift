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
