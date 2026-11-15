import XCTest
@testable import HPlayer

@MainActor
final class JableTests: XCTestCase {
    func testVideoRefRoundTripsThroughRecordURL() {
        let ref = JableVideoRef(videoId: "ssis-123", title: "测试标题", coverUrl: "https://example.com/cover.jpg")
        XCTAssertEqual(ref.recordURL, "hpjable://video/ssis-123")
        let restored = JableVideoRef(recordURL: ref.recordURL, title: ref.episodeTitle)
        XCTAssertEqual(restored?.videoId, "ssis-123")
        XCTAssertEqual(restored?.title, "测试标题")
        XCTAssertNil(JableVideoRef(recordURL: "https://example.com/video/ssis-123", title: "x"))
        XCTAssertNil(JableVideoRef(recordURL: "hpjable://video/", title: "x"))
    }

    func testRecentStoreKeepsJablePositionAndRestoresSource() {
        let suite = "jable-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentStore(defaults: defaults)
        let source = PlaybackSource.jable(JableVideoRef(videoId: "ipx-456", title: "测试片名"))

        store.record(source)
        store.record(source)
        XCTAssertEqual(store.items.count, 1, "同一部视频只保留一条记录")

        store.savePosition(for: source, seconds: 60, duration: 240)
        XCTAssertEqual(store.progress(for: source) ?? 0, 0.25, accuracy: 0.001)

        let item = store.items[0]
        XCTAssertTrue(item.isJable)
        XCTAssertFalse(item.isAnime)
        XCTAssertFalse(item.isDrama)

        let restoredSource = store.source(for: item)
        XCTAssertEqual(restoredSource, source)
    }

    func testCardJsonParsing() throws {
        let json = """
        [
            {
                "id": "ssis-001",
                "title": "测试视频 1",
                "url": "https://jable.tv/videos/ssis-001/",
                "coverUrl": "https://assets.jable.tv/cover1.jpg",
                "duration": "01:50:20",
                "views": "1.2万次播放"
            },
            {
                "id": "",
                "title": "无效视频",
                "url": "",
                "coverUrl": ""
            }
        ]
        """
        let cards = try JableClient.parseVideoCards(json: json)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].id, "ssis-001")
        XCTAssertEqual(cards[0].title, "测试视频 1")
        XCTAssertEqual(cards[0].duration, "01:50:20")
        XCTAssertEqual(cards[0].views, "1.2万次播放")
    }

    func testDetailJsonParsing() throws {
        let json = """
        {
            "hlsUrl": "https://stream.jable.tv/hls/test.m3u8",
            "title": "详细片名",
            "coverUrl": "https://assets.jable.tv/detail_cover.jpg",
            "models": ["三上悠亚", "河北彩花"],
            "tags": ["中文字幕", "巨乳"],
            "related": [
                {
                    "id": "rel-001",
                    "title": "相关视频",
                    "url": "https://jable.tv/videos/rel-001/",
                    "coverUrl": "https://assets.jable.tv/rel.jpg",
                    "duration": "02:10:00",
                    "views": "5000次播放"
                }
            ]
        }
        """
        let detail = try JableClient.parseVideoDetail(json: json, fallbackId: "main-001")
        XCTAssertEqual(detail.id, "main-001")
        XCTAssertEqual(detail.title, "详细片名")
        XCTAssertEqual(detail.hlsUrl, "https://stream.jable.tv/hls/test.m3u8")
        XCTAssertEqual(detail.models, ["三上悠亚", "河北彩花"])
        XCTAssertEqual(detail.tags, ["中文字幕", "巨乳"])
        XCTAssertEqual(detail.related.count, 1)
        XCTAssertEqual(detail.related[0].id, "rel-001")
    }

    func testImagePipelineJableHeaders() {
        let jableURL = URL(string: "https://mushroomtrack.com/cover/ssis-123.jpg")!
        let headers = ImagePipeline.defaultImageHeaders(for: jableURL)
        XCTAssertEqual(headers["Referer"], "https://jable.tv/")
        XCTAssertNotNil(headers["User-Agent"])

        let normalURL = URL(string: "https://example.com/image.png")!
        let normalHeaders = ImagePipeline.defaultImageHeaders(for: normalURL)
        XCTAssertNil(normalHeaders["Referer"])
    }
}
