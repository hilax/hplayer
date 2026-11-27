import XCTest
@testable import HPlayer

private func makeFile(_ id: String, parent: String = "1", dir: Bool = false, video: Bool = true,
                      size: Int = 0, pick: String? = nil) -> P115File {
    P115File(id: id, parentId: parent, name: dir ? id : "\(id).\(video ? "mkv" : "srt")", isDir: dir,
             kind: dir ? "folder" : (video ? "video" : "doc"), size: size,
             pickCode: dir ? "" : (pick ?? "pc-\(id)"), sha1: "", updatedAt: "", thumbUrl: "")
}

// MARK: - 选择汇总

final class FileSelectionSummaryTests: XCTestCase {
    func testCountsKindsAndSizes() {
        let summary = FileSelectionSummary([
            makeFile("a", dir: true), makeFile("b", size: 1_073_741_824), makeFile("c", size: 1_073_741_824),
            makeFile("d", video: false, size: 1024),
        ])
        XCTAssertEqual(summary.folders, 1)
        XCTAssertEqual(summary.videos, 2)
        XCTAssertEqual(summary.others, 1)
        XCTAssertEqual(summary.count, 4)
        XCTAssertEqual(summary.kindsText, "1 个文件夹，2 个视频，1 个其他文件")
        XCTAssertEqual(summary.text, "1 个文件夹 · 2 个视频 · 1 个其他文件，共 2.00 GB")
    }

    func testFoldersAddNoSizeAndAnEmptySelectionHasNoText() {
        let onlyFolder = FileSelectionSummary([makeFile("a", dir: true, size: 999)])
        XCTAssertEqual(onlyFolder.bytes, 0)
        XCTAssertEqual(onlyFolder.text, "1 个文件夹")
        let empty = FileSelectionSummary([])
        XCTAssertEqual(empty.count, 0)
        XCTAssertEqual(empty.text, "")
        XCTAssertEqual(empty.kindsText, "")
    }

    func testNegativeSizesAreIgnored() {
        XCTAssertEqual(FileSelectionSummary([makeFile("a", size: -5)]).bytes, 0)
    }
}

// MARK: - 文件夹层级

final class FolderTreeTests: XCTestCase {
    private func entry(_ parent: String) -> CloudFolderEntry { CloudFolderEntry(parent: parent, name: "n") }

    func testCollectsEveryRecordedDescendant() {
        let recorded = ["B": entry("A"), "C": entry("B"), "D": entry("A"), "X": entry("Z")]
        XCTAssertEqual(FolderTree.descendants(of: ["B"], recorded: recorded), Set(["B", "C"]))
        XCTAssertEqual(FolderTree.descendants(of: ["A"], recorded: recorded), Set(["A", "B", "C", "D"]))
        XCTAssertEqual(FolderTree.descendants(of: ["B", "D"], recorded: recorded), Set(["B", "C", "D"]))
        XCTAssertEqual(FolderTree.descendants(of: [], recorded: recorded), Set<String>())
        XCTAssertEqual(FolderTree.descendants(of: ["Q"], recorded: recorded), Set(["Q"]))
    }

    func testCyclesTerminate() {
        let recorded = ["A": entry("B"), "B": entry("A")]
        XCTAssertEqual(FolderTree.descendants(of: ["A"], recorded: recorded), Set(["A", "B"]))
    }
}

// MARK: - 片库跟着网盘操作更新

@MainActor
final class LibraryFileSyncTests: XCTestCase {
    private func makeStore() -> (MediaLibraryStore, AppState, UserDefaults) {
        let suite = "LibraryFileSyncTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let state = AppState(cookieLoader: { "UID=12345_99; CID=local-session" })
        return (MediaLibraryStore(defaults: defaults), state, defaults)
    }

    private func entry(_ parent: String, _ name: String = "n") -> CloudFolderEntry { CloudFolderEntry(parent: parent, name: name) }

    func testDeletingAFolderReachesVideosInsideRecordedSubfolders() {
        let (store, state, _) = makeStore()
        let videos = [makeFile("a", parent: "10"), makeFile("b", parent: "20"), makeFile("c", parent: "30"), makeFile("d", parent: "40")]
        store.add(videos, for: state)
        store.recordFolders(["20": entry("10"), "30": entry("20"), "40": entry("99")], for: state)

        let folder = makeFile("20", parent: "10", dir: true)
        let affected = LibraryFileSync.affectedVideos([folder], library: store, appState: state)
        XCTAssertEqual(Set(affected.map(\.pickCode)), Set(["pc-b", "pc-c"]))

        let direct = LibraryFileSync.affectedVideos([videos[0]], library: store, appState: state)
        XCTAssertEqual(direct.map(\.pickCode), ["pc-a"])
    }

    func testRenamingAVideoKeepsItsPickCodeAndNeverAddsStrangers() {
        let (store, state, _) = makeStore()
        let video = makeFile("a", parent: "10")
        store.add([video], for: state)

        LibraryFileSync.didRename(video.replacing(name: "new.mkv"), library: store, appState: state)
        XCTAssertEqual(store.files(for: state).map(\.name), ["new.mkv"])
        XCTAssertEqual(store.files(for: state).map(\.pickCode), ["pc-a"])

        let stranger = makeFile("z", parent: "10")
        LibraryFileSync.didRename(stranger.replacing(name: "other.mkv"), library: store, appState: state)
        XCTAssertEqual(store.files(for: state).count, 1)
    }

    func testRenamingAFolderUpdatesOnlyItsRecordedName() {
        let (store, state, _) = makeStore()
        store.recordFolders(["20": entry("10", "旧名字")], for: state)
        let folder = makeFile("20", parent: "10", dir: true).replacing(name: "新名字")
        LibraryFileSync.didRename(folder, library: store, appState: state)
        XCTAssertEqual(store.folders(for: state)["20"], CloudFolderEntry(parent: "10", name: "新名字"))

        let unknown = makeFile("77", parent: "10", dir: true).replacing(name: "没记录过")
        LibraryFileSync.didRename(unknown, library: store, appState: state)
        XCTAssertNil(store.folders(for: state)["77"], "Folders that were never recorded are not invented")
    }

    func testMovingUpdatesVideoParentsAndFolderParents() {
        let (store, state, _) = makeStore()
        let video = makeFile("a", parent: "10")
        store.add([video], for: state)
        store.recordFolders(["20": entry("10", "子")], for: state)

        LibraryFileSync.didMove([video, makeFile("20", parent: "10", dir: true)], to: "50", library: store, appState: state)
        XCTAssertEqual(store.files(for: state).first?.parentId, "50")
        XCTAssertEqual(store.folders(for: state)["20"], CloudFolderEntry(parent: "50", name: "子"))
    }

    func testDeletingKeepsTheLibraryUnlessAskedAndThenClearsVideosAndHistory() {
        let (store, state, defaults) = makeStore()
        let recents = RecentStore(defaults: defaults)
        let kept = makeFile("keep", parent: "90")
        let gone = makeFile("gone", parent: "10")
        store.add([kept, gone], for: state)
        store.recordFolders(["10": entry("0", "要删的")], for: state)
        recents.record(.p115(title: "gone", pickCode: "pc-gone"))
        recents.record(.p115(title: "keep", pickCode: "pc-keep"))

        let selection = [makeFile("10", parent: "0", dir: true)]
        XCTAssertEqual(LibraryFileSync.didDelete(selection, removeFromLibrary: false, library: store, recents: recents, appState: state), 0)
        XCTAssertEqual(store.files(for: state).count, 2)
        XCTAssertEqual(recents.items.count, 2)

        XCTAssertEqual(LibraryFileSync.didDelete(selection, removeFromLibrary: true, library: store, recents: recents, appState: state), 1)
        XCTAssertEqual(store.files(for: state).map(\.pickCode), ["pc-keep"])
        XCTAssertEqual(recents.items.compactMap(\.pickCode), ["pc-keep"])
        XCTAssertNil(store.folders(for: state)["10"], "The deleted folder is forgotten")
    }

    func testLibraryStoreAdditionsOnlyTouchExistingVideos() {
        let (store, state, _) = makeStore()
        let first = makeFile("a", parent: "10")
        let second = makeFile("b", parent: "10")
        store.add([first, second], for: state)
        XCTAssertEqual(store.pickCodes(for: state), Set(["pc-a", "pc-b"]))

        let revision = store.revision
        store.update([first], for: state)
        XCTAssertEqual(store.revision, revision, "An identical record is not a change")

        store.update([first.replacing(name: "x.mkv"), makeFile("c")], for: state)
        XCTAssertEqual(store.files(for: state).map(\.name), ["x.mkv", "b.mkv"])
        XCTAssertEqual(store.files(for: state).count, 2)

        let signedOut = AppState(cookieLoader: { nil })
        XCTAssertTrue(store.pickCodes(for: signedOut).isEmpty)
    }

    func testLookupFilesByPickCodePreservesOrderAndDeduplicates() {
        let (store, state, _) = makeStore()
        let first = makeFile("101", parent: "10", pick: "pc-101")
        let second = makeFile("102", parent: "10", pick: "pc-102")
        store.add([first, second], for: state)

        XCTAssertEqual(store.file(pickCode: "pc-101", for: state), first)
        XCTAssertNil(store.file(pickCode: "missing", for: state))
        XCTAssertEqual(store.files(pickCodes: ["pc-102", "pc-101", "pc-102", ""], for: state), [second, first])
    }
}

// MARK: - 片库卡片删除 115 网盘影片

@MainActor
final class CloudLibraryDeletionTests: XCTestCase {
    private func makeEnv() -> (MediaLibraryStore, RecentStore, CloudLibraryScanner, AppState, UserDefaults) {
        let suite = "CloudLibraryDeletionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let state = AppState(cookieLoader: { "UID=12345_99; CID=local-session" })
        let store = MediaLibraryStore(defaults: defaults)
        let recents = RecentStore(defaults: defaults)
        let scanner = CloudLibraryScanner(defaults: defaults, minimumRequestInterval: 0, persistInterval: 0, retryBaseDelay: 0)
        return (store, recents, scanner, state, defaults)
    }

    private func makeClient() -> Direct115Client {
        Direct115Client(cookie: "UID=12345_99; CID=local-session", protocolClasses: [RoutedURLProtocol.self])
    }

    private func seriesMetadata() -> MediaMetadata {
        MediaMetadata(imdbID: "tt999", type: "series", title: "测试剧集", year: "2025",
                      posterURL: "https://example.test/poster.jpg", backgroundURL: "", logoURL: "",
                      overview: "", rating: "8.5", genres: ["剧情"], country: "China")
    }

    func testRequestResolvesCloudMovieAndIgnoresLocalVideo() {
        let (store, _, _, state, _) = makeEnv()
        let cloudFile = makeFile("1001", parent: "10", size: 2048, pick: "pc-1001")
        store.add([cloudFile], for: state)

        let cloudItem = HomeMediaItem(media: LibraryMedia(cloud: cloudFile), metadata: nil)
        let request = CloudLibraryDeletion.request(for: cloudItem, library: store, appState: state)
        XCTAssertEqual(request?.files, [cloudFile])
        XCTAssertEqual(request?.confirmTitle, "删除 115 网盘影片？")

        let local = LocalMedia(url: URL(fileURLWithPath: "/tmp/local.mp4"), size: 1024, modified: Date())
        let localItem = HomeMediaItem(media: LibraryMedia(local: local), metadata: nil)
        XCTAssertNil(CloudLibraryDeletion.request(for: localItem, library: store, appState: state))
    }

    func testRequestForSeriesCollectsOnlyCloudEpisodesInOrder() {
        let (store, _, _, state, _) = makeEnv()
        let ep1 = makeFile("2001", parent: "20", pick: "pc-ep1")
        let ep2 = makeFile("2002", parent: "20", pick: "pc-ep2")
        store.add([ep1, ep2], for: state)

        let localEp = HomeMediaItem(
            media: LibraryMedia(local: LocalMedia(url: URL(fileURLWithPath: "/tmp/S01E03.mp4"), size: 500, modified: Date())),
            metadata: seriesMetadata()
        )
        let group = SeriesGroup(
            id: "tt999",
            metadata: seriesMetadata(),
            episodes: [
                HomeMediaItem(media: LibraryMedia(cloud: ep1), metadata: seriesMetadata()),
                localEp,
                HomeMediaItem(media: LibraryMedia(cloud: ep2), metadata: seriesMetadata()),
            ]
        )

        let request = CloudLibraryDeletion.request(for: group, library: store, appState: state)
        XCTAssertEqual(request?.files, [ep1, ep2])
        XCTAssertEqual(request?.confirmTitle, "删除 2 个 115 网盘视频？")
        XCTAssertEqual(request?.successText, "已将 2 个视频移入 115 回收站，并从片库移除")
    }

    func testExecuteMovesToRecycleBinAndCleansLibraryScannerAndRecents() async throws {
        let (store, recents, scanner, state, defaults) = makeEnv()
        let target = makeFile("3001", parent: "10", pick: "pc-target")
        let keeper = makeFile("3002", parent: "10", pick: "pc-keeper")
        store.add([target, keeper], for: state)
        recents.record(.p115(title: target.name, pickCode: target.pickCode))
        recents.record(.p115(title: keeper.name, pickCode: keeper.pickCode))

        scanner.start(accountID: "device:12345", fetchPage: { _, _ in
            Direct115FilePage(files: [target, keeper], nextOffset: nil)
        }, onBatch: { _ in }, restart: true)
        for _ in 0..<500 where scanner.phase == .running {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(scanner.phase, .completed)

        RoutedURLProtocol.install { _ in .json(["state": true]) }
        let item = HomeMediaItem(media: LibraryMedia(cloud: target), metadata: nil)
        let request = try XCTUnwrap(CloudLibraryDeletion.request(for: item, library: store, appState: state))

        let message = try await CloudLibraryDeletion.execute(
            request,
            client: makeClient(),
            library: store,
            recents: recents,
            scanner: scanner,
            appState: state
        )

        XCTAssertEqual(message, "已移入 115 回收站，并从片库移除")
        let sent = try XCTUnwrap(RoutedURLProtocol.requests().first)
        XCTAssertEqual(sent.url?.absoluteString, "https://webapi.115.com/rb/delete")
        XCTAssertEqual(RoutedURLProtocol.form(of: sent), ["fid[0]": "3001"])
        XCTAssertEqual(store.files(for: state).map(\.pickCode), ["pc-keeper"])
        XCTAssertEqual(recents.items.compactMap(\.pickCode), ["pc-keeper"])
        XCTAssertEqual(scanner.discoveredFiles.map(\.pickCode), ["pc-keeper"])

        let restoredScanner = CloudLibraryScanner(defaults: defaults, minimumRequestInterval: 0, persistInterval: 0, retryBaseDelay: 0)
        restoredScanner.selectAccount("device:12345")
        XCTAssertEqual(restoredScanner.discoveredFiles.map(\.pickCode), ["pc-keeper"])
    }

    func testExecuteFailureLeavesLibraryAndRecentsUntouched() async throws {
        let (store, recents, scanner, state, _) = makeEnv()
        let target = makeFile("4001", parent: "10", pick: "pc-4001")
        store.add([target], for: state)
        recents.record(.p115(title: target.name, pickCode: target.pickCode))

        RoutedURLProtocol.install { _ in .json(["state": false, "errno": 99, "error": "登录已失效"]) }
        let item = HomeMediaItem(media: LibraryMedia(cloud: target), metadata: nil)
        let request = try XCTUnwrap(CloudLibraryDeletion.request(for: item, library: store, appState: state))

        do {
            _ = try await CloudLibraryDeletion.execute(
                request,
                client: makeClient(),
                library: store,
                recents: recents,
                scanner: scanner,
                appState: state
            )
            XCTFail("远端删除失败时应该抛出错误")
        } catch {
            XCTAssertEqual(error as? Direct115FileError, .notLoggedIn)
        }

        XCTAssertEqual(store.files(for: state).map(\.pickCode), ["pc-4001"])
        XCTAssertEqual(recents.items.compactMap(\.pickCode), ["pc-4001"])
    }
}

// MARK: - 文件模型与提示文字

final class FileModelAndTextTests: XCTestCase {
    func testReplacingKeepsEverythingElse() {
        let original = makeFile("a", parent: "10", size: 5)
        let renamed = original.replacing(name: "b.mkv")
        XCTAssertEqual(renamed.name, "b.mkv")
        XCTAssertEqual(renamed.parentId, "10")
        XCTAssertEqual(renamed.pickCode, original.pickCode)
        XCTAssertEqual(renamed.size, 5)
        let moved = original.replacing(parentId: "77")
        XCTAssertEqual(moved.parentId, "77")
        XCTAssertEqual(moved.name, original.name)
    }

    func testExtensionLabel() {
        XCTAssertEqual(makeFile("a").extensionLabel, "MKV")
        XCTAssertEqual(makeFile("a", dir: true).extensionLabel, "")
        let noExtension = P115File(id: "1", parentId: "0", name: "README", isDir: false, kind: "doc", size: 1,
                                   pickCode: "x", sha1: "", updatedAt: "", thumbUrl: "")
        XCTAssertEqual(noExtension.extensionLabel, "")
    }

    func testDownloadResultSentencesNameWhatHappened() {
        XCTAssertEqual(FileOperationText.downloadResult(DownloadEnqueueSummary(added: 2)), "已加入下载 2 个文件，可在 我的 › 本机视频 查看")
        XCTAssertEqual(FileOperationText.downloadResult(DownloadEnqueueSummary(added: 1, duplicates: 1, folders: 2, unavailable: 1)),
                       "已加入下载 1 个文件，可在 我的 › 本机视频 查看；1 个已在下载列表里；文件夹暂不支持下载，已跳过 2 个；1 个文件没有下载地址")
        XCTAssertEqual(FileOperationText.downloadResult(DownloadEnqueueSummary()), "没有可下载的文件")
    }

    func testPathLabelAlwaysStartsWithTheDrive() {
        XCTAssertEqual(FileOperationText.pathLabel([]), "网盘")
        XCTAssertEqual(FileOperationText.pathLabel([Crumb(cid: "0", name: "根目录")]), "网盘")
        XCTAssertEqual(FileOperationText.pathLabel([Crumb(cid: "0", name: "115 网盘"), Crumb(cid: "5", name: "电影"), Crumb(cid: "6", name: "2024")]),
                       "网盘 / 电影 / 2024")
    }

    func testDeletedTimeText() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
            DateComponents(calendar: calendar, year: year, month: month, day: day, hour: hour, minute: minute).date!
        }
        let now = date(2026, 11, 5, 12, 0)
        XCTAssertEqual(DeletedTimeText.text(date(2026, 11, 5, 10, 32), now: now, calendar: calendar), "今天 10:32")
        XCTAssertEqual(DeletedTimeText.text(date(2026, 11, 4, 22, 8), now: now, calendar: calendar), "昨天 22:08")
        XCTAssertEqual(DeletedTimeText.text(date(2026, 10, 30, 19, 45), now: now, calendar: calendar), "10-30 19:45")
        XCTAssertEqual(DeletedTimeText.text(date(2025, 12, 31, 8, 5), now: now, calendar: calendar), "2025-12-31 08:05")
        XCTAssertEqual(DeletedTimeText.text(nil, now: now, calendar: calendar), "时间未知")
    }

    func testRecycleItemKindsAndScope() {
        func item(_ name: String, dir: Bool) -> Direct115RecycleItem {
            Direct115RecycleItem(id: "1", name: name, size: 1, parentName: "", deletedAt: nil, isDirectory: dir)
        }
        XCTAssertEqual(RecycleItemKind.of(item("待整理", dir: true)), .folder)
        XCTAssertEqual(RecycleItemKind.of(item("Movie.2024.MKV", dir: false)), .video)
        XCTAssertEqual(RecycleItemKind.of(item("字幕.srt", dir: false)), .file)
        XCTAssertEqual(RecycleScope.selected(["1", "2"]).ids, ["1", "2"])
        XCTAssertTrue(RecycleScope.everything.ids.isEmpty)
    }

    func testFolderTrailParsingKeepsTheOrderAndNamesTheRoot() {
        let json: [String: Any] = ["path": [
            ["cid": 0, "name": "根目录"], ["cid": "123", "name": "电影"], ["cid": 456, "name": "2024"],
            ["cid": "", "name": "没有编号"], ["cid": "789", "name": ""],
        ]]
        XCTAssertEqual(Direct115Client.parseFolderTrail(json), [
            Direct115PathEntry(id: "0", name: "网盘"), Direct115PathEntry(id: "123", name: "电影"), Direct115PathEntry(id: "456", name: "2024"),
        ])
        XCTAssertTrue(Direct115Client.parseFolderTrail([:]).isEmpty)
    }
}

// MARK: - 离线下载与下载管理的文字

final class ManagementTextTests: XCTestCase {
    private func task(_ status: Direct115OfflineTask.Status, percent: Double = 0, size: Int = 0, speed: Double = 0,
                      remaining: Int = 0, link: String = "magnet:?xt=urn:btih:abc") -> Direct115OfflineTask {
        Direct115OfflineTask(infoHash: "hash", name: "Movie", size: size, status: status, percent: percent, fileID: "",
                             folderID: "5", remoteHash: "hash", sourceURL: link, addedAt: nil, speed: speed, remainingSeconds: remaining)
    }

    func testOfflineFiltersGroupStatuses() {
        XCTAssertTrue(OfflineFilter.running.includes(.waiting))
        XCTAssertTrue(OfflineFilter.running.includes(.downloading))
        XCTAssertFalse(OfflineFilter.running.includes(.done))
        XCTAssertTrue(OfflineFilter.done.includes(.done))
        XCTAssertTrue(OfflineFilter.failed.includes(.failed))
        XCTAssertFalse(OfflineFilter.failed.includes(.waiting))
    }

    func testRunningTaskText() {
        let running = task(.downloading, percent: 63, size: 9_921_374_453, speed: 3_565_158, remaining: 1_020)
        XCTAssertEqual(OfflineTaskText.percent(running), "63%")
        XCTAssertEqual(OfflineTaskText.detail(running), " · 5.82 GB / 9.24 GB")
        XCTAssertEqual(OfflineTaskText.rate(running), "3.4 MB/s · 剩余约 17 分钟")
        XCTAssertEqual(OfflineTaskText.subtitle(running, folder: "网盘 / 电影"), "磁力链接 · 保存到 网盘 / 电影")
        XCTAssertEqual(OfflineTaskText.subtitle(running, folder: nil), "磁力链接")
    }

    func testWaitingAndFinishedTaskText() {
        let waiting = task(.waiting)
        XCTAssertEqual(OfflineTaskText.percent(waiting), "0%")
        XCTAssertEqual(OfflineTaskText.detail(waiting), " · 等待中")
        XCTAssertEqual(OfflineTaskText.rate(waiting), "暂无速度")
        XCTAssertEqual(OfflineTaskText.subtitle(waiting, folder: "网盘 / 电影"), "磁力链接 · 正在等待资源")
        XCTAssertEqual(OfflineTaskText.rate(task(.downloading)), "正在下载")
        XCTAssertEqual(OfflineTaskText.finished(task(.done, percent: 100, size: 32_800_000_000)), "已完成 · 30.55 GB")
        XCTAssertEqual(OfflineTaskText.finished(task(.done, percent: 100)), "已完成")
        XCTAssertEqual(OfflineTaskText.subtitle(task(.done, link: "https://example.com/a.zip"), folder: nil), "HTTP 链接")
    }

    private func download(_ state: DownloadItem.State, total: Int64 = 4_692_251_770, received: Int64 = 1_923_823_225,
                          message: String = "", library: Bool = true) -> DownloadItem {
        DownloadItem(id: UUID(), fileID: "1", pickCode: "pc", name: "Movie.mkv", isVideo: true, totalBytes: total,
                     folderLabel: "网盘 / 电影", state: state, receivedBytes: received, message: message,
                     addedAt: Date(), finishedAt: nil, savedName: nil, savedInLibrary: library)
    }

    func testDownloadCardText() {
        let running = download(.downloading)
        XCTAssertEqual(DownloadsText.subtitle(running), "4.37 GB · 网盘 / 电影")
        XCTAssertEqual(DownloadsText.subtitle(download(.paused)), "4.37 GB · 网盘 / 电影 · 已暂停")
        XCTAssertEqual(DownloadsText.percent(running), "41%")
        XCTAssertEqual(DownloadsText.amount(running), " · 1.79 GB / 4.37 GB")
        XCTAssertEqual(DownloadsText.amount(download(.downloading, total: 0, received: 0)), "")
        XCTAssertEqual(DownloadsText.status(running, speed: 8_598_323, remaining: 322), "8.2 MB/s · 剩余约 5 分钟")
        XCTAssertEqual(DownloadsText.status(running, speed: nil, remaining: nil), "正在连接…")
        XCTAssertEqual(DownloadsText.status(download(.paused), speed: nil, remaining: nil), "点按继续，支持断点续传")
        XCTAssertEqual(DownloadsText.status(download(.failed), speed: nil, remaining: nil), "下载失败，点按重试")
        XCTAssertEqual(DownloadsText.status(download(.failed, message: "空间不足"), speed: nil, remaining: nil), "空间不足")
        XCTAssertEqual(DownloadsText.status(download(.queued), speed: nil, remaining: nil), "排队中")
    }

    func testSavedLineSaysWhereTheFileWent() {
        XCTAssertEqual(DownloadsText.savedLine(download(.completed, library: true)), "已保存到「本机视频」 · 4.37 GB")
        XCTAssertEqual(DownloadsText.savedLine(download(.completed, total: 0, library: false)), "已保存到 App 的「下载」文件夹")
    }
}
