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
