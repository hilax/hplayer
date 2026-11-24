import XCTest
@testable import HPlayer

final class MagnetStarNamesTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var codes: [String] = []
        func add(_ code: String) { lock.lock(); codes.append(code); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return codes }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000_000)
        var date: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
    }

    private func movie(_ code: String) -> MagnetSearchItem {
        MagnetSearchItem(code: code, title: code, coverURL: nil, detailPath: "/\(code)")
    }

    func testFoundNamesAreLookedUpOnceAndReadableSynchronously() async {
        let calls = Calls()
        let store = MagnetStarNames(startInterval: 0, lookup: { item in
            calls.add(item.code)
            return .found(["河北彩花", "河北彩花 ", "三上悠亜"])
        })
        let first = await store.names(for: movie("SSIS-888"))
        let second = await store.names(for: movie("ssis-888"))
        XCTAssertEqual(first, ["河北彩花", "三上悠亜"], "Duplicate spellings collapse into one name")
        XCTAssertEqual(second, first)
        XCTAssertEqual(calls.all, ["SSIS-888"], "The same code is looked up once, whatever its case")
        XCTAssertEqual(store.cachedNames(for: movie("SSIS-888")), ["河北彩花", "三上悠亜"],
                       "Cards read known names on their first frame")
    }

    func testTitlesWithoutPerformersAreRememberedForADay() async {
        let calls = Calls()
        let clock = Clock()
        let store = MagnetStarNames(now: { clock.date }, startInterval: 0, lookup: { item in
            calls.add(item.code)
            return .none
        })
        let first = await store.names(for: movie("FC2-123456"))
        let again = await store.names(for: movie("FC2-123456"))
        XCTAssertEqual(first, [])
        XCTAssertEqual(again, [])
        XCTAssertEqual(calls.all.count, 1)
        XCTAssertEqual(store.cachedNames(for: movie("FC2-123456")), [])

        clock.advance(MagnetStarNames.noneLifetime + 1)
        _ = await store.names(for: movie("FC2-123456"))
        XCTAssertEqual(calls.all.count, 2, "Freshly listed titles get their cast filled in later, so a miss expires")
    }

    func testFailuresAreRetriedAfterAShortWhile() async {
        let calls = Calls()
        let clock = Clock()
        let store = MagnetStarNames(now: { clock.date }, startInterval: 0, lookup: { item in
            calls.add(item.code)
            return .unavailable
        })
        let first = await store.names(for: movie("ABF-159"))
        let again = await store.names(for: movie("ABF-159"))
        XCTAssertNil(first)
        XCTAssertNil(again)
        XCTAssertEqual(calls.all.count, 1, "A failure is not retried on every scroll")
        XCTAssertNil(store.cachedNames(for: movie("ABF-159")), "A failure is not the same as having no performers")

        clock.advance(MagnetStarNames.failureLifetime + 1)
        _ = await store.names(for: movie("ABF-159"))
        XCTAssertEqual(calls.all.count, 2)
    }

    func testBlockedSourcePausesLookups() async {
        let calls = Calls()
        let clock = Clock()
        let store = MagnetStarNames(now: { clock.date }, startInterval: 0, lookup: { item in
            calls.add(item.code)
            return .blocked
        })
        _ = await store.names(for: movie("SONE-001"))
        let other = await store.names(for: movie("SONE-002"))
        XCTAssertNil(other)
        XCTAssertEqual(calls.all, ["SONE-001"], "After Cloudflare blocks a request, nothing else is sent for a while")

        clock.advance(MagnetStarNames.blockedPause + 1)
        _ = await store.names(for: movie("SONE-002"))
        XCTAssertEqual(calls.all, ["SONE-001", "SONE-002"])
    }

    func testConcurrentRequestsShareOneLookup() async {
        let calls = Calls()
        let store = MagnetStarNames(startInterval: 0, lookup: { item in
            calls.add(item.code)
            try? await Task.sleep(nanoseconds: 100_000_000)
            return .found(["楓カレン"])
        })
        async let one = store.names(for: movie("IPX-100"))
        async let two = store.names(for: movie("IPX-100"))
        let results = await [one, two]
        XCTAssertEqual(results, [["楓カレン"], ["楓カレン"]])
        XCTAssertEqual(calls.all.count, 1)
    }

    func testRecordedNamesSkipTheLookup() async {
        let calls = Calls()
        let store = MagnetStarNames(startInterval: 0, lookup: { item in
            calls.add(item.code)
            return .found(["别人"])
        })
        await store.record(["美谷朱里"], for: movie("MIDV-500"))
        let names = await store.names(for: movie("MIDV-500"))
        XCTAssertEqual(names, ["美谷朱里"])
        XCTAssertTrue(calls.all.isEmpty, "Names seen on the detail page are reused by the list cards")
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testPrefetchFillsTheCacheWithoutAWaitingCard() async {
        let calls = Calls()
        let store = MagnetStarNames(startInterval: 0, lookup: { item in
            calls.add(item.code)
            return .found(["名字 \(item.code)"])
        })
        await store.prefetch([movie("PRE-001"), movie("PRE-002")])
        await waitUntil { calls.all.count == 2 }
        await waitUntil { store.cachedNames(for: movie("PRE-002")) != nil }
        XCTAssertEqual(Set(calls.all), ["PRE-001", "PRE-002"])
        XCTAssertEqual(store.cachedNames(for: movie("PRE-001")), ["名字 PRE-001"],
                       "A card scrolled into view later reads the name on its first frame")
    }

    func testIdlePrefetchKeepsOnlyTheMostRecentBatch() async {
        let calls = Calls()
        let store = MagnetStarNames(startInterval: 0, lookup: { item in
            calls.add(item.code)
            return .none
        })
        let items = (0 ..< 20).map { movie(String(format: "IDL-%03d", $0)) }
        await store.prefetch(items)
        await waitUntil { calls.all.count >= MagnetStarNames.maxIdlePrefetch }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(calls.all.count, MagnetStarNames.maxIdlePrefetch,
                       "Prefetches nobody waits for are capped so a fast fling does not flood the site")
        XCTAssertFalse(calls.all.contains("IDL-000"), "The oldest prefetches (already scrolled past) are dropped")
        XCTAssertTrue(calls.all.contains("IDL-019"))
    }

    func testDiskCachePersistsAcrossInstances() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("star-names-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let writer = MagnetStarNames(cacheFile: file, startInterval: 0, lookup: { _ in .found(["石川澪"]) })
        _ = await writer.names(for: movie("MIDV-018"))
        await writer.flush()

        let calls = Calls()
        let reader = MagnetStarNames(cacheFile: file, startInterval: 0, lookup: { item in
            calls.add(item.code)
            return .found(["别人"])
        })
        XCTAssertEqual(reader.cachedNames(for: movie("MIDV-018")), ["石川澪"])
        let names = await reader.names(for: movie("MIDV-018"))
        XCTAssertEqual(names, ["石川澪"])
        XCTAssertTrue(calls.all.isEmpty)
    }

    func testDisplayListsTwoNamesAndDropsAliases() {
        XCTAssertEqual(MagnetStarNames.display(["森沢かな（飯岡かなこ）"]), "森沢かな")
        XCTAssertEqual(MagnetStarNames.display(["A", "B"]), "A、B")
        XCTAssertEqual(MagnetStarNames.display(["A", "B", "C"]), "A、B 等")
        XCTAssertEqual(MagnetStarNames.display(["A", "B", "C"], limit: 1), "A 等")
        XCTAssertNil(MagnetStarNames.display([]))
    }

    func testFreshnessIsCountedInUTCDays() throws {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 11
        components.day = 24
        components.hour = 10
        let now = try XCTUnwrap(components.date)

        XCTAssertEqual(MagnetDates.freshness("2026-11-24", now: now)?.label, "今天")
        XCTAssertEqual(MagnetDates.freshness("2026-11-24", now: now)?.isToday, true)
        XCTAssertEqual(MagnetDates.freshness("2026-11-23", now: now)?.label, "昨天")
        XCTAssertEqual(MagnetDates.freshness("2026-11-21", now: now)?.label, "3 天前")
        XCTAssertEqual(MagnetDates.freshness("2026-11-10", now: now)?.label, "11-10")
        XCTAssertNil(MagnetDates.freshness(nil, now: now))
        XCTAssertEqual(MagnetDates.short("2025-03-02", now: now), "2025-03-02")
    }

    func testFreshSummaryPrefersUHDAndMostSeeders() {
        let item = MagnetSearchItem(
            code: "SONE-456",
            title: "SONE-456",
            coverURL: nil,
            releaseDate: "2026-11-24",
            detailPath: "/SONE-456",
            isFresh: true,
            prefetchedMagnets: [
                MagnetTorrentItem(magnetURL: "magnet:?xt=urn:btih:aaaa", name: "SONE-456-C 1080p", size: "5.2 GiB",
                                  date: "2026-11-24", isHD: true, hasSubtitles: true, seeders: 12, source: "Sukebei"),
                MagnetTorrentItem(magnetURL: "magnet:?xt=urn:btih:bbbb", name: "SONE-456 4K", size: "18 GiB",
                                  date: "2026-11-24", isHD: true, hasSubtitles: false, seeders: 40, source: "Sukebei"),
            ]
        )
        let summary = MagnetFreshSummary(item)
        XCTAssertTrue(summary.hasSubtitles)
        XCTAssertEqual(summary.quality, "4K")
        XCTAssertEqual(summary.seeders, 40)
        XCTAssertEqual(summary.size, "5.2 GiB")
    }
}
