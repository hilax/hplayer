import XCTest
@testable import HPlayer

/// 播放器的选集要能看到整条线路的所有集数。
/// 动漫的流地址带时效签名、每次解析都不同，所以播放列表存的是集数引用而不是地址。
final class AnimePlaylistTests: XCTestCase {

    private func makeDetail(parts: [AnimePlayRoute]? = nil) -> AnimeVideoDetail {
        AnimeVideoDetail(
            id: 180167,
            name: "测试番剧",
            parts: parts ?? [
                AnimePlayRoute(play: "newup-jp", playZh: "日语", singleClarityDisplay: 1,
                               part: ["第01集", "第02集", "第03集", "第10集"]),
                AnimePlayRoute(play: "newup-cn", playZh: "国语", singleClarityDisplay: 1,
                               part: ["第01集", "第02集"]),
            ]
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "anime.playlist.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    // MARK: 选集列表

    func testEpisodeRefsCoverTheWholeSelectedRoute() {
        let detail = makeDetail()
        let refs = detail.episodeRefs(routeIndex: 0)

        XCTAssertEqual(refs.map(\.part), ["第01集", "第02集", "第03集", "第10集"])
        XCTAssertEqual(refs.count, 4, "播放器选集应当拿到整条线路，而不是正在播的那一集")
        XCTAssertTrue(refs.allSatisfy { $0.play == "newup-jp" && $0.animeId == 180167 && $0.routeIndex == 0 })
        XCTAssertEqual(refs.first?.episodeTitle, "测试番剧 第01集")
        XCTAssertEqual(Set(refs.map(\.id)).count, refs.count, "选集 id 不能重复，否则列表渲染会错乱")

        // 切线路后集数跟着变
        XCTAssertEqual(detail.episodeRefs(routeIndex: 1).map(\.part), ["第01集", "第02集"])
        XCTAssertTrue(detail.episodeRefs(routeIndex: 1).allSatisfy { $0.play == "newup-cn" })
    }

    func testEpisodeRefsFallBackToFirstRouteAndDeduplicate() {
        let detail = makeDetail()
        XCTAssertEqual(detail.episodeRefs(routeIndex: 99).map(\.play), ["newup-jp", "newup-jp", "newup-jp", "newup-jp"],
                       "线路下标越界时退回第一条")
        XCTAssertTrue(makeDetail(parts: []).episodeRefs(routeIndex: 0).isEmpty)

        let duplicated = makeDetail(parts: [
            AnimePlayRoute(play: "newup-jp", playZh: "日语", singleClarityDisplay: nil,
                           part: ["第01集", "第01集", "", "第02集"]),
        ])
        XCTAssertEqual(duplicated.episodeRefs(routeIndex: 0).map(\.part), ["第01集", "第02集"])
    }

    /// PlayerView.init 的规则：播放源不在列表里就退化成单集列表。
    /// 当前集必须能按 id 在列表里找到，否则选集又会只剩一集。
    func testCurrentEpisodeIsFoundInPlaylistWithoutResolving() {
        let refs = makeDetail().episodeRefs(routeIndex: 0)
        let playlist = refs.map { PlaybackSource.anime($0) }
        let current = PlaybackSource.anime(refs[2])

        XCTAssertTrue(playlist.contains(current))
        XCTAssertEqual(playlist.firstIndex(of: current), 2)
        XCTAssertEqual(playlist.count, 4)
        XCTAssertEqual(current.title, "测试番剧 第03集")
    }

    /// 同一集解析两次得到两个不同的签名地址，但身份必须是同一个。
    func testAnimeIdentitySurvivesReResolution() {
        let ref = makeDetail().episodeRefs(routeIndex: 0)[0]
        let first = PlaybackSource.online(title: ref.episodeTitle, url: URL(string: "https://cdn.example.com/a.m3u8?sign=111")!, headers: [:])
        let second = PlaybackSource.online(title: ref.episodeTitle, url: URL(string: "https://cdn.example.com/a.m3u8?sign=222")!, headers: [:])

        XCTAssertNotEqual(first.id, second.id, "签名地址本来就每次都不同")
        XCTAssertEqual(PlaybackSource.anime(ref).id, PlaybackSource.anime(ref).id)
        XCTAssertEqual(PlaybackSource.anime(ref).id, ref.id)
    }

    // MARK: 播放记录

    func testRecentStoreKeepsOneRecordPerEpisodeAcrossResolves() {
        let store = RecentStore(defaults: makeDefaults())
        let refs = makeDetail().episodeRefs(routeIndex: 0)
        let first = PlaybackSource.anime(refs[0])

        store.record(first)
        store.savePosition(for: first, seconds: 300, duration: 1400)
        XCTAssertEqual(store.position(for: first), 300)

        // 再播同一集（地址已经换了一个新的），记录不能变成两条，位置也不能丢
        store.record(first)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.position(for: first), 300)
        XCTAssertEqual(store.progress(for: first) ?? 0, 300.0 / 1400.0, accuracy: 0.0001)

        // 别集是独立的一条
        store.record(.anime(refs[1]))
        XCTAssertEqual(store.items.count, 2)
        XCTAssertNil(store.position(for: .anime(refs[1])))
    }

    /// 「继续观看」要能还原成集数引用，重新解析一个新鲜地址；记录里的旧签名地址早过期了。
    func testRecentRecordRestoresToEpisodeRef() throws {
        let store = RecentStore(defaults: makeDefaults())
        let ref = makeDetail().episodeRefs(routeIndex: 1)[1]
        store.record(.anime(ref))

        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.animeRef, ref)
        XCTAssertTrue(item.isAnime)
        XCTAssertEqual(item.url, "", "不存会过期的签名地址")
        XCTAssertEqual(store.source(for: item), .anime(ref))
    }

    /// 升级前写入的动漫记录按流地址存。升级后第一次播同一集要认领回来，
    /// 续播位置和「已看完」标记都不能丢，也不能留下重复的一条。
    func testAdoptsLegacyURLKeyedAnimeRecord() throws {
        let defaults = makeDefaults()
        let legacy = RecentItem(
            id: "legacy-1",
            title: "测试番剧 第01集",
            url: "https://m3bkbfdm.hzhcbkj.cn/a.m3u8?sign=expired",
            playedAt: Date(),
            position: 420,
            duration: 1400,
            finished: true
        )
        defaults.set(try JSONEncoder().encode([legacy]), forKey: "hplayer.recent")

        let store = RecentStore(defaults: defaults)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertNil(store.items[0].animeRef)
        XCTAssertTrue(store.items[0].isAnime, "旧记录靠 CDN 域名也认得出是动漫")

        let ref = makeDetail().episodeRefs(routeIndex: 0)[0]
        store.record(.anime(ref))

        XCTAssertEqual(store.items.count, 1, "认领旧记录，不是新加一条")
        XCTAssertEqual(store.items[0].id, "legacy-1")
        XCTAssertEqual(store.items[0].animeRef, ref)
        XCTAssertEqual(store.items[0].finished, true)
        XCTAssertEqual(store.position(for: .anime(ref)), 420)

        // 详情页按标题查进度，新旧记录都要能查到
        XCTAssertEqual(store.animeEpisode(title: "测试番剧 第01集")?.animeRef, ref)
    }

    /// 旧记录没有动漫字段，解码不能失败，也不能被误认成集数引用。
    func testLegacyRecordWithoutAnimeFieldsStillDecodes() throws {
        let json = """
        {"id":"a1","title":"测试番剧 第01集","url":"https://example.com/a.m3u8","playedAt":0,"position":120,"duration":600}
        """
        let item = try JSONDecoder().decode(RecentItem.self, from: Data(json.utf8))
        XCTAssertNil(item.animeRef)
        XCTAssertEqual(item.position, 120)
    }

    // MARK: 详情页回填

    /// 在播放器里切集也需要写下「最后看的一集」，否则退出后详情页还停在最初那集。
    func testRememberAsLastWatchedWritesEpisodeAndRoute() {
        let id = 990_001
        let episodeKey = "anime.last_episode.\(id)"
        let routeKey = "anime.last_route.\(id)"
        addTeardownBlock {
            UserDefaults.standard.removeObject(forKey: episodeKey)
            UserDefaults.standard.removeObject(forKey: routeKey)
        }

        let ref = AnimeEpisodeRef(animeId: id, seriesName: "测试番剧", play: "newup-cn", routeIndex: 2, part: "第07集")
        ref.rememberAsLastWatched()

        XCTAssertEqual(UserDefaults.standard.string(forKey: episodeKey), "第07集")
        XCTAssertEqual(UserDefaults.standard.integer(forKey: routeKey), 2)
    }
}