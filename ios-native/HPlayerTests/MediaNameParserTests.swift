import XCTest
import CryptoKit
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

    func testEpisodeOnlyAndManualSearchKeepTheTitle() {
        let parsed = MediaNameParser.parse("凡人修仙传.E006.1080p.mkv")
        XCTAssertEqual(parsed.title, "凡人修仙传")
        XCTAssertEqual(parsed.episode, 6)
        XCTAssertEqual(MediaNameParser.parse("The.Demon.Hunter").title, "The Demon Hunter")
    }

    func testSHA1ReadsEveryByteAndSurvivesRename() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var data = Data(repeating: 0x5A, count: 2 * 1024 * 1024 + 37)
        let original = directory.appendingPathComponent("video.mkv")
        try data.write(to: original)
        let firstHash = await MediaFingerprint.make(for: original)
        XCTAssertEqual(firstHash, Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined())
        let renamed = directory.appendingPathComponent("renamed.mkv")
        try FileManager.default.moveItem(at: original, to: renamed)
        let renamedHash = await MediaFingerprint.make(for: renamed)
        XCTAssertEqual(firstHash, renamedHash)
        data[data.count / 2] = 0x11
        try data.write(to: renamed)
        let changedHash = await MediaFingerprint.make(for: renamed)
        XCTAssertNotEqual(firstHash, changedHash, "Hash must include the middle of the file")
    }
}
