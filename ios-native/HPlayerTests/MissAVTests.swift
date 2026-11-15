import XCTest
@testable import HPlayer

@MainActor
final class MissAVTests: XCTestCase {
    func testVideoRefRoundTripsThroughRecordURL() {
        let ref = MissAVVideoRef(videoId: "sw-123", title: "测试标题", coverUrl: "https://example.com/cover.jpg")
        XCTAssertEqual(ref.recordURL, "hpmissav://video/sw-123")
        let restored = MissAVVideoRef(recordURL: ref.recordURL, title: ref.episodeTitle)
        XCTAssertEqual(restored?.videoId, "sw-123")
        XCTAssertEqual(restored?.title, "测试标题")
        XCTAssertNil(MissAVVideoRef(recordURL: "https://example.com/video/sw-123", title: "x"))
        XCTAssertNil(MissAVVideoRef(recordURL: "hpmissav://video/", title: "x"))
    }

    func testRecentStoreKeepsMissAVPositionAndRestoresSource() {
        let suite = "missav-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentStore(defaults: defaults)
        let source = PlaybackSource.missav(MissAVVideoRef(videoId: "fc2-456", title: "测试片名"))

        store.record(source)
        store.record(source)
        XCTAssertEqual(store.items.count, 1, "同一部视频只保留一条记录")

        store.savePosition(for: source, seconds: 120, duration: 480)
        XCTAssertEqual(store.progress(for: source) ?? 0, 0.25, accuracy: 0.001)

        let item = store.items[0]
        XCTAssertTrue(item.isMissAV)
        XCTAssertFalse(item.isAnime)
        XCTAssertFalse(item.isDrama)
        XCTAssertFalse(item.isJable)

        let restoredSource = store.source(for: item)
        XCTAssertEqual(restoredSource, source)
    }

    func testRecentPlaylistStoreHandlesMissAV() {
        let source = PlaybackSource.missav(MissAVVideoRef(videoId: "sw-999", title: "播放列表片名", coverUrl: "https://surrit.com/cover.jpg"))
        let stored = RecentPlaylistStore.StoredSource(source)
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.source, source)
    }

    func testCardJsonParsing() throws {
        let json = """
        [
            {
                "id": "sw-001",
                "title": "MissAV 视频 1",
                "url": "https://missav.ws/sw-001",
                "coverUrl": "https://eightyik.com/cover1.jpg",
                "duration": "02:10:15",
                "views": ""
            },
            {
                "id": "",
                "title": "无效视频",
                "url": "",
                "coverUrl": ""
            }
        ]
        """
        let cards = try MissAVClient.parseVideoCards(json: json)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].id, "sw-001")
        XCTAssertEqual(cards[0].title, "MissAV 视频 1")
        XCTAssertEqual(cards[0].duration, "02:10:15")
    }

    func testDetailJsonParsing() throws {
        let json = """
        {
            "hlsUrl": "https://surrit.com/12345678-1234-1234-1234-123456789abc/playlist.m3u8",
            "title": "MissAV 详细片名",
            "coverUrl": "https://eightyik.com/detail.jpg",
            "models": ["相泽南"],
            "tags": ["无码流出", "巨乳"],
            "related": [
                {
                    "id": "rel-002",
                    "title": "推荐视频",
                    "url": "https://missav.ws/rel-002",
                    "coverUrl": "https://eightyik.com/rel.jpg",
                    "duration": "01:30:00",
                    "views": ""
                }
            ]
        }
        """
        let detail = try MissAVClient.parseVideoDetail(json: json, fallbackId: "sw-001")
        XCTAssertEqual(detail.id, "sw-001")
        XCTAssertEqual(detail.title, "MissAV 详细片名")
        XCTAssertEqual(detail.hlsUrl, "https://surrit.com/12345678-1234-1234-1234-123456789abc/playlist.m3u8")
        XCTAssertEqual(detail.models, ["相泽南"])
        XCTAssertEqual(detail.tags, ["无码流出", "巨乳"])
        XCTAssertEqual(detail.related.count, 1)
        XCTAssertEqual(detail.related[0].id, "rel-002")
    }

    func testImagePipelineMissAVHeaders() {
        let missavURL = URL(string: "https://eightyik.com/cover/sw-123.jpg")!
        let headers = ImagePipeline.defaultImageHeaders(for: missavURL)
        XCTAssertEqual(headers["Referer"], "https://missav.ws/")
        XCTAssertNotNil(headers["User-Agent"])

        let surritURL = URL(string: "https://surrit.com/thumb/cover.jpg")!
        let surritHeaders = ImagePipeline.defaultImageHeaders(for: surritURL)
        XCTAssertEqual(surritHeaders["Referer"], "https://missav.ws/")
    }
}
