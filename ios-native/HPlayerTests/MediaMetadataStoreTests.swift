import XCTest
import CryptoKit
@testable import HPlayer

@MainActor
final class MediaMetadataStoreTests: XCTestCase {
    func testSavedSessionAndAccountAreAvailableBeforeAnyTaskRuns() {
        let restored = AppState(cookieLoader: { "UID=12345_99; CID=local-session" })
        XCTAssertTrue(restored.isAuthenticated)
        XCTAssertFalse(restored.isLoading)
        XCTAssertEqual(restored.libraryAccountID, "device:12345")
        XCTAssertFalse(AppState(cookieLoader: { nil }).isAuthenticated)
        XCTAssertFalse(AppState(cookieLoader: { " \n" }).isAuthenticated)
        XCTAssertNil(AppState.accountID(in: "UID=not-an-account; CID=local-session"))
    }

    func testDifferentCodesWithTheSameCleanedTitleKeepSeparateCovers() async throws {
        let (defaults, suite) = makeDefaults()
        UserDefaults.standard.set(true, forKey: AdultMetadataSettings.enabledKey)
        defer {
            defaults.removePersistentDomain(forName: suite)
            UserDefaults.standard.removeObject(forKey: AdultMetadataSettings.enabledKey)
        }
        let first = LibraryMedia(cloud: P115File(id: "a", parentId: "0", name: "[ABC-123] Same.Name.mp4",
            isDir: false, kind: "video", size: 10, pickCode: "a", sha1: "", updatedAt: "", thumbUrl: ""))
        let second = LibraryMedia(cloud: P115File(id: "b", parentId: "0", name: "[DEF-456] Same.Name.mp4",
            isDir: false, kind: "video", size: 10, pickCode: "b", sha1: "", updatedAt: "", thumbUrl: ""))
        let store = MediaMetadataStore(defaults: defaults, lookup: { parsed in
            guard let code = parsed.catalogCode else { return nil }
            var result = MediaMetadata(imdbID: "r18dev:\(code)", type: "movie", title: code, year: "",
                posterURL: "https://images.example/\(code).jpg", backgroundURL: "", logoURL: "", overview: "",
                rating: "", genres: [], country: "Japan", season: nil, episode: nil)
            result.source = MetadataSource.r18dev.rawValue
            return result
        })
        store.sync(files: [first, second])
        try await waitForScan(store)
        XCTAssertEqual(store.metadataByMediaID[first.id]?.imdbID, "r18dev:ABC-123")
        XCTAssertEqual(store.metadataByMediaID[second.id]?.imdbID, "r18dev:DEF-456")

        let restored = MediaMetadataStore(defaults: defaults, lookup: { _ in XCTFail("Cached codes should restore"); return nil })
        restored.hydrate(files: [first, second])
        XCTAssertEqual(restored.metadataByMediaID[first.id]?.imdbID, "r18dev:ABC-123")
        XCTAssertEqual(restored.metadataByMediaID[second.id]?.imdbID, "r18dev:DEF-456")
    }

    func testSavedSessionUsesHistoricalMediaLibraryAccountScope() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = P115File(id: "old", parentId: "0", name: "Saved.mkv", isDir: false,
            kind: "video", size: 100, pickCode: "saved", sha1: "", updatedAt: "", thumbUrl: "")
        defaults.set(try JSONEncoder().encode(["device:12345": [file]]), forKey: "hplayer.posterLibrary.cloud.v1")
        let restored = AppState(cookieLoader: { "UID=12345_99; CID=local-session" })
        XCTAssertEqual(MediaLibraryStore(defaults: defaults).files(for: restored), [file])
    }

    func testColdHydrationRestoresHashAndTitleCoversWithoutLookup() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = cloud(name: "凡人修仙传.S01E01.2160p.mkv", pickCode: "first")
        let seed = MediaMetadataStore(defaults: defaults, lookup: { _ in nil })
        await seed.match(seriesMetadata(), to: original)

        let lookup = MetadataLookupStub(responses: [])
        let restored = MediaMetadataStore(defaults: defaults, lookup: { _ in await lookup.lookup() })
        let renamed = cloud(name: "Renamed.Release.S01E07.mkv", pickCode: "renamed")
        // 没有视频内容可读，但片名缓存足以在首帧恢复本地文件的封面。
        let local = LibraryMedia(local: LocalMedia(
            url: URL(fileURLWithPath: "/not-a-real-video/凡人修仙传.S01E04.mkv"),
            size: 12 * 1024 * 1024 * 1024, modified: .distantPast
        ))
        restored.hydrate(files: [renamed, local])

        XCTAssertEqual(restored.metadataByMediaID[renamed.id]?.imdbID, "bgm:凡人")
        XCTAssertEqual(restored.metadataByMediaID[renamed.id]?.episode, 7)
        XCTAssertEqual(restored.metadataByMediaID[renamed.id]?.matchedByHash, true)
        XCTAssertEqual(restored.metadataByMediaID[local.id]?.episode, 4)
        XCTAssertEqual(restored.metadataByMediaID[local.id]?.manual, true)
        XCTAssertFalse(restored.isMatching)
        XCTAssertEqual(restored.completedScanCount, 0)
        restored.sync(files: [renamed, local])
        XCTAssertFalse(restored.isMatching)
        XCTAssertEqual(restored.completedScanCount, 1)
        let calls = await lookup.calls
        XCTAssertEqual(calls, 0)
    }

    func testExplicitRetryBypassesMissButPreservesManualUnmatch() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let lookup = MetadataLookupStub(responses: [nil, seriesMetadata()])
        let store = MediaMetadataStore(defaults: defaults, lookup: { _ in await lookup.lookup() })
        let file = cloud(name: "凡人修仙传.S01E02.mkv", pickCode: "retry")
        store.sync(files: [file])
        try await waitForScan(store)
        let firstCalls = await lookup.calls
        XCTAssertEqual(firstCalls, 1)
        XCTAssertNil(store.metadataByMediaID[file.id])

        store.sync(files: [file])
        let throttledCalls = await lookup.calls
        XCTAssertEqual(throttledCalls, 1, "Background refresh must keep the 12-hour miss throttle")
        store.retryFailed(files: [file])
        try await waitForScan(store)
        let retriedCalls = await lookup.calls
        XCTAssertEqual(retriedCalls, 2)
        XCTAssertEqual(store.metadataByMediaID[file.id]?.imdbID, "bgm:凡人")
        XCTAssertNotNil(store.lastCompletedAt)

        await store.unmatch(file)
        store.retryFailed(files: [file])
        try await waitForScan(store)
        let ignoredCalls = await lookup.calls
        XCTAssertEqual(ignoredCalls, 2, "An intentional unmatch must survive a manual rescan")
        let restarted = MediaMetadataStore(defaults: defaults, lookup: { _ in XCTFail("Ignored files must not be searched"); return nil })
        restarted.hydrate(files: [file])
        XCTAssertNil(restarted.metadataByMediaID[file.id])
    }

    func testUnchangedLocalFileRestoresByMemoizedHashAndChangedFileDoesNot() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Unrelated.Renamed.File.mkv")
        let data = Data(repeating: 0x5A, count: 2 * 1024 * 1024 + 1)
        try data.write(to: url)
        let hash = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let original = LibraryMedia(cloud: P115File(id: "seed", parentId: "0", name: "凡人修仙传.S01E01.mkv",
            isDir: false, kind: "video", size: data.count, pickCode: "seed", sha1: hash, updatedAt: "", thumbUrl: ""))
        let local = LibraryMedia(local: LocalMedia(url: url, size: data.count, modified: .distantPast))
        let lookup = MetadataLookupStub(responses: [])
        let seed = MediaMetadataStore(defaults: defaults, lookup: { _ in await lookup.lookup() })
        await seed.match(seriesMetadata(), to: original)
        seed.sync(files: [local])
        try await waitForScan(seed)
        XCTAssertEqual(seed.metadataByMediaID[local.id]?.matchedByHash, true)

        let restored = MediaMetadataStore(defaults: defaults, lookup: { _ in await lookup.lookup() })
        restored.hydrate(files: [local])
        XCTAssertEqual(restored.metadataByMediaID[local.id]?.imdbID, "bgm:凡人")
        let calls = await lookup.calls
        XCTAssertEqual(calls, 0)

        try Data([0x11]).write(to: url)
        let changed = LibraryMedia(local: LocalMedia(url: url, size: 1, modified: Date()))
        restored.hydrate(files: [changed])
        XCTAssertNil(restored.metadataByMediaID[changed.id], "A changed local file must not reuse its old SHA1 mapping")
    }

    func testRetryDuringLookupQueuesNextAttemptWithoutConcurrentRequests() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let lookup = MetadataLookupStub(responses: [nil, seriesMetadata()], pauseFirst: true)
        let store = MediaMetadataStore(defaults: defaults, lookup: { _ in await lookup.lookup() })
        let file = cloud(name: "凡人修仙传.S01E02.mkv", pickCode: "serial")
        store.sync(files: [file])
        for _ in 0..<200 {
            if await lookup.calls > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        store.retryFailed(files: [file])
        await Task.yield()
        let callsWhileWaiting = await lookup.calls
        XCTAssertEqual(callsWhileWaiting, 1)
        await lookup.releaseFirst()
        try await waitForScan(store)
        let calls = await lookup.calls
        let maxConcurrent = await lookup.maximumConcurrent
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(maxConcurrent, 1)
        XCTAssertEqual(store.metadataByMediaID[file.id]?.imdbID, "bgm:凡人")
    }

    func testManualMatchWinsOverAnAlreadyRunningAutomaticLookup() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let lookup = MetadataLookupStub(responses: [seriesMetadata()], pauseFirst: true)
        let store = MediaMetadataStore(defaults: defaults, lookup: { _ in await lookup.lookup() })
        let file = cloud(name: "凡人修仙传.S01E02.mkv", pickCode: "manual")
        store.sync(files: [file])
        for _ in 0..<200 {
            if await lookup.calls > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        var chosen = seriesMetadata()
        chosen.source = MetadataSource.tmdb.rawValue
        await store.match(chosen, to: file)
        await lookup.releaseFirst()
        try await waitForScan(store)
        XCTAssertEqual(store.metadataByMediaID[file.id]?.sourceKind, .tmdb)
        XCTAssertEqual(store.metadataByMediaID[file.id]?.manual, true)
    }

    func testAutomaticResultWithoutUsablePosterCanBeRetried() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let lookup = MetadataLookupStub(responses: [seriesMetadata(posterURL: ""), seriesMetadata()])
        let store = MediaMetadataStore(defaults: defaults, lookup: { _ in await lookup.lookup() })
        let file = cloud(name: "凡人修仙传.S01E02.mkv", pickCode: "posterless")
        store.sync(files: [file])
        try await waitForScan(store)
        XCTAssertNil(store.metadataByMediaID[file.id], "An exact title without artwork must not count as a successful poster match")
        store.retryFailed(files: [file])
        try await waitForScan(store)
        XCTAssertEqual(store.metadataByMediaID[file.id]?.hasUsablePoster, true)
        let calls = await lookup.calls
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(seriesMetadata(posterURL: "file:///poster.jpg").hasUsablePoster)
        XCTAssertFalse(seriesMetadata(posterURL: "/poster.jpg").hasUsablePoster)
        XCTAssertFalse(seriesMetadata(posterURL: " \n").hasUsablePoster)
    }

    func testPosterlessManualChoicePersistsWithoutAutomaticReplacement() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = cloud(name: "凡人修仙传.S01E02.mkv", pickCode: "manual-empty")
        let store = MediaMetadataStore(defaults: defaults, lookup: { _ in nil })
        await store.match(seriesMetadata(posterURL: ""), to: file)
        let restored = MediaMetadataStore(defaults: defaults, lookup: { _ in XCTFail("A manual choice must not be replaced"); return nil })
        restored.sync(files: [file])
        XCTAssertEqual(restored.metadataByMediaID[file.id]?.manual, true)
        XCTAssertEqual(restored.metadataByMediaID[file.id]?.hasUsablePoster, false)
        XCTAssertFalse(restored.isMatching)
    }

    func testOldPosterlessAutomaticCacheDoesNotPreventNewMatching() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        struct OldCache: Encodable {
            let hash: [String: MediaMetadata]
            let title: [String: MediaMetadata]
        }
        let old = seriesMetadata(posterURL: "")
        let cache = OldCache(hash: ["sha1:\(String(repeating: "a", count: 40))": old],
                             title: ["凡人修仙传||series": old])
        defaults.set(try JSONEncoder().encode(cache), forKey: "hplayer.mediaMetadata.v3")
        let lookup = MetadataLookupStub(responses: [seriesMetadata()])
        let store = MediaMetadataStore(defaults: defaults, lookup: { _ in await lookup.lookup() })
        let file = cloud(name: "凡人修仙传.S01E02.mkv", pickCode: "old-empty")
        store.hydrate(files: [file])
        XCTAssertNil(store.metadataByMediaID[file.id])
        store.sync(files: [file])
        try await waitForScan(store)
        XCTAssertEqual(store.metadataByMediaID[file.id]?.hasUsablePoster, true)
        let calls = await lookup.calls
        XCTAssertEqual(calls, 1)
    }

    func testPauseRejectsLateSuccessAndMissWithoutBlockingResume() async throws {
        for lateResponse in [nil, seriesMetadata()] as [MediaMetadata?] {
            let (defaults, suite) = makeDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            let lookup = MetadataLookupStub(responses: [lateResponse, seriesMetadata()], pauseFirst: true)
            let store = MediaMetadataStore(defaults: defaults, lookup: { _ in await lookup.lookup() })
            let file = cloud(name: "凡人修仙传.S01E02.mkv", pickCode: "pause")
            store.sync(files: [file])
            for _ in 0..<200 {
                if await lookup.calls > 0 { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            store.pause()
            XCTAssertFalse(store.isMatching)
            XCTAssertTrue(store.resolvingIDs.isEmpty)
            XCTAssertEqual(store.completedScanCount, 0)
            await lookup.releaseFirst()
            for _ in 0..<200 {
                if await lookup.active == 0 { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            await Task.yield()
            XCTAssertNil(store.metadataByMediaID[file.id], "A cancelled lookup must not publish its late result")
            store.sync(files: [file])
            try await waitForScan(store)
            let calls = await lookup.calls
            XCTAssertEqual(calls, 2, "A cancelled miss must not reinstate the 12-hour throttle")
            XCTAssertEqual(store.metadataByMediaID[file.id]?.hasUsablePoster, true)
        }
    }

    // MARK: 演员资料补全

    func testManualPerformerRequestWaitsForCoverMatching() async throws {
        let (defaults, suite) = makeDefaults()
        UserDefaults.standard.set(true, forKey: AdultMetadataSettings.enabledKey)
        defer {
            defaults.removePersistentDomain(forName: suite)
            UserDefaults.standard.removeObject(forKey: AdultMetadataSettings.enabledKey)
        }
        let cover = MetadataLookupStub(responses: [makeR18Match("ABC-123")], pauseFirst: true)
        let performers = PerformerLookupStub(results: ["ABC-123": .found(["演员甲"])])
        let file = codedFile("ABC-123")
        let store = MediaMetadataStore(defaults: defaults, performerLookup: { code, id in await performers.lookup(code, id) },
                                       lookup: { _ in await cover.lookup() })
        store.sync(files: [file])
        for _ in 0..<200 {
            if await cover.calls > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        store.startPerformerEnrichment(force: true)
        XCTAssertEqual(store.performerEnrichmentState, .waiting)
        await cover.releaseFirst()
        try await waitForScan(store)
        try await waitForEnrichment(store)
        XCTAssertEqual(store.performerEnrichmentState, .completed)
        XCTAssertEqual(store.performerEnrichmentProcessed, 1)
        XCTAssertEqual(store.performerEnrichmentTotal, 1)
        XCTAssertEqual(store.metadataByMediaID[file.id]?.performers, ["演员甲"])
    }

    func testStoppingQueuedPerformerRequestDoesNotStopCoverMatching() async throws {
        let (defaults, suite) = makeDefaults()
        UserDefaults.standard.set(true, forKey: AdultMetadataSettings.enabledKey)
        defer {
            defaults.removePersistentDomain(forName: suite)
            UserDefaults.standard.removeObject(forKey: AdultMetadataSettings.enabledKey)
        }
        let cover = MetadataLookupStub(responses: [makeR18Match("ABC-123")], pauseFirst: true)
        let performers = PerformerLookupStub(results: ["ABC-123": .found(["演员甲"])])
        let file = codedFile("ABC-123")
        let store = MediaMetadataStore(defaults: defaults, performerLookup: { code, id in await performers.lookup(code, id) },
                                       lookup: { _ in await cover.lookup() })
        store.sync(files: [file])
        for _ in 0..<200 {
            if await cover.calls > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        store.startPerformerEnrichment(force: true)
        store.stopPerformerEnrichment()
        XCTAssertEqual(store.performerEnrichmentState, .stopped)
        XCTAssertTrue(store.isMatching)
        await cover.releaseFirst()
        try await waitForScan(store)
        XCTAssertNotNil(store.metadataByMediaID[file.id])
        let calls = await performers.calls.count
        XCTAssertEqual(calls, 0)
        store.startPerformerEnrichment(force: true)
        try await waitForEnrichment(store)
        XCTAssertEqual(store.metadataByMediaID[file.id]?.performers, ["演员甲"])
    }

    func testBackgroundPassFillsPerformersForCoverOnlyMatchesAndRemembersThem() async throws {
        let (defaults, suite) = makeDefaults()
        UserDefaults.standard.set(true, forKey: AdultMetadataSettings.enabledKey)
        defer {
            defaults.removePersistentDomain(forName: suite)
            UserDefaults.standard.removeObject(forKey: AdultMetadataSettings.enabledKey)
        }
        let stub = PerformerLookupStub(results: ["ABC-123": .found(["演员甲"]), "DEF-456": .none])
        let files = [codedFile("ABC-123"), codedFile("DEF-456")]
        let store = MediaMetadataStore(defaults: defaults, performerLookup: { code, contentID in await stub.lookup(code, contentID) },
                                       lookup: { parsed in parsed.catalogCode.map(makeR18Match) })
        store.sync(files: files)
        try await waitForScan(store)
        try await waitForEnrichment(store)
        XCTAssertEqual(store.metadataByMediaID[files[0].id]?.performers, ["演员甲"])
        XCTAssertNil(store.metadataByMediaID[files[1].id]?.performers)
        XCTAssertEqual(store.performerCoverage().total, 2)
        XCTAssertEqual(store.performerCoverage().withPerformers, 1)
        let calls = await stub.calls
        XCTAssertEqual(calls.map(\.code), ["ABC-123", "DEF-456"])
        XCTAssertEqual(calls.first?.contentID, "cidabc123", "The content_id remembered at match time saves a request")

        // 重启后演员名随缓存恢复；已确认查不到的番号 30 天内不再问。
        let restored = MediaMetadataStore(defaults: defaults, performerLookup: { code, contentID in await stub.lookup(code, contentID) },
                                          lookup: { _ in XCTFail("Cached codes should restore"); return nil })
        restored.sync(files: files)
        XCTAssertEqual(restored.metadataByMediaID[files[0].id]?.performers, ["演员甲"])
        XCTAssertFalse(restored.isEnrichingPerformers)
        let afterRestart = await stub.calls.count
        XCTAssertEqual(afterRestart, 2)

        // 用户主动点「补全演员资料」会重新问一遍没查到的。
        restored.startPerformerEnrichment(force: true)
        try await waitForEnrichment(restored)
        let afterForce = await stub.calls.count
        XCTAssertEqual(afterForce, 3)
    }

    func testBackgroundPassGivesUpAfterThreeNetworkFailuresAndSkipsFailedCodesForAnHour() async throws {
        let (defaults, suite) = makeDefaults()
        UserDefaults.standard.set(true, forKey: AdultMetadataSettings.enabledKey)
        defer {
            defaults.removePersistentDomain(forName: suite)
            UserDefaults.standard.removeObject(forKey: AdultMetadataSettings.enabledKey)
        }
        let stub = PerformerLookupStub(results: [:], fallback: .unavailable)
        let files = (1...5).map { codedFile("ABC-00\($0)") }
        let store = MediaMetadataStore(defaults: defaults, performerLookup: { code, contentID in await stub.lookup(code, contentID) },
                                       lookup: { parsed in parsed.catalogCode.map(makeR18Match) })
        store.sync(files: files)
        try await waitForScan(store)
        try await waitForEnrichment(store)
        let first = await stub.calls.map(\.code)
        XCTAssertEqual(first, ["ABC-001", "ABC-002", "ABC-003"])
        XCTAssertEqual(store.performerEnrichmentState, .failed)
        XCTAssertEqual(store.performerEnrichmentProcessed, 3)
        XCTAssertEqual(store.performerEnrichmentTotal, 5)
        XCTAssertEqual(store.performerEnrichmentFailures, 3)

        store.startPerformerEnrichment()
        try await waitForEnrichment(store)
        let second = await stub.calls.map(\.code)
        XCTAssertEqual(second, ["ABC-001", "ABC-002", "ABC-003", "ABC-004", "ABC-005"], "Codes that just failed are not asked again")
    }

    func testStoppingCancelsTheBackgroundPassAndDropsLateResults() async throws {
        let (defaults, suite) = makeDefaults()
        UserDefaults.standard.set(true, forKey: AdultMetadataSettings.enabledKey)
        defer {
            defaults.removePersistentDomain(forName: suite)
            UserDefaults.standard.removeObject(forKey: AdultMetadataSettings.enabledKey)
        }
        let stub = PerformerLookupStub(results: ["ABC-123": .found(["演员甲"])], pauseFirst: true)
        let file = codedFile("ABC-123")
        let store = MediaMetadataStore(defaults: defaults, performerLookup: { code, contentID in await stub.lookup(code, contentID) },
                                       lookup: { parsed in parsed.catalogCode.map(makeR18Match) })
        store.sync(files: [file])
        try await waitForScan(store)
        XCTAssertTrue(store.isEnrichingPerformers)
        for _ in 0..<200 {
            if await stub.calls.count > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        store.stopByUser()
        XCTAssertFalse(store.isEnrichingPerformers)
        await stub.releaseFirst()
        for _ in 0..<200 {
            if await stub.active == 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await Task.yield()
        XCTAssertNil(store.metadataByMediaID[file.id]?.performers, "A result that arrives after stopping must not be written")
        store.startPerformerEnrichment()
        XCTAssertFalse(store.isEnrichingPerformers, "A user stop also keeps the automatic pass from restarting")
    }

    func testPassOnlyConsidersCodedMatchesWithoutPerformers() async throws {
        let (defaults, suite) = makeDefaults()
        UserDefaults.standard.set(true, forKey: AdultMetadataSettings.enabledKey)
        defer {
            defaults.removePersistentDomain(forName: suite)
            UserDefaults.standard.removeObject(forKey: AdultMetadataSettings.enabledKey)
        }
        let store = MediaMetadataStore(defaults: defaults, performerLookup: { _, _ in .none }, lookup: { _ in nil })
        var withPerformers = makeR18Match("ABC-123")
        withPerformers.performers = ["演员甲"]
        await store.match(withPerformers, to: codedFile("ABC-123"))
        await store.match(makeR18Match("DEF-456"), to: codedFile("DEF-456"))
        await store.match(seriesMetadata(), to: cloud(name: "凡人修仙传.S01E01.mkv", pickCode: "series"))
        XCTAssertEqual(store.performerCandidates().map { $0.code }, ["DEF-456"])
        var malformed = MediaMetadata(imdbID: "r18dev:bad", type: "movie", title: "", year: "", posterURL: "", backgroundURL: "",
                                      logoURL: "", overview: "", rating: "", genres: [], country: "", season: nil, episode: nil)
        malformed.source = MetadataSource.r18dev.rawValue
        XCTAssertNil(malformed.catalogCode, "Anything that does not look like a catalog code is ignored")
    }

    private func waitForEnrichment(_ store: MediaMetadataStore) async throws {
        for _ in 0..<400 {
            if !store.isEnrichingPerformers { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("The performer pass should have completed")
    }

    private func codedFile(_ code: String) -> LibraryMedia {
        LibraryMedia(cloud: P115File(id: code, parentId: "0", name: "[\(code)] sample.mp4", isDir: false, kind: "video",
                                     size: 10, pickCode: code, sha1: "", updatedAt: "", thumbUrl: ""))
    }

    private func waitForScan(_ store: MediaMetadataStore) async throws {
        for _ in 0..<400 {
            if !store.isMatching { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Metadata queue should have completed")
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "HPlayer.MetadataTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func cloud(name: String, pickCode: String) -> LibraryMedia {
        LibraryMedia(cloud: P115File(id: pickCode, parentId: "0", name: name,
            isDir: false, kind: "video", size: 500, pickCode: pickCode,
            sha1: String(repeating: "a", count: 40), updatedAt: "", thumbUrl: ""))
    }

    private func seriesMetadata(posterURL: String = "https://example.invalid/poster.jpg") -> MediaMetadata {
        MediaMetadata(imdbID: "bgm:凡人", type: "series", title: "凡人修仙传", year: "2020",
            posterURL: posterURL, backgroundURL: "", logoURL: "",
            overview: "", rating: "8.0", genres: [], country: "中国", season: 1, episode: 1)
    }
}

private func makeR18Match(_ code: String) -> MediaMetadata {
    var result = MediaMetadata(imdbID: "r18dev:\(code)", type: "movie", title: code, year: "",
        posterURL: "https://images.example/\(code).jpg", backgroundURL: "", logoURL: "", overview: "",
        rating: "", genres: [], country: "Japan", season: nil, episode: nil)
    result.source = MetadataSource.r18dev.rawValue
    result.contentID = "cid" + code.lowercased().replacingOccurrences(of: "-", with: "")
    return result
}

private actor PerformerLookupStub {
    struct Call: Sendable {
        let code: String
        let contentID: String?
    }

    private let results: [String: PerformerLookup]
    private let fallback: PerformerLookup
    private let pauseFirst: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls: [Call] = []
    private(set) var active = 0

    init(results: [String: PerformerLookup], fallback: PerformerLookup = .none, pauseFirst: Bool = false) {
        self.results = results
        self.fallback = fallback
        self.pauseFirst = pauseFirst
    }

    func lookup(_ code: String, _ contentID: String?) async -> PerformerLookup {
        calls.append(Call(code: code, contentID: contentID))
        active += 1
        defer { active -= 1 }
        if pauseFirst && calls.count == 1 {
            await withCheckedContinuation { continuation = $0 }
        }
        return results[code] ?? fallback
    }

    func releaseFirst() {
        continuation?.resume()
        continuation = nil
    }
}

private actor MetadataLookupStub {
    private var responses: [MediaMetadata?]
    private let pauseFirst: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var active = 0
    private(set) var calls = 0
    private(set) var maximumConcurrent = 0

    init(responses: [MediaMetadata?], pauseFirst: Bool = false) {
        self.responses = responses
        self.pauseFirst = pauseFirst
    }

    func lookup() async -> MediaMetadata? {
        calls += 1
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        defer { active -= 1 }
        if pauseFirst && calls == 1 {
            await withCheckedContinuation { continuation = $0 }
        }
        return responses.isEmpty ? nil : responses.removeFirst()
    }

    func releaseFirst() {
        continuation?.resume()
        continuation = nil
    }
}
