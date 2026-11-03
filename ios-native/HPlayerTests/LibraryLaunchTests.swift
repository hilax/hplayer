import XCTest
@testable import HPlayer

/// 首页启动白屏、片库第一次打开卡顿的回归测试。
final class LibraryLaunchTests: XCTestCase {
    // MARK: 文件名解析结果存盘

    func testParsedNamesSurviveARestartOfTheSameBuild() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parsed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let names = ["仙逆.Renegade.Immortal.S01E05.2023.1080p.WEB-DL.mp4", "Arrival.2016.mp4"]
        let parsed = MediaNameParser.parsed(names)
        XCTAssertEqual(parsed.count, 2)

        ParsedNameDiskCache.save(parsed, to: url, stamp: "build-a")
        let restored = ParsedNameDiskCache.load(from: url, stamp: "build-a")
        XCTAssertEqual(restored, parsed, "Every field of the parse result must round-trip")
        XCTAssertEqual(restored[names[0]]?.episode, 5)
        XCTAssertEqual(restored[names[1]]?.year, "2016")
    }

    func testANewBuildIgnoresTheOldParseResults() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parsed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        ParsedNameDiskCache.save(MediaNameParser.parsed(["Dune.2021.mp4"]), to: url, stamp: "build-a")
        XCTAssertTrue(ParsedNameDiskCache.load(from: url, stamp: "build-b").isEmpty,
                      "Parsing rules may have changed in a new build")
    }

    func testMissingOrDamagedCacheFileIsIgnored() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parsed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(ParsedNameDiskCache.load(from: url, stamp: "x").isEmpty)
        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(ParsedNameDiskCache.load(from: url, stamp: "x").isEmpty)
    }

    func testSeededResultsAreServedWithoutReparsing() {
        let name = "seeded-\(UUID().uuidString).mkv"
        let marker = MediaNameParser.ParsedName(title: "种子标题", year: "1999", season: 2, episode: 3, catalogCode: nil)
        MediaNameParser.seed([name: marker])
        XCTAssertEqual(MediaNameParser.parse(name), marker)
    }

    func testCachedRegexesParseTheSameAsBefore() {
        // 同一个模式重复使用编译好的正则，结果必须和每次重新编译一样。
        for _ in 0..<3 {
            let value = MediaNameParser.parseUncached("The.Demon.Hunter.S01E71.2026.mkv")
            XCTAssertEqual(value.season, 1)
            XCTAssertEqual(value.episode, 71)
            XCTAssertEqual(value.year, "2026")
        }
    }

    // MARK: 首页和片库共用的分组

    @MainActor
    func testSnapshotIsSharedAndCatalogEntriesArePreparedInAdvance() async {
        let store = LibrarySnapshotStore()
        XCTAssertFalse(store.ready)
        await store.rebuildEntries(recents: [])
        XCTAssertFalse(store.catalogReady, "No entries before the first snapshot")

        let files = ["a.mp4", "b.mp4", "c.mp4"].map {
            LibraryMedia(local: LocalMedia(url: URL(fileURLWithPath: "/tmp/\($0)"), size: 100, modified: .distantPast))
        }
        var matches: [String: MediaMetadata] = [:]
        for (index, file) in files.prefix(2).enumerated() {
            matches[file.id] = MediaMetadata(imdbID: "m\(index)", type: "movie", title: "片\(index)", year: "2026",
                                             posterURL: "https://images.example.org/\(index).jpg", backgroundURL: "",
                                             logoURL: "", overview: "", rating: "", genres: [], country: "",
                                             season: nil, episode: nil)
        }
        await store.rebuild(files: files, matches: matches)
        XCTAssertTrue(store.ready)
        XCTAssertEqual(store.revision, 1)
        XCTAssertEqual(store.home.items.count, 3)
        XCTAssertEqual(store.home.movies.count, 2)

        await store.rebuildEntries(recents: [])
        XCTAssertTrue(store.catalogReady)
        XCTAssertEqual(store.catalogEntries.count, 2, "Both matched movies are ready for the catalog grid")
    }

    @MainActor
    func testLargeLibraryIsGroupedOffTheMainThreadWithTheSameResult() async {
        let count = LibrarySnapshotStore.inlineLimit + 50
        let files = (0..<count).map {
            LibraryMedia(local: LocalMedia(url: URL(fileURLWithPath: "/tmp/big-\($0).mp4"), size: 100, modified: .distantPast))
        }
        let store = LibrarySnapshotStore()
        await store.rebuild(files: files, matches: [:])
        XCTAssertTrue(store.ready)
        XCTAssertEqual(store.home.items.count, count)
        XCTAssertEqual(store.home.unmatched.count, count)
    }
}
