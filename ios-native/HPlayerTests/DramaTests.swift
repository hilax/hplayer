import XCTest
@testable import HPlayer

final class DramaTests: XCTestCase {
    func testEpisodeRefRoundTripsThroughRecordURL() {
        let ref = DramaEpisodeRef(videoId: 117, seriesName: "测试 短剧", episode: 3)
        XCTAssertEqual(ref.recordURL, "hpdrama://video/117/3")
        let restored = DramaEpisodeRef(recordURL: ref.recordURL, title: ref.episodeTitle)
        XCTAssertEqual(restored, ref)
        XCTAssertNil(DramaEpisodeRef(recordURL: "https://example.com/video/117/3", title: "x"))
        XCTAssertNil(DramaEpisodeRef(recordURL: "hpdrama://video/abc/3", title: "x"))
    }

    func testRecentStoreKeepsDramaPositionAndRestoresSource() {
        let suite = "drama-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentStore(defaults: defaults)
        let source = PlaybackSource.drama(DramaEpisodeRef(videoId: 12, seriesName: "剧名", episode: 2))
        store.record(source)
        store.record(source)
        XCTAssertEqual(store.items.count, 1, "同一集只留一条记录")
        store.savePosition(for: source, seconds: 30, duration: 120)
        XCTAssertEqual(store.progress(for: source) ?? 0, 0.25, accuracy: 0.001)
        let item = store.items[0]
        XCTAssertTrue(item.isDrama)
        XCTAssertFalse(item.isAnime)
        XCTAssertEqual(store.source(for: item), source)
    }

    func testModelsReadLooselyTypedFields() {
        let card = DramaCard(json: ["id": "9", "title": "A", "cover": "c", "tags": ["x", 1] as [Any], "score": "8.5",
                                    "episode_count": 20, "is_finished": 1])
        XCTAssertEqual(card?.id, 9)
        XCTAssertEqual(card?.tags, ["x"])
        XCTAssertEqual(card?.statusText, "全 20 集")
        let detail = DramaDetail(json: ["id": 9, "title": "A", "episodes": [["ep_num": 2], ["ep_num": "1"], ["ep_num": 2]] as [[String: Any]],
                                        "author": ["name": "作者"]])
        XCTAssertEqual(detail?.episodes.map(\.number), [1, 2])
        XCTAssertEqual(detail?.author, "作者")
        let bare = DramaDetail(json: ["id": 9, "episode_count": "3"])
        XCTAssertEqual(bare?.episodes.count, 3)
        XCTAssertNil(DramaCard(json: ["title": "没有编号"]))
    }

    func testRankItemReadsLooseFields() {
        let item = DramaRankItem(json: ["rank": "2", "video_id": 7628, "title": "时停手表", "cover": "c",
                                        "tags": ["都市", 1] as [Any], "cate_name": "短剧",
                                        "episode_count": 10, "is_finished": true, "metric_label": "热力指数",
                                        "metric_value": "5938"])
        XCTAssertEqual(item?.rank, 2)
        XCTAssertEqual(item?.id, 7628)
        XCTAssertEqual(item?.tags, ["都市"])
        XCTAssertEqual(item?.subtitle, "短剧 · 全 10 集")
        XCTAssertEqual(item?.metricLabel, "热力指数")
        XCTAssertEqual(item?.metricValue, 5938)

        let updating = DramaRankItem(json: ["video_id": 1, "episode_count": 3])
        XCTAssertEqual(updating?.rank, 0)
        XCTAssertEqual(updating?.subtitle, "更新至 3 集")
        XCTAssertNil(DramaRankItem(json: ["rank": 1, "title": "没有编号"]))
    }

    /// 榜单只放行能认出是短剧、漫剧的条目；换脸、魔改和认不出分类的都不显示，名次重新连续编号
    func testRanksKeepOnlySeriesAndAnimated() {
        func rank(_ id: Int, _ rank: Int, cate: String = "", slug: String = "", title: String = "片名",
                  tags: [String] = []) -> DramaRankItem {
            DramaRankItem(json: ["video_id": id, "rank": rank, "cate_name": cate, "cate_slug": slug,
                                 "title": title, "tags": tags])!
        }
        let items = [
            rank(1, 1, cate: "换脸"),
            rank(2, 2, cate: "AI短剧"),
            rank(3, 3, slug: "ai-huanlian"),
            rank(4, 4, cate: "魔改"),
            rank(5, 5, slug: "ai-manju"),
            rank(6, 6),                                   // 认不出分类
            rank(7, 7, cate: "短剧", tags: ["AI换脸"]),     // 分类像短剧但标签是换脸
            rank(8, 8, cate: "漫剧", title: "某某魔改版"),
            rank(9, 9, cate: "漫剧")
        ]
        XCTAssertEqual(items.filter(\.isAllowedInApp).map(\.videoId), [2, 5, 9])
        let ranked = DramaClient.allowedRanks(items.reversed())
        XCTAssertEqual(ranked.map(\.videoId), [2, 5, 9])
        XCTAssertEqual(ranked.map(\.rank), [1, 2, 3])
    }

    func testPlayableURLHandlesFieldVariants() {
        let line = "https://example.com"
        XCTAssertEqual(DramaClient.playableURL(in: ["video_url": "https://a.b/x.m3u8?k=1"], line: line)?.absoluteString,
                       "https://a.b/x.m3u8?k=1")
        XCTAssertEqual(DramaClient.playableURL(in: ["video_url": "", "video_url_hevc": "//a.b/h.m3u8"], line: line)?.absoluteString,
                       "https://a.b/h.m3u8")
        XCTAssertEqual(DramaClient.playableURL(in: ["video_url": "/hls/1/index.m3u8"], line: line)?.absoluteString,
                       "https://example.com/hls/1/index.m3u8")
        XCTAssertEqual(DramaClient.playableURL(in: ["play": ["src": "https://a.b/v.mp4"]] as [String: Any], line: line)?.absoluteString,
                       "https://a.b/v.mp4")
        XCTAssertNotNil(DramaClient.playableURL(in: ["video_url": "https://a.b/短剧 1/x.m3u8"], line: line))
        XCTAssertNil(DramaClient.playableURL(in: ["video_url": "", "title": "x"], line: line))
    }

    /// 真实返回（2026-11-10 取自 POST /api/videos/12/episodes/1/playback，地址与校验值已缩短）
    func testParsePlaybackReadsStreamsAndCDNHeaders() {
        let payload: [String: Any] = [
            "mode": 1, "manifest_method": "GET", "ep": 1, "media_id": "",
            "cdn": ["m3u8Enabled": true, "otherEnabled": false, "authKey": "x-cdn-auth",
                    "authValue": "abc123", "app": "150"],
            "streams": ["main": "https://cdn.example/videos5/a/a.m3u8?auth_key=1-2&via_m=dx150",
                        "hevc": "https://cdn.example/m3m/h.m3u8?auth_key=1-3",
                        "preview": "https://cdn.example/videos5/a/a.m3u8?auth_key=1-2"],
        ]
        let parsed = DramaClient.parsePlayback(payload, line: "https://example.com")
        XCTAssertEqual(parsed?.url.absoluteString, "https://cdn.example/videos5/a/a.m3u8?auth_key=1-2&via_m=dx150")
        XCTAssertEqual(parsed?.headers["x-cdn-auth"], "abc123")
        XCTAssertEqual(parsed?.headers["x-cdn-app"], "150")
        // 没有 streams 时回落到老字段；都没有就是 nil
        XCTAssertEqual(DramaClient.parsePlayback(["video_url": "https://a.b/x.m3u8"], line: "https://example.com")?.url.absoluteString,
                       "https://a.b/x.m3u8")
        XCTAssertNil(DramaClient.parsePlayback(["streams": ["main": ""], "video_url": ""] as [String: Any], line: "https://example.com"))
    }

    func testCoverDecodeRejectsGarbage() {
        XCTAssertNil(DramaCoverStore.decode(Data()))
        XCTAssertNil(DramaCoverStore.decode(Data(repeating: 7, count: 32)))
    }
}
