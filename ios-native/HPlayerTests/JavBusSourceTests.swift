import XCTest
@testable import HPlayer

final class JavBusSourceTests: XCTestCase {
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
}
