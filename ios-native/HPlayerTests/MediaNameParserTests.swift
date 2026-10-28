import XCTest
@testable import HPlayer

final class MediaNameParserTests: XCTestCase {
    func testParsesEnglishReleaseName() {
        let parsed = MediaNameParser.parse(
            "The.Demon.Hunter.S01E71.2026.2160p.WEB-DL.H265.AAC-BlackTV.mkv"
        )

        XCTAssertEqual(parsed.title, "The Demon Hunter")
        XCTAssertEqual(parsed.year, "2026")
        XCTAssertEqual(parsed.season, 1)
        XCTAssertEqual(parsed.episode, 71)
    }

    func testParsesChineseEpisodeName() {
        let parsed = MediaNameParser.parse("凡人修仙传.第71集.2160p.HDR.mkv")

        XCTAssertEqual(parsed.title, "凡人修仙传")
        XCTAssertEqual(parsed.episode, 71)
    }

    func testNormalizesCacheKey() {
        XCTAssertEqual(
            MediaNameParser.cacheKey("The Demon Hunter"),
            MediaNameParser.cacheKey("the-demon-hunter")
        )
    }
}
