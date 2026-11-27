import AVFoundation
import Network
import WebKit
import XCTest
@testable import HPlayer

final class SukebeiSourceTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_700_000_000)
        var date: Date { lock.lock(); defer { lock.unlock() }; return current }
        func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    // MARK: - URL 构建

    func testMakeRSSURLBuildsCategoryAndEncodedOrQuery() throws {
        let global = try XCTUnwrap(SukebeiSource.makeRSSURL())
        XCTAssertEqual(global.absoluteString, "https://sukebei.nyaa.si/?page=rss&c=2_2")

        let studio = try XCTUnwrap(SukebeiSource.makeRSSURL(query: "SONE|SNOS"))
        let comps = try XCTUnwrap(URLComponents(url: studio, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.queryItems?.first { $0.name == "page" }?.value, "rss")
        XCTAssertEqual(comps.queryItems?.first { $0.name == "c" }?.value, "2_2")
        XCTAssertEqual(comps.queryItems?.first { $0.name == "q" }?.value, "SONE|SNOS")
        XCTAssertTrue(studio.absoluteString.contains("SONE%7CSNOS"))

        XCTAssertNil(SukebeiSource.makeRSSURL(host: "not a url"))
    }

    // MARK: - RSS XML 解析

    func testParseRSSExtractsFieldsEntitiesAndSkipsInvalidHashes() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss xmlns:nyaa="https://sukebei.nyaa.si/xmlns/nyaa" version="2.0">
          <channel>
            <title>Sukebei - RSS</title>
            <item>
              <title>[777av.cc] SONE-456-C A &amp; B 美少女の秘密 [1080p].mp4</title>
              <guid isPermaLink="true">https://sukebei.nyaa.si/view/1001</guid>
              <pubDate>Mon, 23 Nov 2026 14:30:00 -0000</pubDate>
              <nyaa:seeders>42</nyaa:seeders>
              <nyaa:leechers>7</nyaa:leechers>
              <nyaa:infoHash>AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA</nyaa:infoHash>
              <nyaa:categoryId>2_2</nyaa:categoryId>
              <nyaa:size>4.2 GiB</nyaa:size>
            </item>
            <item>
              <title>INVALID-001 bad hash</title>
              <pubDate>Mon, 23 Nov 2026 12:00:00 GMT</pubDate>
              <nyaa:infoHash>not-40-hex</nyaa:infoHash>
              <nyaa:size>1.0 GiB</nyaa:size>
            </item>
          </channel>
        </rss>
        """
        let items = try SukebeiSource.parseRSS(Data(xml.utf8))
        XCTAssertEqual(items.count, 1)
        let first = items[0]
        XCTAssertEqual(first.title, "[777av.cc] SONE-456-C A & B 美少女の秘密 [1080p].mp4")
        XCTAssertEqual(first.infoHash, String(repeating: "a", count: 40))
        XCTAssertEqual(first.size, "4.2 GiB")
        XCTAssertEqual(first.date, "2026-11-23")
        XCTAssertEqual(first.seeders, 42)
        XCTAssertEqual(first.leechers, 7)
        XCTAssertEqual(first.categoryId, "2_2")
    }

    func testParseRSSThrowsOnHTMLChallengeOrEmptyData() {
        let html = "<html><body>Just a moment...</body></html>"
        XCTAssertThrowsError(try SukebeiSource.parseRSS(Data(html.utf8))) { error in
            XCTAssertTrue(error is SukebeiError)
        }
        XCTAssertThrowsError(try SukebeiSource.parseRSS(Data()))
    }

    // MARK: - 标签、高清与标题清理

    func testSubtitleAndHDDetection() {
        XCTAssertTrue(SukebeiSource.hasSubtitles(in: "SONE-456-C 标题"))
        XCTAssertTrue(SukebeiSource.hasSubtitles(in: "abf159ch.mp4"))
        XCTAssertTrue(SukebeiSource.hasSubtitles(in: "[中文字幕] MIDA-010"))
        XCTAssertTrue(SukebeiSource.hasSubtitles(in: "MIDA-010 [CHS]"))
        XCTAssertFalse(SukebeiSource.hasSubtitles(in: "SONE-456-C 无字幕"))
        XCTAssertFalse(SukebeiSource.hasSubtitles(in: "SONE-456 無字幕版"))
        XCTAssertFalse(SukebeiSource.hasSubtitles(in: "SONE-456.1080p.mp4"))

        XCTAssertTrue(SukebeiSource.isHD(in: "SONE-456.1080p.mp4"))
        XCTAssertTrue(SukebeiSource.isHD(in: "SONE-456 4K 60fps"))
        XCTAssertTrue(SukebeiSource.isHD(in: "SONE-456 高清版"))
        XCTAssertFalse(SukebeiSource.isHD(in: "SONE-456.mp4"))
    }

    func testDisplayTitleCleaningAndFallbackSummary() {
        let cleaned = SukebeiSource.displayTitle(
            from: "[777av.cc] SONE-456-C 美少女の秘密 [中文字幕] [1080p].mp4",
            code: "SONE-456",
            size: "4.2 GiB",
            hasSubtitles: true,
            isHD: true
        )
        XCTAssertEqual(cleaned, "美少女の秘密")

        let tagOnly = SukebeiSource.displayTitle(
            from: "hhd800.com@ABF-159-UC.1080p.HEVC.mp4",
            code: "ABF-159",
            size: "5.1 GiB",
            hasSubtitles: true,
            isHD: true
        )
        XCTAssertEqual(tagOnly, "中文字幕 · 高清 · 5.1 GiB")

        let plainCodeOnly = SukebeiSource.displayTitle(
            from: "IPZZ-100.mp4",
            code: "IPZZ-100",
            size: "",
            hasSubtitles: false,
            isHD: false
        )
        XCTAssertEqual(plainCodeOnly, "IPZZ-100")
    }

    // MARK: - 聚合与片商过滤

    func testGroupMoviesDedupesAndFiltersAllowedPrefixes() {
        let h1 = String(repeating: "1", count: 40)
        let h2 = String(repeating: "2", count: 40)
        let h3 = String(repeating: "3", count: 40)
        let h4 = String(repeating: "4", count: 40)
        let h5 = String(repeating: "5", count: 40)
        let entries = [
            SukebeiRSSItem(title: "SONE-456.1080p.mp4", infoHash: h1, size: "3.0 GiB", date: "2026-11-22", seeders: 10, leechers: 1, categoryId: "2_2"),
            SukebeiRSSItem(title: "SONE-456-C 真实副标题 [1080p]", infoHash: h2, size: "4.5 GiB", date: "2026-11-23", seeders: 30, leechers: 2, categoryId: "2_2"),
            SukebeiRSSItem(title: "SSIS-999 unrelated", infoHash: h3, size: "2.0 GiB", date: "2026-11-23", seeders: 5, leechers: 0, categoryId: "2_2"),
            SukebeiRSSItem(title: "FC2-PPV-1234567 ignored", infoHash: h4, size: "1.0 GiB", date: "2026-11-23", seeders: 5, leechers: 0, categoryId: "2_2"),
            SukebeiRSSItem(title: "The same 123 false match", infoHash: h5, size: "1.0 GiB", date: "2026-11-23", seeders: 5, leechers: 0, categoryId: "2_2"),
        ]

        let movies = SukebeiSource.groupMovies(from: entries, allowedPrefixes: ["SONE", "SNOS", "SAME"])
        XCTAssertEqual(movies.count, 1)
        let sone = movies[0]
        XCTAssertEqual(sone.code, "SONE-456")
        XCTAssertEqual(sone.id, "/SONE-456")
        XCTAssertEqual(sone.detailPath, "/SONE-456")
        XCTAssertEqual(sone.title, "真实副标题")
        XCTAssertEqual(sone.releaseDate, "2026-11-23")
        XCTAssertTrue(sone.isFresh)
        XCTAssertEqual(sone.prefetchedMagnets.count, 2)
        XCTAssertTrue(sone.prefetchedMagnets[0].hasSubtitles)
        XCTAssertEqual(sone.prefetchedMagnets[0].source, "Sukebei")
    }

    func testAllStudiosDefineSukebeiPrefixesAndQuery() {
        for studio in MagnetStudio.allCases {
            XCTAssertFalse(studio.sukebeiPrefixes.isEmpty, studio.title)
            XCTAssertTrue(studio.sukebeiPrefixes.allSatisfy { $0 == $0.uppercased() })
            XCTAssertEqual(studio.sukebeiQuery, studio.sukebeiPrefixes.joined(separator: "|"))
        }
    }

    // MARK: - 网络与 TTL 缓存

    func testFetchRSSUsesTTLCacheAndDoesNotCacheParseFailures() async throws {
        let clock = Clock()
        let hits = Counter()
        let xml = rssDocument(items: [
            (title: "SONE-456-C Test", hash: String(repeating: "a", count: 40), size: "3.0 GiB", pubDate: "Mon, 23 Nov 2026 10:00:00 -0000", seeders: 20),
        ])

        RoutedURLProtocol.install { _ in
            let n = hits.increment()
            if n == 1 {
                return .init(status: 200, body: Data("<html>challenge</html>".utf8))
            }
            return .init(status: 200, body: Data(xml.utf8))
        }

        let source = SukebeiSource(
            session: RoutedURLProtocol.session(),
            cacheLifetime: 180,
            now: { clock.date }
        )

        do {
            _ = try await source.fetchLatest()
            XCTFail("HTML 响应应抛出 parseFailed")
        } catch SukebeiError.parseFailed {
            // 期望结果，且不缓存失败
        }

        let first = try await source.fetchLatest()
        XCTAssertEqual(first.map(\.code), ["SONE-456"])
        XCTAssertEqual(hits.value, 2)

        clock.advance(60)
        let cached = try await source.fetchLatest()
        XCTAssertEqual(cached, first)
        XCTAssertEqual(hits.value, 2, "缓存期内不重复请求")

        clock.advance(130)
        _ = try await source.fetchLatest()
        XCTAssertEqual(hits.value, 3, "超过 TTL 后重新请求")
    }

    func testFetchMagnetsMatchesExactStandardAndNonStandardCodes() async throws {
        let h1 = String(repeating: "a", count: 40)
        let h2 = String(repeating: "b", count: 40)
        let h3 = String(repeating: "c", count: 40)
        let h4 = String(repeating: "d", count: 40)
        let xml = rssDocument(items: [
            (title: "SONE-456.mp4", hash: h1, size: "2.0 GiB", pubDate: "Mon, 23 Nov 2026 10:00:00 -0000", seeders: 10),
            (title: "SONE-4560.mp4", hash: h2, size: "2.0 GiB", pubDate: "Mon, 23 Nov 2026 10:00:00 -0000", seeders: 50),
            (title: "FC2-PPV-12345.mp4", hash: h3, size: "1.5 GiB", pubDate: "Mon, 23 Nov 2026 10:00:00 -0000", seeders: 8),
            (title: "FC2-PPV-123456.mp4", hash: h4, size: "1.5 GiB", pubDate: "Mon, 23 Nov 2026 10:00:00 -0000", seeders: 80),
        ])

        RoutedURLProtocol.install { _ in .init(status: 200, body: Data(xml.utf8)) }
        let source = SukebeiSource(session: RoutedURLProtocol.session())

        let standard = try await source.fetchMagnets(code: "sone-456")
        XCTAssertEqual(standard.count, 1)
        XCTAssertTrue(standard[0].magnetURL.contains(h1))

        let fc2 = try await source.fetchMagnets(code: "FC2-PPV-12345")
        XCTAssertEqual(fc2.count, 1)
        XCTAssertTrue(fc2[0].magnetURL.contains(h3))
    }

    // MARK: - MagnetAggregator 合并、排序与容错

    func testMergeStudioPage1FiltersStaleReuploadsAndDeduplicates() {
        let jb = [
            MagnetSearchItem(code: "SONE-450", title: "JB 450", coverURL: nil, detailPath: "/SONE-450"),
            MagnetSearchItem(code: "SONE-440", title: "JB 440", coverURL: nil, detailPath: "/SONE-440"),
        ]
        let sb = [
            MagnetSearchItem(code: "SONE-455", title: "SB 455", coverURL: nil, detailPath: "/SONE-455", isFresh: true),
            MagnetSearchItem(code: "SONE-450", title: "SB 450 dup", coverURL: nil, detailPath: "/SONE-450", isFresh: true),
            MagnetSearchItem(code: "SONE-420", title: "SB 420 recent", coverURL: nil, detailPath: "/SONE-420", isFresh: true),
            MagnetSearchItem(code: "SONE-050", title: "SB 050 stale", coverURL: nil, detailPath: "/SONE-050", isFresh: true),
            MagnetSearchItem(code: "SNOS-010", title: "SB SNOS new prefix", coverURL: nil, detailPath: "/SNOS-010", isFresh: true),
        ]

        let merged = MagnetAggregator.mergeStudioPage1(javbus: jb, sukebei: sb)
        XCTAssertEqual(merged.map(\.code), ["SONE-455", "SONE-420", "SNOS-010", "SONE-450", "SONE-440"])
        XCTAssertEqual(merged.first(where: { $0.code == "SONE-450" })?.title, "JB 450")

        let jbEmpty = MagnetAggregator.mergeStudioPage1(javbus: [], sukebei: sb)
        XCTAssertEqual(jbEmpty.map(\.code), sb.map(\.code))
    }

    func testEnrichSukebeiShelfAndMergeSearchPage1() throws {
        let cover = try XCTUnwrap(URL(string: "https://pics.javbus.com/cover/sone456.jpg"))
        let star = MagnetStarItem(name: "演员甲", avatarURL: nil, detailPath: "/star/a")
        let torrent = MagnetTorrentItem(magnetURL: "magnet:?xt=urn:btih:\(String(repeating: "a", count: 40))", name: "t", size: "3 GiB", source: "Sukebei")

        let fresh = MagnetSearchItem(
            id: "/SONE-456",
            code: "SONE-456",
            title: "Sukebei Title",
            coverURL: nil,
            releaseDate: "2026-11-23",
            detailPath: "/SONE-456",
            isFresh: true,
            prefetchedMagnets: [torrent]
        )
        let rich = MagnetSearchItem(
            id: "/SONE-456-jb",
            code: "SONE-456",
            title: "JavBus Title",
            coverURL: cover,
            releaseDate: "2026-11-20",
            detailPath: "/SONE-456-jb",
            stars: [star]
        )
        let other = MagnetSearchItem(
            id: "/SONE-455-jb",
            code: "SONE-455",
            title: "Other",
            coverURL: nil,
            detailPath: "/SONE-455-jb"
        )

        let shelf = MagnetAggregator.enrichSukebeiShelf([fresh], with: [rich])
        XCTAssertEqual(shelf.count, 1)
        XCTAssertEqual(shelf[0].title, "JavBus Title")
        XCTAssertEqual(shelf[0].coverURL, cover)
        XCTAssertEqual(shelf[0].stars, [star])
        XCTAssertEqual(shelf[0].detailPath, "/SONE-456-jb")
        XCTAssertTrue(shelf[0].isFresh)
        XCTAssertEqual(shelf[0].prefetchedMagnets, [torrent])

        let searchMerged = MagnetAggregator.mergeSearchPage1(keyword: "sone-456", javbus: [other, rich], sukebei: [fresh])
        XCTAssertEqual(searchMerged.map(\.code), ["SONE-456", "SONE-455"])
    }

    func testMergeMagnetsDeduplicatesMergesMetadataAndSortsStrictly() {
        let hashSame = String(repeating: "a", count: 40)
        let hashHD = String(repeating: "b", count: 40)
        let hashOld = String(repeating: "c", count: 40)

        let jb = [
            MagnetTorrentItem(magnetURL: "magnet:?xt=urn:btih:\(hashSame.uppercased())&dn=jb", name: "a.mp4", size: "未知大小", date: nil, isHD: true, hasSubtitles: false, source: "JavBus"),
            MagnetTorrentItem(magnetURL: "magnet:?xt=urn:btih:\(hashOld)", name: "old.mp4", size: "1.0 GiB", date: "2026-10-01", isHD: true, hasSubtitles: false, source: "JavBus"),
        ]
        let sb = [
            MagnetTorrentItem(magnetURL: "magnet:?xt=urn:btih:\(hashSame)", name: "a-sub.mp4", size: "4.0 GiB", date: "2026-11-23", isHD: false, hasSubtitles: true, seeders: 25, source: "Sukebei"),
            MagnetTorrentItem(magnetURL: "magnet:?xt=urn:btih:\(hashHD)", name: "hd.mp4", size: "3.0 GiB", date: "2026-11-23", isHD: true, hasSubtitles: false, seeders: 60, source: "Sukebei"),
        ]

        let merged = MagnetAggregator.mergeMagnets(javbus: jb, sukebei: sb)
        XCTAssertEqual(merged.count, 3)

        XCTAssertTrue(merged[0].hasSubtitles)
        XCTAssertTrue(merged[0].isHD)
        XCTAssertEqual(merged[0].size, "4.0 GiB")
        XCTAssertEqual(merged[0].date, "2026-11-23")
        XCTAssertEqual(merged[0].seeders, 25)
        XCTAssertEqual(merged[0].source, "JavBus")

        XCTAssertTrue(merged[1].magnetURL.contains(hashHD))
        XCTAssertTrue(merged[2].magnetURL.contains(hashOld))
    }

    func testAggregatorFaultToleranceAcrossDetailStudioAndSearch() async throws {
        let h1 = String(repeating: "e", count: 40)
        let xml = rssDocument(items: [
            (title: "SONE-777 新片标题 1080p", hash: h1, size: "3.5 GiB", pubDate: "Mon, 23 Nov 2026 12:00:00 -0000", seeders: 15),
        ])

        // 1. Detail: JavBus 404 + Sukebei 200 -> 成功返回 Sukebei 磁力
        RoutedURLProtocol.install { request in
            if request.url?.host == "sukebei.nyaa.si" {
                return .init(status: 200, body: Data(xml.utf8))
            }
            return .init(status: 404)
        }
        let session = RoutedURLProtocol.session()
        let agg1 = MagnetAggregator(javbus: JavBusSource(session: session), sukebei: SukebeiSource(session: session), isSukebeiEnabled: { true })
        let item777 = MagnetSearchItem(code: "SONE-777", title: "t", coverURL: nil, detailPath: "/SONE-777")
        let detailFromSB = try await agg1.fetchDetailInfo(for: item777)
        XCTAssertTrue(detailFromSB.stars.isEmpty)
        XCTAssertEqual(detailFromSB.magnets.count, 1)
        XCTAssertEqual(detailFromSB.magnets[0].source, "Sukebei")

        // 2. Detail: JavBus 200 + Sukebei 500 -> 成功返回 JavBus
        let jbDetail = """
        <span class="genre"><a href="https://www.javbus.com/star/2js">三上悠亚</a></span>
        <table><tr><td><a href="magnet:?xt=urn:btih:\(String(repeating: "f", count: 40))">f.mp4</a></td><td>2.0GB</td><td>2026-11-20</td></tr></table>
        """
        RoutedURLProtocol.install { request in
            if request.url?.host == "sukebei.nyaa.si" {
                return .init(status: 500)
            }
            return .init(status: 200, body: Data(jbDetail.utf8))
        }
        let agg2 = MagnetAggregator(javbus: JavBusSource(session: session), sukebei: SukebeiSource(session: session), isSukebeiEnabled: { true })
        let detailFromJB = try await agg2.fetchDetailInfo(for: item777)
        XCTAssertEqual(detailFromJB.stars.map(\.name), ["三上悠亚"])
        XCTAssertEqual(detailFromJB.magnets.count, 1)
        XCTAssertEqual(detailFromJB.magnets[0].source, "JavBus")

        // 3. Detail: 双源均失败但有 prefetchedMagnets -> 返回预取磁力
        RoutedURLProtocol.install { _ in .init(status: 500) }
        let prefetched = MagnetTorrentItem(magnetURL: "magnet:?xt=urn:btih:\(h1)", name: "prefetched", size: "3.5 GiB", source: "Sukebei")
        let withPrefetch = MagnetSearchItem(code: "SONE-777", title: "t", coverURL: nil, detailPath: "/SONE-777", prefetchedMagnets: [prefetched])
        let agg3 = MagnetAggregator(javbus: JavBusSource(session: session), sukebei: SukebeiSource(session: session), isSukebeiEnabled: { true })
        let fromPrefetch = try await agg3.fetchDetailInfo(for: withPrefetch)
        XCTAssertEqual(fromPrefetch.magnets, [prefetched])

        // 4. Studio & Search: JavBus 500 + Sukebei 200 -> 容错返回 Sukebei
        RoutedURLProtocol.install { request in
            if request.url?.host == "sukebei.nyaa.si" {
                return .init(status: 200, body: Data(xml.utf8))
            }
            return .init(status: 500)
        }
        let agg4 = MagnetAggregator(javbus: JavBusSource(session: session), sukebei: SukebeiSource(session: session), isSukebeiEnabled: { true })
        let studioFallback = try await agg4.fetchStudio(.s1, page: 1)
        XCTAssertEqual(studioFallback.map(\.code), ["SONE-777"])
        let searchFallback = try await agg4.searchAll(keyword: "SONE-777", page: 1)
        XCTAssertEqual(searchFallback.movies.map(\.code), ["SONE-777"])
        XCTAssertTrue(searchFallback.stars.isEmpty)
    }

    // MARK: - 性能优化：并发去重、磁盘 SWR、非阻塞渐进返回与软超时

    func testInFlightDeduplicationDiskCacheForceRefreshAndSWR() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sukebei-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let clock = Clock()
        let hits = Counter()
        let xml1 = rssDocument(items: [
            (title: "SONE-201.mp4", hash: String(repeating: "a", count: 40), size: "2.0 GiB", pubDate: "Mon, 23 Nov 2026 10:00:00 -0000", seeders: 12),
        ])
        let xml2 = rssDocument(items: [
            (title: "SONE-202.mp4", hash: String(repeating: "b", count: 40), size: "2.5 GiB", pubDate: "Mon, 23 Nov 2026 11:00:00 -0000", seeders: 30),
        ])

        RoutedURLProtocol.install { _ in
            let n = hits.increment()
            Thread.sleep(forTimeInterval: 0.08)
            return .init(status: 200, body: Data((n == 1 ? xml1 : xml2).utf8))
        }

        let source = SukebeiSource(session: RoutedURLProtocol.session(), cacheLifetime: 180, cacheDirectory: dir, now: { clock.date })
        async let a = source.fetchLatest()
        async let b = source.fetchLatest()
        let (resA, resB) = try await (a, b)
        XCTAssertEqual(resA.map(\.code), ["SONE-201"])
        XCTAssertEqual(resB.map(\.code), ["SONE-201"])
        XCTAssertEqual(hits.value, 1, "并发同时请求同一 query 必须合并为一次 HTTP")

        // 超过内存与短时 TTL 后，新实例仍可同步从磁盘读取 SWR 缓存；forceRefresh 会跳过缓存
        clock.advance(300)
        let restarted = SukebeiSource(session: RoutedURLProtocol.session(), cacheLifetime: 180, cacheDirectory: dir, now: { clock.date })
        XCTAssertEqual(restarted.cachedLatest().map(\.code), ["SONE-201"], "重启后应能直接同步读取旧磁盘缓存")

        let refreshed = try await restarted.fetchLatest(forceRefresh: true)
        XCTAssertEqual(refreshed.map(\.code), ["SONE-202"])
        XCTAssertEqual(hits.value, 2)
    }

    @MainActor
    func testProgressiveAggregatorDeliversJavBusImmediatelyWithoutBlockingOnSlowSukebei() async throws {
        let jbStudioHTML = """
        <a class="movie-box" href="/SONE-100">
          <img src="https://pics.javbus.com/cover/100_b.jpg" title="片商首发作品">
          <date>SONE-100</date> / <date>2026-11-23</date>
        </a>
        """

        let jbHits = Counter()
        let sbHits = Counter()
        RoutedURLProtocol.install { request in
            if request.url?.host == "sukebei.nyaa.si" {
                _ = sbHits.increment()
                return .init(status: 500, delay: 2.0)
            }
            _ = jbHits.increment()
            return .init(status: 200, body: Data(jbStudioHTML.utf8))
        }

        let jbSession = RoutedURLProtocol.session()
        let sbSession = RoutedURLProtocol.session()
        defer {
            jbSession.invalidateAndCancel()
            sbSession.invalidateAndCancel()
        }
        let agg = MagnetAggregator(
            javbus: JavBusSource(session: jbSession),
            sukebei: SukebeiSource(session: sbSession),
            sukebeiSoftTimeout: 0.15,
            isSukebeiEnabled: { true }
        )

        var firstDeliveryElapsed: TimeInterval?
        let start = Date()
        let result = try await agg.loadStudioPage1(.s1) { partial in
            if firstDeliveryElapsed == nil {
                firstDeliveryElapsed = Date().timeIntervalSince(start)
            }
            XCTAssertEqual(partial.map(\.code), ["SONE-100"])
        }
        let totalElapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.map(\.code), ["SONE-100"])
        XCTAssertEqual(jbHits.value, 1)
        XCTAssertEqual(sbHits.value, 1)
        XCTAssertLessThan(firstDeliveryElapsed ?? 99, 0.12, "JavBus 结果应在卡慢的 Sukebei 之前立即交付 UI")
        XCTAssertLessThan(totalElapsed, 0.8, "超过 0.15s 软超时后应结束等待，不得阻塞满 2s")

        // 搜索与详情页同样不阻塞在慢速 Sukebei 上
        let jbDetailHTML = """
        <span class="genre"><a href="https://www.javbus.com/star/2js">三上悠亚</a></span>
        <table>
          <tr>
            <td><a href="magnet:?xt=urn:btih:\(String(repeating: "c", count: 40))">sone100.mp4</a></td>
            <td>2.40GB</td><td>2026-11-23</td>
          </tr>
        </table>
        """
        RoutedURLProtocol.install { request in
            if request.url?.host == "sukebei.nyaa.si" {
                return .init(status: 500, delay: 1.5)
            }
            if request.url?.path.hasPrefix("/search/") == true {
                return .init(status: 200, body: Data(jbStudioHTML.utf8))
            }
            return .init(status: 200, body: Data(jbDetailHTML.utf8))
        }
        let searchStart = Date()
        let searchResult = try await agg.searchAllProgressive(keyword: "SONE-100") { partial in
            XCTAssertEqual(partial.movies.map(\.code), ["SONE-100"])
        }
        XCTAssertEqual(searchResult.movies.map(\.code), ["SONE-100"])
        XCTAssertLessThan(Date().timeIntervalSince(searchStart), 0.5)

        let prefetched = MagnetTorrentItem(
            magnetURL: "magnet:?xt=urn:btih:\(String(repeating: "d", count: 40))",
            name: "prefetched",
            size: "4.1 GiB",
            source: "Sukebei"
        )
        let detailItem = MagnetSearchItem(
            code: "SONE-100",
            title: "t",
            coverURL: nil,
            detailPath: "/SONE-100",
            prefetchedMagnets: [prefetched]
        )
        let detailStart = Date()
        let detailResult = try await agg.loadDetailInfo(for: detailItem) { partial in
            XCTAssertEqual(partial.stars.map(\.name), ["三上悠亚"])
            XCTAssertEqual(partial.magnets.count, 2)
        }
        XCTAssertEqual(detailResult.magnets.count, 2)
        XCTAssertLessThan(Date().timeIntervalSince(detailStart), 0.5)
    }

    // MARK: - Sukebei 开关（默认关闭）

    func testSukebeiSettingsDefaultsToOffAndPersistsToggle() throws {
        let suiteName = "hplayer.sukebei.toggle.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(SukebeiSettings.isEnabled(in: defaults), "Sukebei 默认必须关闭")

        SukebeiSettings.setEnabled(true, in: defaults)
        XCTAssertTrue(SukebeiSettings.isEnabled(in: defaults))

        SukebeiSettings.setEnabled(false, in: defaults)
        XCTAssertFalse(SukebeiSettings.isEnabled(in: defaults))
    }

    @MainActor
    func testAggregatorSkipsAllSukebeiRequestsWhenDisabled() async throws {
        let jbHTML = """
        <a class="movie-box" href="/SONE-888">
          <img src="https://pics.javbus.com/cover/888_b.jpg" title="JavBus 影片">
          <date>SONE-888</date> / <date>2026-11-27</date>
        </a>
        """
        let jbDetailHTML = """
        <span class="genre"><a href="https://www.javbus.com/star/2js">三上悠亚</a></span>
        <table><tr><td><a href="magnet:?xt=urn:btih:\(String(repeating: "f", count: 40))">jb.mp4</a></td><td>2.0GB</td><td>2026-11-27</td></tr></table>
        """
        let sbXML = rssDocument(items: [
            (title: "SONE-999 Sukebei 新种", hash: String(repeating: "a", count: 40), size: "3.0 GiB", pubDate: "Fri, 27 Nov 2026 10:00:00 -0000", seeders: 99),
        ])

        let sbHits = Counter()
        let jbHits = Counter()
        RoutedURLProtocol.install { request in
            if request.url?.host == "sukebei.nyaa.si" {
                _ = sbHits.increment()
                return .init(status: 200, body: Data(sbXML.utf8))
            }
            _ = jbHits.increment()
            if request.url?.path == "/SONE-888" {
                return .init(status: 200, body: Data(jbDetailHTML.utf8))
            }
            return .init(status: 200, body: Data(jbHTML.utf8))
        }

        let session = RoutedURLProtocol.session()
        defer { session.invalidateAndCancel() }
        let sbSource = SukebeiSource(session: session)
        let agg = MagnetAggregator(
            javbus: JavBusSource(session: session),
            sukebei: sbSource,
            isSukebeiEnabled: { false }
        )

        XCTAssertFalse(agg.sukebeiEnabled)
        XCTAssertTrue(agg.cachedFreshLatest().isEmpty)
        let fresh = try await agg.fetchFreshLatest()
        XCTAssertTrue(fresh.isEmpty)
        XCTAssertEqual(sbHits.value, 0, "关闭 Sukebei 时不应请求 Sukebei 最新出种")

        let studio = try await agg.loadStudioPage1(.s1) { _ in }
        XCTAssertEqual(studio.map(\.code), ["SONE-888"])
        XCTAssertEqual(sbHits.value, 0, "关闭 Sukebei 时片商页不应请求 Sukebei")

        let search = try await agg.searchAllProgressive(keyword: "SONE-888") { _ in }
        XCTAssertEqual(search.movies.map(\.code), ["SONE-888"])
        XCTAssertEqual(sbHits.value, 0, "关闭 Sukebei 时搜索页不应请求 Sukebei")

        let prefetchedSB = MagnetTorrentItem(
            magnetURL: "magnet:?xt=urn:btih:\(String(repeating: "a", count: 40))",
            name: "sb.mp4",
            size: "3.0 GiB",
            source: "Sukebei"
        )
        let detailItem = MagnetSearchItem(
            code: "SONE-888",
            title: "JavBus 影片",
            coverURL: nil,
            detailPath: "/SONE-888",
            prefetchedMagnets: [prefetchedSB]
        )
        let detail = try await agg.loadDetailInfo(for: detailItem) { _ in }
        XCTAssertEqual(detail.stars.map(\.name), ["三上悠亚"])
        XCTAssertEqual(detail.magnets.count, 1)
        XCTAssertEqual(detail.magnets[0].source, "JavBus")
        XCTAssertEqual(sbHits.value, 0, "关闭 Sukebei 时详情页不应请求 Sukebei")
        XCTAssertGreaterThan(jbHits.value, 0)

        // 当 JavBus 失败且 Sukebei 关闭时，直接抛出 JavBus 错误而不回退请求 Sukebei
        RoutedURLProtocol.install { request in
            if request.url?.host == "sukebei.nyaa.si" {
                _ = sbHits.increment()
                return .init(status: 200, body: Data(sbXML.utf8))
            }
            return .init(status: 500)
        }
        do {
            _ = try await agg.fetchStudio(.s1, page: 1)
            XCTFail("关闭 Sukebei 且 JavBus 失败时应抛出错误")
        } catch {
            XCTAssertEqual(sbHits.value, 0)
            XCTAssertTrue(error.userMessage.contains("500"))
        }
    }

    // MARK: - 网络与连接报错中文提示

    func testNetworkErrorFormatterTranslatesSystemAndEngineErrorsToChinese() {
        let urlCases: [(URLError.Code, String)] = [
            (.timedOut, "超时"),
            (.notConnectedToInternet, "无网络连接"),
            (.networkConnectionLost, "中断"),
            (.cannotFindHost, "找不到服务器"),
            (.cannotConnectToHost, "无法连接到服务器"),
            (.dnsLookupFailed, "域名解析失败"),
            (.secureConnectionFailed, "安全连接"),
            (.serverCertificateUntrusted, "证书"),
            (.appTransportSecurityRequiresSecureConnection, "HTTPS"),
            (.badServerResponse, "服务器响应异常"),
            (.dataNotAllowed, "蜂窝网络"),
        ]
        for (code, expected) in urlCases {
            let msg = URLError(code).userMessage
            XCTAssertTrue(msg.contains(expected), "URLError(\(code)) 应翻译为中文并包含「\(expected)」，实际为：\(msg)")
        }

        // POSIX 错误
        XCTAssertTrue(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED)).userMessage.contains("拒绝连接"))
        XCTAssertTrue(NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT)).userMessage.contains("超时"))
        XCTAssertTrue(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET)).userMessage.contains("重置"))
        XCTAssertTrue(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)).userMessage.contains("存储空间不足"))

        // CFNetwork 代理/DNS 错误
        XCTAssertTrue(NSError(domain: "kCFErrorDomainCFNetwork", code: 310).userMessage.contains("代理"))
        XCTAssertTrue(NSError(domain: "kCFErrorDomainCFNetwork", code: 2).userMessage.contains("域名解析"))

        // NWError
        XCTAssertTrue(NWError.dns(0).userMessage.contains("域名解析"))
        XCTAssertTrue(NWError.tls(0).userMessage.contains("安全连接"))

        // WKError & AVFoundation 嵌套 URLError
        let wkJS = NSError(domain: WKErrorDomain, code: WKError.javaScriptExceptionOccurred.rawValue)
        XCTAssertTrue(wkJS.userMessage.contains("解析失败"))

        let wrappedAV = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.unknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: URLError(.timedOut) as NSError]
        )
        XCTAssertTrue(wrappedAV.userMessage.contains("超时"))

        // DecodingError
        let decodingErr = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "invalid json"))
        XCTAssertTrue(decodingErr.userMessage.contains("数据格式异常"))

        // NuvioEngineError
        XCTAssertTrue(NuvioEngineError(message: "NuvioEngine is closed").userMessage.contains("已关闭"))
        XCTAssertTrue(NuvioEngineError(message: "loopback preload ended before its target").userMessage.contains("中断"))

        // mpv / FFmpeg 播放内核英文错误
        XCTAssertTrue(NetworkErrorFormatter.translateMediaEngineMessage("loading failed").contains("加载失败"))
        XCTAssertTrue(NetworkErrorFormatter.translateMediaEngineMessage("[ffmpeg] error: Connection timed out").contains("超时"))
        XCTAssertTrue(NetworkErrorFormatter.translateMediaEngineMessage("HTTP error 403 Forbidden").contains("403"))
        XCTAssertTrue(NetworkErrorFormatter.translateMediaEngineMessage("Failed to resolve hostname example.com").contains("域名解析"))

        // DLNA SOAP 英文错误
        XCTAssertTrue(NetworkErrorFormatter.translateDLNAFault("Illegal MIME-type").contains("不支持"))
        XCTAssertTrue(NetworkErrorFormatter.translateDLNAFault("HTTP 500").contains("500"))

        // 业务错误包装底层网络错误
        XCTAssertTrue(JavBusError.network(URLError(.timedOut)).userMessage.contains("超时"))
        XCTAssertTrue(SukebeiError.network(URLError(.notConnectedToInternet)).userMessage.contains("无网络连接"))
        XCTAssertTrue(JableError.network(URLError(.cannotConnectToHost)).userMessage.contains("无法连接到服务器"))
        XCTAssertTrue(MissAVError.network(URLError(.networkConnectionLost)).userMessage.contains("中断"))
        XCTAssertTrue(AnimeTransportError.network(URLError(.dnsLookupFailed)).userMessage.contains("域名解析"))

        // LocalStreamProxy & RangeDownloader 中文错误描述
        XCTAssertTrue(LocalStreamProxy.summary(of: URLError(.timedOut)).contains("超时"))
        XCTAssertTrue(RangeDownloader.describe(URLError(.cannotFindHost) as NSError).contains("下载服务器"))
        XCTAssertTrue(RangeDownloader.describe(URLError(.appTransportSecurityRequiresSecureConnection) as NSError).contains("HTTPS"))

        // 英文原始文案转中文，中文原文保持不变
        XCTAssertTrue(APIError.server("The Internet connection appears to be offline.").userMessage.contains("无网络连接"))
        XCTAssertEqual(APIError.server("自定义中文提示").userMessage, "自定义中文提示")
    }

    // MARK: - 辅助

    private func rssDocument(items: [(title: String, hash: String, size: String, pubDate: String, seeders: Int)]) -> String {
        let body = items.map { item in
            """
            <item>
              <title>\(item.title)</title>
              <pubDate>\(item.pubDate)</pubDate>
              <nyaa:seeders>\(item.seeders)</nyaa:seeders>
              <nyaa:leechers>2</nyaa:leechers>
              <nyaa:infoHash>\(item.hash)</nyaa:infoHash>
              <nyaa:categoryId>2_2</nyaa:categoryId>
              <nyaa:size>\(item.size)</nyaa:size>
            </item>
            """
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss xmlns:nyaa="https://sukebei.nyaa.si/xmlns/nyaa" version="2.0">
          <channel>\(body)</channel>
        </rss>
        """
    }
}
