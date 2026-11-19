import XCTest
@testable import HPlayer

@MainActor
final class MagnetCloudSessionTests: XCTestCase {
    private func completedCloudController() -> MagnetController {
        let file = P115File(id: "old-file", parentId: "0", name: "Episode.mkv", isDir: false,
                            kind: "video", size: 1024, pickCode: "old-account-pick", sha1: "", updatedAt: "", thumbUrl: "")
        let catalog = MagnetCatalog(cloudVideos: [Direct115CloudVideo(file: file, folder: "")],
                                    name: "Show", totalSize: 1024)
        let controller = MagnetController.interfaceFixture(catalog: catalog,
                                                            cloudClient: Direct115Client(cookie: "UID=account-a"))
        let source = PlaybackSource.p115(title: file.name, pickCode: file.pickCode)
        controller.cloudQueue = PlaybackQueue(source: source, items: [source])
        return controller
    }

    func testSwitchingAccountsDiscardsPreviousCloudFilesAndPlaybackQueue() {
        let controller = completedCloudController()
        controller.configureCloud(client: Direct115Client(cookie: "UID=account-b"), enabled: true)
        XCTAssertNil(controller.catalog)
        XCTAssertNil(controller.cloudCatalog)
        XCTAssertNil(controller.cloudQueue)
        XCTAssertEqual(controller.cloud, .off)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(controller.usesCloud)
    }

    func testLogoutDiscardsPreviousCloudFilesAndPlaybackQueue() {
        let controller = completedCloudController()
        controller.configureCloud(client: nil, enabled: true)
        XCTAssertNil(controller.catalog)
        XCTAssertNil(controller.cloudCatalog)
        XCTAssertNil(controller.cloudQueue)
        XCTAssertEqual(controller.cloud, .off)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.usesCloud)
    }

    func testReconfiguringSameSessionPreservesCompletedCloudFiles() {
        let controller = completedCloudController()
        controller.configureCloud(client: Direct115Client(cookie: "UID=account-a"), enabled: true)
        XCTAssertNotNil(controller.catalog)
        XCTAssertNotNil(controller.cloudCatalog)
        XCTAssertNotNil(controller.cloudQueue)
        XCTAssertEqual(controller.cloud, .ready)
        XCTAssertEqual(controller.phase, .ready)
    }

    func testPrepareDefaultCloudQueueSelectsLargestMainVideoForMultiFileCatalog() {
        MagnetHistoryStore.shared.remove("0123456789012345678901234567890123456789")
        let ep1 = P115File(id: "f1", parentId: "0", name: "EP01.mkv", isDir: false,
                           kind: "video", size: 500_000_000, pickCode: "pc-ep1", sha1: "", updatedAt: "", thumbUrl: "")
        let ep2 = P115File(id: "f2", parentId: "0", name: "EP02.mkv", isDir: false,
                           kind: "video", size: 800_000_000, pickCode: "pc-ep2", sha1: "", updatedAt: "", thumbUrl: "")
        let catalog = MagnetCatalog(
            cloudVideos: [
                Direct115CloudVideo(file: ep1, folder: ""),
                Direct115CloudVideo(file: ep2, folder: ""),
            ],
            name: "SSIS-001",
            totalSize: 1_300_000_000
        )
        let controller = MagnetController.interfaceFixture(
            catalog: catalog,
            cloudClient: Direct115Client(cookie: "UID=account-a")
        )
        XCTAssertNil(controller.cloudQueue)

        controller.prepareDefaultCloudQueueIfReady()
        let queue = controller.cloudQueue
        XCTAssertNotNil(queue, "多文件 115 目录就绪时应能同步生成默认播放队列，避免首帧闪屏")
        XCTAssertEqual(queue?.source.id, "p115|pc-ep2", "无历史记录时应默认选中体积最大的正片")
        XCTAssertEqual(queue?.items.count, 2)
        XCTAssertTrue(queue?.source.title.contains("SSIS-001") == true, "单文件名不含番号时应自动附带种子番号便于辨识与字幕匹配")
    }

    func testCloudPlayedMagnetIsDeduplicatedFromContinueWatchingWhileBTIsKept() throws {
        let suiteName = "hplayer.test.magnetHistory.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MagnetHistoryStore(defaults: defaults)
        let cloudHash = "0123456789abcdef0123456789abcdef01234567"
        let btHash = "fedcba9876543210fedcba9876543210fedcba98"
        let cloudLink = try XCTUnwrap(MagnetLink.parse("magnet:?xt=urn:btih:\(cloudHash)&dn=ABF-400"))
        let btLink = try XCTUnwrap(MagnetLink.parse("magnet:?xt=urn:btih:\(btHash)&dn=MovieBT"))

        let p115File = P115File(id: "1", parentId: "0", name: "489155 com@ABF-400.mp4", isDir: false,
                                kind: "video", size: 2_000_000_000, pickCode: "pc_abf400", sha1: "", updatedAt: "", thumbUrl: "")
        let cloudCatalog = MagnetCatalog(cloudVideos: [Direct115CloudVideo(file: p115File, folder: "")],
                                         name: "ABF-400", totalSize: 2_000_000_000)
        store.recordResolved(link: cloudLink, catalog: cloudCatalog)
        store.recordPlayed(infoHash: cloudLink.infoHash, file: try XCTUnwrap(cloudCatalog.allVideos.first))

        let cloudEntry = try XCTUnwrap(store.item(for: cloudLink.infoHash))
        XCTAssertEqual(cloudEntry.playedViaCloud, true)
        XCTAssertEqual(cloudEntry.lastCloudPickCode, "pc_abf400")
        XCTAssertTrue(MagnetHistoryStore.isSupersededByCloud(
            cloudEntry,
            recentCloudPickCodes: ["pc_abf400"],
            recentCloudTitles: ["489155 com@ABF-400.mp4"],
            cachedPickCodesForHash: { _ in [] },
            isDownloadedToCloud: { _ in false }
        ))

        let btFile = NuvioTorrentFile(index: 0, offset: 0, size: 1_500_000_000, path: "MovieBT.mkv", pathWasTruncated: false)
        let btCatalog = MagnetCatalog(files: [btFile], fallbackName: "MovieBT")
        store.recordResolved(link: btLink, catalog: btCatalog)
        store.recordPlayed(infoHash: btLink.infoHash, file: try XCTUnwrap(btCatalog.allVideos.first))

        let btEntry = try XCTUnwrap(store.item(for: btLink.infoHash))
        XCTAssertEqual(btEntry.playedViaCloud, false)
        XCTAssertFalse(MagnetHistoryStore.isSupersededByCloud(
            btEntry,
            recentCloudPickCodes: ["pc_abf400"],
            recentCloudTitles: ["489155 com@ABF-400.mp4"],
            cachedPickCodesForHash: { _ in ["pc_abf400"] },
            isDownloadedToCloud: { _ in true }
        ))
    }

    func testLegacyPreFixMagnetHistoryDuplicateIsDeduplicatedAndStaysHiddenAfterRemoval() throws {
        let suiteName = "hplayer.test.magnetHistoryLegacy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let legacyItem = MagnetHistoryItem(
            infoHash: legacyHash,
            magnet: "magnet:?xt=urn:btih:\(legacyHash)&dn=ABF-400",
            name: "ABF-400",
            totalSize: 2_000_000_000,
            videoCount: 2,
            lastFileIndex: 0,
            lastFileTitle: "ABF-400",
            positions: [:],
            updatedAt: Date()
        )
        defaults.set(try JSONEncoder().encode([legacyItem]), forKey: "hplayer.magnet.history")

        let store = MagnetHistoryStore(defaults: defaults)
        let loaded = try XCTUnwrap(store.item(for: legacyHash))
        XCTAssertNil(loaded.playedViaCloud)

        // 1. 命中 MagnetCloudVideoCache 的 pickCode 关联去重
        XCTAssertTrue(MagnetHistoryStore.isSupersededByCloud(
            loaded,
            recentCloudPickCodes: ["pc_abf400"],
            recentCloudTitles: ["489155 com@ABF-400.mp4"],
            cachedPickCodesForHash: { hash in hash == legacyHash ? ["pc_abf400"] : [] },
            isDownloadedToCloud: { _ in false }
        ))

        // 2. 缓存被清后通过已离线标记与片名匹配去重
        XCTAssertTrue(MagnetHistoryStore.isSupersededByCloud(
            loaded,
            recentCloudPickCodes: ["pc_other"],
            recentCloudTitles: ["489155 com@ABF-400.mp4"],
            cachedPickCodesForHash: { _ in [] },
            isDownloadedToCloud: { $0 == legacyHash }
        ))

        // 3. 删除 115 记录后标记旧磁力条目，不会重新冒出重复卡片
        store.markSupersededByCloud(pickCode: "pc_abf400", cachedInfoHashes: [legacyHash], title: "489155 com@ABF-400.mp4")
        let marked = try XCTUnwrap(store.item(for: legacyHash))
        XCTAssertEqual(marked.playedViaCloud, true)
        XCTAssertTrue(MagnetHistoryStore.isSupersededByCloud(
            marked,
            recentCloudPickCodes: [],
            recentCloudTitles: [],
            cachedPickCodesForHash: { _ in [] },
            isDownloadedToCloud: { _ in false }
        ))
    }
}
