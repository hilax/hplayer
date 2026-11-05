import XCTest
@testable import HPlayer

private let sampleBody = Data("0123456789".utf8)

// MARK: - 单次下载

final class RangeDownloaderTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func downloader(_ part: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }) -> RangeDownloader {
        RangeDownloader(request: URLRequest(url: URL(string: "https://dl.example.test/a.mkv")!), partURL: part,
                        protocolClasses: [RoutedURLProtocol.self], reportInterval: 0, onProgress: progress)
    }

    func testDownloadsTheWholeFile() async throws {
        let part = try directory().appendingPathComponent("a.part")
        RoutedURLProtocol.install { _ in .init(status: 200, headers: ["Content-Length": "10", "Content-Type": "video/x-matroska"], body: sampleBody) }
        let bytes = try await downloader(part).run()
        XCTAssertEqual(bytes, 10)
        XCTAssertEqual(try Data(contentsOf: part), sampleBody)
        let request = try XCTUnwrap(RoutedURLProtocol.requests().first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
    }

    func testResumesFromTheExistingBytes() async throws {
        let part = try directory().appendingPathComponent("a.part")
        try sampleBody.prefix(4).write(to: part)
        RoutedURLProtocol.install { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=4-")
            return .init(status: 206, headers: ["Content-Range": "bytes 4-9/10", "Content-Length": "6"], body: sampleBody.dropFirst(4))
        }
        let bytes = try await downloader(part).run()
        XCTAssertEqual(bytes, 10)
        XCTAssertEqual(try Data(contentsOf: part), sampleBody)
    }

    func testRestartsWhenTheServerIgnoresRange() async throws {
        let part = try directory().appendingPathComponent("a.part")
        try Data("xxxx".utf8).write(to: part)
        RoutedURLProtocol.install { _ in .init(status: 200, headers: ["Content-Length": "10"], body: sampleBody) }
        let bytes = try await downloader(part).run()
        XCTAssertEqual(bytes, 10)
        XCTAssertEqual(try Data(contentsOf: part), sampleBody)
    }

    func testAlreadyCompleteFileIsAccepted() async throws {
        let part = try directory().appendingPathComponent("a.part")
        try sampleBody.write(to: part)
        RoutedURLProtocol.install { _ in .init(status: 416, headers: ["Content-Range": "bytes */10"]) }
        let bytes = try await downloader(part).run()
        XCTAssertEqual(bytes, 10)
        XCTAssertEqual(try Data(contentsOf: part), sampleBody)
    }

    func testMismatchedRangeAsksForARestart() async throws {
        let part = try directory().appendingPathComponent("a.part")
        try Data("xxxx".utf8).write(to: part)
        RoutedURLProtocol.install { _ in .init(status: 206, headers: ["Content-Range": "bytes 0-9/10"], body: sampleBody) }
        await assertFailure(.rangeRejected) { _ = try await self.downloader(part).run() }

        RoutedURLProtocol.install { _ in .init(status: 416, headers: ["Content-Range": "bytes */3"]) }
        await assertFailure(.rangeRejected) { _ = try await self.downloader(part).run() }
    }

    func testExpiredAddressAndServerErrors() async throws {
        let part = try directory().appendingPathComponent("a.part")
        for status in [401, 403, 410] {
            RoutedURLProtocol.install { _ in .init(status: status) }
            await assertFailure(.expired) { _ = try await self.downloader(part).run() }
        }
        RoutedURLProtocol.install { _ in .init(status: 503) }
        await assertFailure(.http(503)) { _ = try await self.downloader(part).run() }
        XCTAssertTrue(RangeDownloader.Failure.http(503).isRetryable)
        XCTAssertFalse(RangeDownloader.Failure.http(404).isRetryable)
        XCTAssertFalse(RangeDownloader.Failure.expired.isRetryable)
    }

    func testAWebPageIsNotAFile() async throws {
        let part = try directory().appendingPathComponent("a.part")
        RoutedURLProtocol.install { _ in .init(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data("<html>".utf8)) }
        await assertFailure(.notAFile) { _ = try await self.downloader(part).run() }
    }

    func testShortBodyIsReportedAsIncomplete() async throws {
        let part = try directory().appendingPathComponent("a.part")
        RoutedURLProtocol.install { _ in .init(status: 206, headers: ["Content-Range": "bytes 0-9/10"], body: sampleBody.prefix(4)) }
        await assertFailure(.incomplete(received: 4, expected: 10)) { _ = try await self.downloader(part).run() }
        XCTAssertEqual(try Data(contentsOf: part), sampleBody.prefix(4))
    }

    func testReportsProgress() async throws {
        let part = try directory().appendingPathComponent("a.part")
        RoutedURLProtocol.install { _ in .init(status: 206, headers: ["Content-Range": "bytes 0-9/10"], body: sampleBody) }
        let box = ProgressBox()
        _ = try await downloader(part) { received, total in box.add(received, total) }.run()
        let last = try XCTUnwrap(box.last)
        XCTAssertEqual(last.0, 10)
        XCTAssertEqual(last.1, 10)
    }

    func testParsesContentRange() {
        XCTAssertEqual(RangeDownloader.parseContentRange("bytes 100-999/1000"), .init(start: 100, end: 999, total: 1000))
        XCTAssertEqual(RangeDownloader.parseContentRange("bytes 100-999/*"), .init(start: 100, end: 999, total: nil))
        XCTAssertEqual(RangeDownloader.parseContentRange("bytes */1000"), .init(start: nil, end: nil, total: 1000))
        XCTAssertNil(RangeDownloader.parseContentRange("items 1-2/3"))
        XCTAssertNil(RangeDownloader.parseContentRange("bytes 9-1/10"))
        XCTAssertNil(RangeDownloader.parseContentRange(nil))
    }

    private func assertFailure(_ expected: RangeDownloader.Failure, _ body: () async throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("应该失败：\(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? RangeDownloader.Failure, expected, file: file, line: line)
        }
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int64, Int64?)] = []

    func add(_ received: Int64, _ total: Int64?) {
        lock.lock(); defer { lock.unlock() }
        values.append((received, total))
    }

    var last: (Int64, Int64?)? {
        lock.lock(); defer { lock.unlock() }
        return values.last
    }
}

// MARK: - 文字与文件

final class DownloadFilesTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testSafeFileNames() {
        XCTAssertEqual(DownloadFiles.safeFileName("a/b:c.mkv"), "a_b_c.mkv")
        XCTAssertEqual(DownloadFiles.safeFileName("..隐藏.mp4"), "隐藏.mp4")
        XCTAssertEqual(DownloadFiles.safeFileName("  \n  "), "下载文件")
        XCTAssertEqual(DownloadFiles.safeFileName("tab\there.mp4"), "tabhere.mp4")
        let long = DownloadFiles.safeFileName(String(repeating: "影", count: 200) + ".mkv")
        XCTAssertLessThanOrEqual(long.utf8.count, 200)
        XCTAssertTrue(long.hasSuffix(".mkv"))
    }

    func testMoveKeepsBothFilesWhenNamesCollide() throws {
        let root = try directory()
        let target = root.appendingPathComponent("lib")
        let first = root.appendingPathComponent("1.part"), second = root.appendingPathComponent("2.part")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        let a = try DownloadFiles.move(first, into: target, preferredName: "movie.mp4")
        let b = try DownloadFiles.move(second, into: target, preferredName: "movie.mp4")
        XCTAssertEqual(a.lastPathComponent, "movie.mp4")
        XCTAssertEqual(b.lastPathComponent, "movie (2).mp4")
        XCTAssertEqual(try Data(contentsOf: a), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: b), Data("two".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }

    func testFormats() {
        XCTAssertEqual(DownloadFormat.bytes(0), "0 B")
        XCTAssertEqual(DownloadFormat.bytes(948 * 1024 * 1024), "948 MB")
        XCTAssertEqual(DownloadFormat.bytes(Int64(4.37 * 1024 * 1024 * 1024)), "4.37 GB")
        XCTAssertEqual(DownloadFormat.speed(8.2 * 1024 * 1024), "8.2 MB/s")
        XCTAssertEqual(DownloadFormat.speed(0), "")
        XCTAssertEqual(DownloadFormat.remaining(20), "剩余不到 1 分钟")
        XCTAssertEqual(DownloadFormat.remaining(300), "剩余约 5 分钟")
        XCTAssertEqual(DownloadFormat.remaining(3 * 3600), "剩余约 3 小时")
        XCTAssertEqual(DownloadFormat.remaining(100 * 3600), "剩余时间较长")
    }

    func testLocalLibrarySupportsOnlyItsKnownFormats() {
        XCTAssertTrue(LocalMediaStore.supportsVideoExtension("MKV"))
        XCTAssertFalse(LocalMediaStore.supportsVideoExtension("rmvb"))
        XCTAssertFalse(LocalMediaStore.supportsVideoExtension(""))
    }
}

// MARK: - 下载管理

@MainActor
final class DownloadManagerTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var loose: URL!
    /// DownloadManager 只弱引用本地视频库；测试里用 `_` 丢掉返回值时，库会被立刻释放，下载就落到别的目录
    private var retainedMedia: [LocalMediaStore] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        library = root.appendingPathComponent("Media", isDirectory: true)
        loose = root.appendingPathComponent("Loose", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root!
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    }

    private func makeManager(maxConcurrent: Int = 2, freeSpace: (() -> Int64?)? = { nil }, retryDelays: [TimeInterval] = [0.01, 0.01]) -> (DownloadManager, LocalMediaStore) {
        let media = LocalMediaStore(directory: library)
        let manager = DownloadManager(
            storeURL: root.appendingPathComponent("downloads.json"), partsDirectory: root.appendingPathComponent("parts"),
            looseDirectory: loose, maxConcurrent: maxConcurrent, protocolClasses: [RoutedURLProtocol.self],
            retryDelays: retryDelays, freeSpace: freeSpace)
        manager.media = media
        retainedMedia.append(media)
        manager.requestProvider = { _ in URLRequest(url: URL(string: "https://dl.example.test/file")!) }
        return (manager, media)
    }

    private func file(_ name: String, pick: String = "pc", size: Int = 10, dir: Bool = false, video: Bool = true) -> P115File {
        P115File(id: "id-\(name)", parentId: "5", name: name, isDir: dir, kind: dir ? "folder" : (video ? "video" : "doc"),
                 size: size, pickCode: pick, sha1: "", updatedAt: "", thumbUrl: "")
    }

    private func wait(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    func testEnqueueSkipsFoldersDuplicatesAndFilesWithoutPickCode() {
        let (manager, _) = makeManager(maxConcurrent: 1)
        RoutedURLProtocol.install { _ in .init(status: 503) }
        manager.requestProvider = { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000); return URLRequest(url: URL(string: "https://x.test")!) }
        let summary = manager.enqueue([
            file("A.mp4", pick: "p1"), file("A copy.mp4", pick: "p1"), file("Folder", pick: "p2", dir: true),
            file("B.mp4", pick: ""), file("C.mp4", pick: "p3"),
        ], folderLabel: "网盘 / 电影")
        XCTAssertEqual(summary, DownloadEnqueueSummary(added: 2, duplicates: 1, folders: 1, unavailable: 1))
        XCTAssertEqual(manager.items.map(\.name), ["A.mp4", "C.mp4"])
        XCTAssertEqual(manager.items.map(\.state), [.downloading, .queued])
        XCTAssertEqual(manager.items.first?.folderLabel, "网盘 / 电影")
        manager.pauseAll()
    }

    func testVideoDownloadEndsUpInTheLocalLibrary() async throws {
        let (manager, media) = makeManager()
        RoutedURLProtocol.install { _ in .init(status: 200, headers: ["Content-Length": "10"], body: sampleBody) }
        manager.enqueue([file("示例影片.mp4", size: 10)], folderLabel: "网盘")
        let finished = await wait { manager.items.first?.state == .completed }
        XCTAssertTrue(finished, manager.items.first?.message ?? "")
        let item = try XCTUnwrap(manager.items.first)
        XCTAssertTrue(item.savedInLibrary)
        XCTAssertEqual(item.savedName, "示例影片.mp4")
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("示例影片.mp4")), sampleBody)
        XCTAssertEqual(media.files.map(\.name), ["示例影片.mp4"])
        XCTAssertEqual(manager.fileURL(for: item)?.lastPathComponent, "示例影片.mp4")
        XCTAssertEqual(manager.completed.count, 1)
        XCTAssertTrue(manager.unfinished.isEmpty)
        // 半成品已经改名移走，不留垃圾
        let parts = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("parts").path).filter { $0.hasSuffix(".part") }
        XCTAssertTrue(parts.isEmpty)
    }

    func testOtherFilesGoToTheDownloadsFolder() async throws {
        let (manager, media) = makeManager()
        RoutedURLProtocol.install { _ in .init(status: 200, headers: ["Content-Length": "10"], body: sampleBody) }
        manager.enqueue([file("字幕.srt", size: 10, video: false), file("老片.rmvb", pick: "pc2", size: 10)], folderLabel: "网盘")
        let finished = await wait { manager.completed.count == 2 }
        XCTAssertTrue(finished)
        XCTAssertTrue(manager.completed.allSatisfy { !$0.savedInLibrary })
        XCTAssertTrue(FileManager.default.fileExists(atPath: loose.appendingPathComponent("字幕.srt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: loose.appendingPathComponent("老片.rmvb").path))
        XCTAssertTrue(media.files.isEmpty)
    }

    func testExpiredAddressIsRefreshedOnce() async throws {
        let (manager, _) = makeManager()
        let counter = Counter()
        manager.requestProvider = { _ in
            counter.increment()
            return URLRequest(url: URL(string: "https://dl.example.test/file")!)
        }
        RoutedURLProtocol.install { _ in
            counter.value == 1 ? .init(status: 403) : .init(status: 200, headers: ["Content-Length": "10"], body: sampleBody)
        }
        manager.enqueue([file("a.mp4")], folderLabel: "网盘")
        let finished = await wait { manager.items.first?.state == .completed }
        XCTAssertTrue(finished, manager.items.first?.message ?? "")
        XCTAssertEqual(counter.value, 2)
    }

    func testServerErrorsAreRetriedThenFailAndCanBeRetriedByHand() async throws {
        let (manager, _) = makeManager()
        RoutedURLProtocol.install { _ in .init(status: 503) }
        manager.enqueue([file("a.mp4")], folderLabel: "网盘")
        let failed = await wait { manager.items.first?.state == .failed }
        XCTAssertTrue(failed)
        XCTAssertEqual(RoutedURLProtocol.requests().count, 3, "第一次加两次重试")
        XCTAssertTrue(manager.items.first?.message.contains("503") == true)

        RoutedURLProtocol.install { _ in .init(status: 200, headers: ["Content-Length": "10"], body: sampleBody) }
        let id = try XCTUnwrap(manager.items.first?.id)
        manager.resume(id)
        let finished = await wait { manager.items.first?.state == .completed }
        XCTAssertTrue(finished)
    }

    func testNotLoggedInFailsWithoutNetwork() async {
        let (manager, _) = makeManager()
        manager.requestProvider = nil
        RoutedURLProtocol.install { _ in .init(status: 200) }
        manager.enqueue([file("a.mp4")], folderLabel: "网盘")
        let failed = await wait { manager.items.first?.state == .failed }
        XCTAssertTrue(failed)
        XCTAssertTrue(manager.items.first?.message.contains("登录") == true)
        XCTAssertTrue(RoutedURLProtocol.requests().isEmpty)
    }

    func testNotEnoughSpaceFailsBeforeDownloading() async {
        let (manager, _) = makeManager(freeSpace: { 1024 })
        RoutedURLProtocol.install { _ in .init(status: 200) }
        manager.enqueue([file("big.mp4", size: 5 * 1024 * 1024 * 1024)], folderLabel: "网盘")
        let failed = await wait { manager.items.first?.state == .failed }
        XCTAssertTrue(failed)
        XCTAssertTrue(manager.items.first?.message.contains("存储空间不足") == true)
        XCTAssertTrue(RoutedURLProtocol.requests().isEmpty)
    }

    func testQueuedItemsCanBePausedAndResumed() async throws {
        let (manager, _) = makeManager(maxConcurrent: 1)
        let gate = Gate()
        manager.requestProvider = { _ in
            await gate.wait()
            return URLRequest(url: URL(string: "https://dl.example.test/file")!)
        }
        RoutedURLProtocol.install { _ in .init(status: 200, headers: ["Content-Length": "10"], body: sampleBody) }
        manager.enqueue([file("a.mp4", pick: "p1"), file("b.mp4", pick: "p2")], folderLabel: "网盘")
        XCTAssertEqual(manager.items.map(\.state), [.downloading, .queued])
        let second = manager.items[1].id
        manager.pause(second)
        XCTAssertEqual(manager.items[1].state, .paused)
        gate.open()
        let firstDone = await wait { manager.items[0].state == .completed }
        XCTAssertTrue(firstDone)
        XCTAssertEqual(manager.items[1].state, .paused, "暂停的不会被自动开始")
        manager.resume(second)
        let secondDone = await wait { manager.items[1].state == .completed }
        XCTAssertTrue(secondDone)
    }

    func testPausingARunningDownloadFreesTheSlot() async throws {
        let (manager, _) = makeManager(maxConcurrent: 1)
        manager.requestProvider = { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000); return URLRequest(url: URL(string: "https://x.test")!) }
        manager.enqueue([file("a.mp4", pick: "p1"), file("b.mp4", pick: "p2")], folderLabel: "网盘")
        XCTAssertEqual(manager.items.map(\.state), [.downloading, .queued])
        manager.pause(manager.items[0].id)
        XCTAssertEqual(manager.items.map(\.state), [.paused, .downloading])
        manager.pauseAll()
        XCTAssertEqual(manager.items.map(\.state), [.paused, .paused])
        XCTAssertEqual(manager.activeCount, 0)
    }

    func testUnfinishedDownloadsComeBackPausedWithTheirRealProgress() async throws {
        let (first, _) = makeManager(maxConcurrent: 1)
        first.requestProvider = { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000); return URLRequest(url: URL(string: "https://x.test")!) }
        first.enqueue([file("a.mp4", size: 100)], folderLabel: "网盘 / 电影")
        let id = try XCTUnwrap(first.items.first?.id)
        let parts = root.appendingPathComponent("parts", isDirectory: true)
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 40).write(to: parts.appendingPathComponent("\(id.uuidString).part"))

        let (second, _) = makeManager()
        let restored = try XCTUnwrap(second.items.first)
        XCTAssertEqual(restored.id, id)
        XCTAssertEqual(restored.state, .paused)
        XCTAssertEqual(restored.receivedBytes, 40)
        XCTAssertEqual(restored.folderLabel, "网盘 / 电影")
        first.pauseAll()
    }

    func testDeletingACompletedDownloadRemovesTheFileButNotTheCloudOne() async throws {
        let (manager, media) = makeManager()
        RoutedURLProtocol.install { _ in .init(status: 200, headers: ["Content-Length": "10"], body: sampleBody) }
        manager.enqueue([file("a.mp4")], folderLabel: "网盘")
        let finished = await wait { manager.items.first?.state == .completed }
        XCTAssertTrue(finished)
        let item = try XCTUnwrap(manager.items.first)
        let url = try XCTUnwrap(manager.fileURL(for: item))
        manager.delete(item.id)
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(media.files.isEmpty)
    }

    func testClearingRecordsKeepsTheFiles() async throws {
        let (manager, _) = makeManager()
        RoutedURLProtocol.install { _ in .init(status: 200, headers: ["Content-Length": "10"], body: sampleBody) }
        manager.enqueue([file("a.mp4")], folderLabel: "网盘")
        let finished = await wait { manager.items.first?.state == .completed }
        XCTAssertTrue(finished)
        manager.clearCompletedRecords()
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appendingPathComponent("a.mp4").path))
    }

    func testDeletedLocalFileMakesTheRecordUnplayable() async throws {
        let (manager, media) = makeManager()
        RoutedURLProtocol.install { _ in .init(status: 200, headers: ["Content-Length": "10"], body: sampleBody) }
        manager.enqueue([file("a.mp4")], folderLabel: "网盘")
        let finished = await wait { manager.items.first?.state == .completed }
        XCTAssertTrue(finished)
        let item = try XCTUnwrap(manager.items.first)
        media.delete(try XCTUnwrap(media.files.first))
        XCTAssertNil(manager.fileURL(for: item))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

/// 让异步代码停在这里，直到测试放行
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false

    func open() {
        lock.lock(); defer { lock.unlock() }
        opened = true
    }

    func wait() async {
        while true {
            lock.lock()
            let isOpen = opened
            lock.unlock()
            if isOpen { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
