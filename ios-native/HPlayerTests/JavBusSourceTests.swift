import XCTest
@testable import HPlayer

final class JavBusSourceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: JavBusSource.hostDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: JavBusSource.hostDefaultsKey)
        super.tearDown()
    }

    func testParseSearchItems() {
        let sampleHTML = """
        <div class="row">
          <a class="movie-box" href="https://www.javbus.com/SSIS-888">
            <div class="photo-frame">
              <img src="https://pics.javbus.com/cover/888_b.jpg" title="测试影片A标题">
            </div>
            <div class="photo-info">
              <span>测试影片A标题<br>
              <date>SSIS-888</date> / <date>2024-05-18</date>
            </div>
          </a>
          <a class="movie-box" href="/IPX-123">
            <div class="photo-frame">
              <img src="https://pics.javbus.com/cover/ipx123.jpg" title="测试影片B标题">
            </div>
            <div class="photo-info">
              <span>测试影片B标题<br>
              <date>IPX-123</date> / <date>2024-03-20</date>
            </div>
          </a>
        </div>
        """

        let items = JavBusSource.parseSearchItems(from: sampleHTML, baseURLString: "https://www.javbus.com")
        XCTAssertEqual(items.count, 2)

        let first = items[0]
        XCTAssertEqual(first.code, "SSIS-888")
        XCTAssertEqual(first.title, "测试影片A标题")
        XCTAssertEqual(first.coverURL?.absoluteString, "https://pics.javbus.com/cover/888_b.jpg")
        XCTAssertEqual(first.releaseDate, "2024-05-18")
        XCTAssertEqual(first.detailPath, "/SSIS-888")

        let second = items[1]
        XCTAssertEqual(second.code, "IPX-123")
        XCTAssertEqual(second.title, "测试影片B标题")
        XCTAssertEqual(second.releaseDate, "2024-03-20")
        XCTAssertEqual(second.detailPath, "/IPX-123")
    }

    func testParseStarItems() {
        let sampleHTML = """
        <div class="row">
          <a class="avatar-box text-center" href="https://www.javbus.com/star/2js">
            <div class="photo-frame">
              <img src="https://pics.javbus.com/actress/2js_a.jpg" title="三上悠亚">
            </div>
            <span>三上悠亚</span>
          </a>
          <a class="avatar-box text-center" href="/star/3v0">
            <div class="photo-frame">
              <img src="/actress/3v0.jpg">
            </div>
            <span>河北彩花</span>
          </a>
        </div>
        """

        let stars = JavBusSource.parseStarItems(from: sampleHTML, baseURLString: "https://www.javbus.com")
        XCTAssertEqual(stars.count, 2)

        let first = stars[0]
        XCTAssertEqual(first.name, "三上悠亚")
        XCTAssertEqual(first.detailPath, "/star/2js")
        XCTAssertEqual(first.avatarURL?.absoluteString, "https://pics.javbus.com/actress/2js_a.jpg")

        let second = stars[1]
        XCTAssertEqual(second.name, "河北彩花")
        XCTAssertEqual(second.detailPath, "/star/3v0")
        XCTAssertEqual(second.avatarURL?.absoluteString, "https://www.javbus.com/actress/3v0.jpg")
    }

    func testParseStarHeader() {
        let sampleDetailHTML = """
        <div class="avatar-box">
          <img src="https://pics.javbus.com/actress/2js_a.jpg" title="三上悠亚">
          <span class="pb10">三上悠亚</span>
        </div>
        <div class="photo-info">
          <p>生日: 1993-08-16</p>
          <p>年龄: 31</p>
          <p>身高: 159cm</p>
          <p>罩杯: F</p>
        </div>
        """

        let star = JavBusSource.parseStarHeader(from: sampleDetailHTML, detailPath: "/star/2js", baseURLString: "https://www.javbus.com")
        XCTAssertNotNil(star)
        XCTAssertEqual(star?.name, "三上悠亚")
        XCTAssertEqual(star?.detailPath, "/star/2js")
        XCTAssertTrue(star?.bio?.contains("1993-08-16") == true)
        XCTAssertTrue(star?.bio?.contains("罩杯: F") == true)
    }

    func testParseStarsFromMovieDetail() {
        let sampleMovieHTML = """
        <div class="info">
          <p class="header">演员:</p>
          <span class="genre"><a href="https://www.javbus.com/star/2js">三上悠亚</a></span>
          <span class="genre"><a href="/star/3v0">河北彩花</a></span>
        </div>
        """

        let stars = JavBusSource.parseStarsFromMovieDetail(sampleMovieHTML, baseURLString: "https://www.javbus.com")
        XCTAssertEqual(stars.count, 2)
        XCTAssertEqual(stars[0].name, "三上悠亚")
        XCTAssertEqual(stars[0].detailPath, "/star/2js")
        XCTAssertEqual(stars[1].name, "河北彩花")
        XCTAssertEqual(stars[1].detailPath, "/star/3v0")
    }

    func testParseMagnetsFromHTML() {
        let sampleAJAXHTML = """
        <table>
          <tr onmouseover="hover(this)">
            <td>
              <a href="magnet:?xt=urn:btih:1111111111111111111111111111111111111111&dn=SSIS-888-C">
                SSIS-888-UC.HD.mp4
              </a>
              <a class="btn btn-xs btn-primary">字幕</a>
              <a class="btn btn-xs btn-warning">高清</a>
            </td>
            <td><a class="btn-default btn-xs">5.20GB</a></td>
            <td>2024-05-19</td>
          </tr>
          <tr onmouseover="hover(this)">
            <td>
              <a href="magnet:?xt=urn:btih:2222222222222222222222222222222222222222&dn=SSIS-888">
                SSIS-888.mp4
              </a>
            </td>
            <td><a class="btn-default btn-xs">1.20GB</a></td>
            <td>2024-05-18</td>
          </tr>
        </table>
        """

        let magnets = JavBusSource.parseMagnetsFromHTML(sampleAJAXHTML)
        XCTAssertEqual(magnets.count, 2)

        let first = magnets[0]
        XCTAssertTrue(first.magnetURL.contains("1111111111111111111111111111111111111111"))
        XCTAssertEqual(first.size, "5.20GB")
        XCTAssertEqual(first.date, "2024-05-19")
        XCTAssertTrue(first.hasSubtitles)
        XCTAssertTrue(first.isHD)

        let second = magnets[1]
        XCTAssertTrue(second.magnetURL.contains("2222222222222222222222222222222222222222"))
        XCTAssertEqual(second.size, "1.20GB")
        XCTAssertEqual(second.date, "2024-05-18")
        XCTAssertFalse(second.hasSubtitles)
        XCTAssertFalse(second.isHD)
    }

    func testSortMagnets() {
        let normal = MagnetTorrentItem(
            magnetURL: "magnet:?xt=urn:btih:aaa",
            name: "普通版",
            size: "1GB",
            isHD: false,
            hasSubtitles: false
        )
        let hdOnly = MagnetTorrentItem(
            magnetURL: "magnet:?xt=urn:btih:bbb",
            name: "高清无字幕",
            size: "4GB",
            isHD: true,
            hasSubtitles: false
        )
        let subAndHD = MagnetTorrentItem(
            magnetURL: "magnet:?xt=urn:btih:ccc",
            name: "高清带字幕",
            size: "5GB",
            isHD: true,
            hasSubtitles: true
        )

        let sorted = JavBusSource.sortMagnets([normal, hdOnly, subAndHD])
        XCTAssertEqual(sorted.first?.name, "高清带字幕")
        XCTAssertEqual(sorted[1].name, "高清无字幕")
        XCTAssertEqual(sorted.last?.name, "普通版")
    }

    func testEmptyAndMalformedHTML() {
        let empty = JavBusSource.parseSearchItems(from: "<html><body>无结果</body></html>", baseURLString: "https://www.javbus.com")
        XCTAssertTrue(empty.isEmpty)

        let emptyMagnets = JavBusSource.parseMagnetsFromHTML("<div>暂无磁力</div>")
        XCTAssertTrue(emptyMagnets.isEmpty)
    }

    // MARK: - 修复回归：URL 补全、实体解码、磁力解析

    func testResolveURLHandlesRelativeAndProtocolRelative() {
        let base = "https://www.javbus.com"
        XCTAssertEqual(JavBusSource.resolveURL("/pics/a.jpg", baseURLString: base)?.absoluteString, "https://www.javbus.com/pics/a.jpg")
        XCTAssertEqual(JavBusSource.resolveURL("//img.javbus.com/a.jpg", baseURLString: base)?.absoluteString, "https://img.javbus.com/a.jpg")
        XCTAssertEqual(JavBusSource.resolveURL("https://pics.javbus.com/a.jpg", baseURLString: base)?.absoluteString, "https://pics.javbus.com/a.jpg")
        XCTAssertNil(JavBusSource.resolveURL("   ", baseURLString: base))
    }

    func testParseSearchItemsResolvesRelativeCoverDecodesEntitiesAndDedupes() {
        let html = """
        <a class="movie-box" href="/ABC-001">
          <img src="/pics/thumb/abc.jpg" title="A &amp; B &#39;x&#39;">
          <date>ABC-001</date> / <date>2024-01-02</date>
        </a>
        <a class="movie-box" href="https://www.javbus.com/ABC-001">
          <img src="/pics/thumb/abc.jpg" title="重复的一项">
          <date>ABC-001</date> / <date>2024-01-02</date>
        </a>
        """
        let items = JavBusSource.parseSearchItems(from: html, baseURLString: "https://www.javbus.com")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "A & B 'x'")
        XCTAssertEqual(items.first?.coverURL?.absoluteString, "https://www.javbus.com/pics/thumb/abc.jpg")
        XCTAssertEqual(items.first?.detailPath, "/ABC-001")
    }

    func testDecodeHTMLEntities() {
        XCTAssertEqual(JavBusSource.decodeHTMLEntities("Tom &amp; Jerry"), "Tom & Jerry")
        XCTAssertEqual(JavBusSource.decodeHTMLEntities("&amp;lt;"), "&lt;", "&amp; 只解码一次")
        XCTAssertEqual(JavBusSource.decodeHTMLEntities("&#x4e2d;&#25991;"), "中文")
        XCTAssertEqual(JavBusSource.decodeHTMLEntities("no entity"), "no entity")
    }

    func testParseMagnetsIgnoresNoiseInsideMagnetURL() {
        // 磁力地址里的 dn 带有 HD、2M 之类的字样，不能被当成高清标记或文件大小。
        let html = """
        <table>
          <tr>
            <td><a href="magnet:?xt=urn:btih:AAAA&amp;dn=HD-2M-sample">plain.mp4</a></td>
            <td><a class="btn-default">3.00GB</a></td>
            <td>2024-06-01</td>
          </tr>
          <tr>
            <td><a href="magnet:?xt=urn:btih:AAAA&amp;dn=HD-2M-sample">plain.mp4</a></td>
            <td><a class="btn-default">3.00GB</a></td>
            <td>2024-06-01</td>
          </tr>
        </table>
        """
        let magnets = JavBusSource.parseMagnetsFromHTML(html)
        XCTAssertEqual(magnets.count, 1, "相同磁力只保留一条")
        XCTAssertEqual(magnets.first?.size, "3.00GB")
        XCTAssertEqual(magnets.first?.date, "2024-06-01")
        XCTAssertEqual(magnets.first?.name, "plain.mp4")
        XCTAssertEqual(magnets.first?.isHD, false)
        XCTAssertEqual(magnets.first?.magnetURL, "magnet:?xt=urn:btih:AAAA&dn=HD-2M-sample")
    }

    func testNormalizedHost() {
        XCTAssertEqual(JavBusSource.normalizedHost("javbus.com"), "https://javbus.com")
        XCTAssertEqual(JavBusSource.normalizedHost("  https://www.javbus.com/  "), "https://www.javbus.com")
        XCTAssertEqual(JavBusSource.normalizedHost("http://mirror.example.com:8080/x"), "http://mirror.example.com:8080")
        XCTAssertNil(JavBusSource.normalizedHost(""))
        XCTAssertNil(JavBusSource.normalizedHost("not a host"))
        XCTAssertNil(JavBusSource.normalizedHost("localhost"))
    }

    func testCurrentHostFallsBackToDefaultWhenCustomHostIsInvalid() {
        let source = JavBusSource()
        XCTAssertEqual(source.currentHost, JavBusSource.defaultHost)

        UserDefaults.standard.set("mirror.example.com", forKey: JavBusSource.hostDefaultsKey)
        XCTAssertEqual(source.currentHost, "https://mirror.example.com")

        UserDefaults.standard.set("not a host", forKey: JavBusSource.hostDefaultsKey)
        XCTAssertEqual(source.currentHost, JavBusSource.defaultHost)
    }

    func testEncodePathSegmentEscapesSeparators() {
        XCTAssertEqual(JavBusSource.encodePathSegment("a/b?c#d"), "a%2Fb%3Fc%23d")
        XCTAssertFalse(JavBusSource.encodePathSegment("三上悠亚").contains("三"))
    }

    func testMakeAjaxURLEncodesImageParameter() throws {
        // 含空格的地址直接拼进字符串会让 URL(string:) 返回 nil，用 URLComponents 才能正确编码。
        let img = "https://www.javbus.com/pics/cover/x b.jpg"
        let url = try XCTUnwrap(JavBusSource.makeAjaxURL(host: "https://www.javbus.com", endpoint: "uncensoredcors.php", gid: "123", uc: "0", img: img, floor: 456))
        XCTAssertEqual(url.path, "/ajax/uncensoredcors.php")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "gid" }?.value, "123")
        XCTAssertEqual(items.first { $0.name == "img" }?.value, img)
    }

    func testIsAgeVerificationPage() {
        XCTAssertTrue(JavBusSource.isAgeVerificationPage(Self.ageVerifyHTML))
        XCTAssertFalse(JavBusSource.isAgeVerificationPage(Self.movieListHTML))
    }

    // MARK: - 修复回归：网络层（假网络）

    private static let movieListHTML = """
    <a class="movie-box" href="https://www.javbus.com/SSIS-888">
      <img src="https://pics.javbus.com/cover/888_b.jpg" title="测试影片A标题">
      <date>SSIS-888</date> / <date>2024-05-18</date>
    </a>
    """

    private static let ageVerifyHTML = """
    <html><body><div class="modal show" id="ageVerify" role="dialog"><h4>你是否已經成年?</h4></div></body></html>
    """

    private static let magnetTableHTML = """
    <table>
      <tr>
        <td><a href="magnet:?xt=urn:btih:1111&dn=x">x.mp4</a></td>
        <td><a class="btn-default">1.00GB</a></td>
        <td>2024-05-19</td>
      </tr>
    </table>
    """

    private func makeSource() -> JavBusSource {
        JavBusSource(session: RoutedURLProtocol.session())
    }

    func testSearchTreats404AsEmptyResult() async throws {
        RoutedURLProtocol.install { _ in .init(status: 404) }
        let movies = try await makeSource().search(keyword: "NOPE-000")
        XCTAssertTrue(movies.isEmpty)
    }

    func testSearchAllKeepsMoviesWhenActressSearchFails() async throws {
        RoutedURLProtocol.install { request in
            let path = request.url?.path ?? ""
            if path.hasPrefix("/searchstar/") {
                return .init(status: 500)
            }
            return .init(status: 200, body: Data(Self.movieListHTML.utf8))
        }
        let result = try await makeSource().searchAll(keyword: "SSIS-888")
        XCTAssertEqual(result.movies.count, 1)
        XCTAssertTrue(result.stars.isEmpty)
    }

    func testRequestsInstallAgeVerificationCookies() async throws {
        RoutedURLProtocol.install { _ in .init(status: 200, body: Data(Self.movieListHTML.utf8)) }
        let session = RoutedURLProtocol.session()
        let source = JavBusSource(session: session)
        _ = try await source.fetchCategory(.latest)

        let cookies = session.configuration.httpCookieStorage?.cookies(for: URL(string: "https://www.javbus.com/")!) ?? []
        XCTAssertTrue(Set(cookies.map(\.name)).isSuperset(of: ["existmag", "age", "dv"]))
    }

    func testAgeVerificationPageIsRetriedAfterSubmittingForm() async throws {
        let counter = CallCounter()
        RoutedURLProtocol.install { request in
            if request.httpMethod == "POST" {
                return .init(status: 200, body: Data("<html>ok</html>".utf8))
            }
            let html = counter.next() == 1 ? Self.ageVerifyHTML : Self.movieListHTML
            return .init(status: 200, body: Data(html.utf8))
        }
        let items = try await makeSource().fetchCategory(.latest)
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(RoutedURLProtocol.requests().contains { $0.httpMethod == "POST" })
    }

    func testPersistentAgeVerificationThrowsReadableError() async {
        RoutedURLProtocol.install { _ in .init(status: 200, body: Data(Self.ageVerifyHTML.utf8)) }
        do {
            _ = try await makeSource().fetchCategory(.latest)
            XCTFail("应该抛出年龄验证错误")
        } catch JavBusError.ageVerificationRequired {
            // 期望的结果
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }

    func testPagingUsesSitePaths() async throws {
        RoutedURLProtocol.install { _ in .init(status: 200, body: Data(Self.movieListHTML.utf8)) }
        let source = makeSource()

        _ = try await source.fetchCategory(.latest, page: 2)
        XCTAssertEqual(RoutedURLProtocol.requests().last?.url?.path, "/page/2")

        _ = try await source.fetchCategory(.uncensored, page: 3)
        XCTAssertEqual(RoutedURLProtocol.requests().last?.url?.path, "/uncensored/page/3")

        _ = try await source.fetchActresses(page: 2)
        XCTAssertEqual(RoutedURLProtocol.requests().last?.url?.path, "/actresses/2")

        _ = try await source.fetchStarDetail(starPath: "/star/2js", page: 2)
        XCTAssertEqual(RoutedURLProtocol.requests().last?.url?.path, "/star/2js/2")
    }

    func testStarDetailBeyondLastPageIsEmptyButFirstPage404Throws() async throws {
        RoutedURLProtocol.install { _ in .init(status: 404) }
        let source = makeSource()

        let beyond = try await source.fetchStarDetail(starPath: "/star/2js", page: 5)
        XCTAssertTrue(beyond.movies.isEmpty)
        XCTAssertNil(beyond.star)

        do {
            _ = try await source.fetchStarDetail(starPath: "/star/2js", page: 1)
            XCTFail("第一页 404 应该报错")
        } catch JavBusError.notFound {
            // 期望的结果
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }

    func testFetchDetailInfoFallsBackToSecondAjaxEndpoint() async throws {
        let detailHTML = """
        <script>
        var gid = 123;
        var uc = 0;
        var img = 'https://pics.javbus.com/cover/x_b.jpg';
        </script>
        """
        RoutedURLProtocol.install { request in
            switch request.url?.path ?? "" {
            case "/ABC-001":
                return .init(status: 200, body: Data(detailHTML.utf8))
            case "/ajax/uncledatoolsbyajax.php":
                return .init(status: 200, body: Data(Self.magnetTableHTML.utf8))
            default:
                return .init(status: 404)
            }
        }
        let item = MagnetSearchItem(code: "ABC-001", title: "t", coverURL: nil, detailPath: "/ABC-001")
        let (_, magnets) = try await makeSource().fetchDetailInfo(for: item)
        XCTAssertEqual(magnets.count, 1)
        XCTAssertEqual(magnets.first?.size, "1.00GB")
    }

    // MARK: - 修复回归：图片防盗链请求头

    func testImageHeadersAddRefererForJavBusDomainsOnly() throws {
        let cover = try XCTUnwrap(URL(string: "https://www.javbus.com/pics/thumb/a.jpg"))
        let headers = JavBusSource.imageHeaders(for: cover)
        XCTAssertEqual(headers["Referer"], "https://www.javbus.com/")
        XCTAssertEqual(headers["User-Agent"], JavBusSource.userAgent)

        let subdomain = try XCTUnwrap(URL(string: "https://pics.javbus.com/a.jpg"))
        XCTAssertEqual(JavBusSource.imageHeaders(for: subdomain)["Referer"], "https://www.javbus.com/")

        let other = try XCTUnwrap(URL(string: "https://images.example/a.jpg"))
        XCTAssertTrue(JavBusSource.imageHeaders(for: other).isEmpty)
    }

    func testImageHeadersFollowTheConfiguredMirror() throws {
        UserDefaults.standard.set("https://mirror.example.com", forKey: JavBusSource.hostDefaultsKey)
        let cover = try XCTUnwrap(URL(string: "https://img.example.com/pics/a.jpg"))
        XCTAssertEqual(JavBusSource.imageHeaders(for: cover)["Referer"], "https://mirror.example.com/")
    }
}

/// 假网络回调跑在别的线程上，计数要加锁。
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
