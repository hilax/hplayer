import Combine
import XCTest
@testable import HPlayer

/// 播放时界面刷新的频率：内核每一帧都会报告播放时间，缓存和网速也一直在变，
/// 但播放页只该在看得出变化时重算，不能跟着视频帧率一秒重算几十次（手机会发烫）。
@MainActor
final class PlaybackRefreshTests: XCTestCase {
    private func playingController() throws -> PlaybackController {
        let player = PlaybackController()
        player.open(try XCTUnwrap(URL(string: "https://example.com/video.mkv")), autoRecover: false)
        player.receiveEventForTesting(.fileLoaded)
        player.receiveEventForTesting(.property("duration", .double(600)))
        player.receiveEventForTesting(.property("seekable", .flag(true)))
        player.receiveEventForTesting(.playbackRestart)
        player.receiveEventForTesting(.property("time-pos", .double(10)))
        return player
    }

    func test115WaitsForPlaybackStartAfterLoadingTheFile() throws {
        let player = PlaybackController()
        defer { player.stop() }
        player.open(try XCTUnwrap(URL(string: "https://example.com/original.mkv")), direct115: true, autoRecover: false)

        player.receiveEventForTesting(.playbackRestart)
        XCTAssertFalse(player.hasPlayed, "An event from the previous file cannot mark this file as started")
        player.receiveEventForTesting(.fileLoaded)
        XCTAssertFalse(player.hasPlayed)
        XCTAssertTrue(player.buffering)

        player.receiveEventForTesting(.playbackRestart)
        XCTAssertTrue(player.hasPlayed)
        XCTAssertFalse(player.buffering)
    }

    func test115ReopensAtLatestSeekWithOneAddressRequest() async throws {
        let player = PlaybackController()
        let url = try XCTUnwrap(URL(string: "https://example.com/original.mkv"))
        let (addresses, releaseAddress) = AsyncStream<URL>.makeStream()
        let refreshing = expectation(description: "address refresh started")
        var refreshCount = 0
        defer { releaseAddress.finish(); player.stop() }
        player.open(url, direct115: true, refreshURL: {
            refreshCount += 1
            if refreshCount == 1 { refreshing.fulfill() }
            return await addresses.first(where: { _ in true }) ?? url
        })
        player.receiveEventForTesting(.fileLoaded)
        player.receiveEventForTesting(.playbackRestart)
        player.receiveEventForTesting(.property("duration", .double(300)))
        player.receiveEventForTesting(.property("seekable", .flag(true)))
        player.receiveEventForTesting(.property("time-pos", .double(10)))

        player.retry()
        await fulfillment(of: [refreshing], timeout: 2)
        player.seek(to: 180)
        player.seek(to: 70)
        player.receiveEventForTesting(.playbackRestart)
        player.receiveEventForTesting(.property("time-pos", .double(180)))
        releaseAddress.yield(url)
        releaseAddress.finish()

        for _ in 0..<100 {
            if player.diagnostics.contains("打开 example.com，从 01:10") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(refreshCount, 1)
        XCTAssertTrue(player.diagnostics.contains("打开 example.com，从 01:10"), player.diagnostics)
    }

    func testFramePositionUpdatesDoNotRefreshThePlayerEveryFrame() throws {
        let player = try playingController()
        var refreshes = 0
        let subscription = player.objectWillChange.sink { refreshes += 1 }
        defer { subscription.cancel() }

        // 一秒 60 帧
        for frame in 1...60 {
            player.receiveEventForTesting(.property("time-pos", .double(10 + Double(frame) / 60)))
        }

        XCTAssertLessThanOrEqual(refreshes, 10, "60 帧的播放时间只应让播放页刷新几次，实际 \(refreshes) 次")
        XCTAssertEqual(player.engineTime, 11, accuracy: 0.001, "内部仍然记着最新的真实播放时间")
        XCTAssertEqual(player.currentTime, 11, accuracy: 0.26)
    }

    func testCacheAndSpeedRefreshOnlyOnVisibleChanges() throws {
        let player = try playingController()
        var refreshes = 0
        let subscription = player.objectWillChange.sink { refreshes += 1 }
        defer { subscription.cancel() }

        player.receiveEventForTesting(.property("cache-speed", .int(1_000_000)))
        player.receiveEventForTesting(.property("cache-speed", .int(1_010_000)))
        player.receiveEventForTesting(.property("demuxer-cache-duration", .double(30)))
        player.receiveEventForTesting(.property("demuxer-cache-duration", .double(30.2)))
        player.receiveEventForTesting(.property("demuxer-cache-time", .double(40)))
        player.receiveEventForTesting(.property("demuxer-cache-time", .double(40.1)))

        XCTAssertEqual(refreshes, 3, "网速差 1%、缓存差零点几秒都看不出来，不该让播放页重算")
        XCTAssertEqual(player.downloadSpeed, 1_000_000)
        XCTAssertEqual(player.cachedSeconds, 30, accuracy: 0.01)
        XCTAssertEqual(player.bufferedUntil, 40, accuracy: 0.01)

        // 缓存用光、网速掉到 0 一定要显示出来
        player.receiveEventForTesting(.property("demuxer-cache-duration", .double(0.3)))
        player.receiveEventForTesting(.property("cache-speed", .int(0)))
        XCTAssertEqual(player.cachedSeconds, 0.3, accuracy: 0.01)
        XCTAssertEqual(player.downloadSpeed, 0)
    }

    func testSoftwareFallbackIsDiagnosedAndExplainedOnce() async throws {
        let player = try playingController()
        try XCTSkipIf(player.decoding != .hardware, "这台模拟器上保存的是软解码")

        player.receiveEventForTesting(.property("hwdec-current", .string("videotoolbox")))
        XCTAssertTrue(player.diagnostics.contains("实际：videotoolbox"))

        // 选的是硬解码，内核却退回了软解码：两秒后提示一次发热的原因
        player.receiveEventForTesting(.property("hwdec-current", .string("no")))
        XCTAssertTrue(player.diagnostics.contains("实际：no"))
        try await Task.sleep(nanoseconds: 2_400_000_000)
        XCTAssertTrue(player.notice.contains("软解码"), "退回软解码要告诉用户：\(player.notice)")

        // 同一个视频不重复提示
        player.notice = ""
        player.receiveEventForTesting(.property("hwdec-current", .none))
        player.receiveEventForTesting(.property("hwdec-current", .string("no")))
        try await Task.sleep(nanoseconds: 2_400_000_000)
        XCTAssertEqual(player.notice, "")
    }

    func testDeferredAutoPlayReleasesCleanlyAndRespectsClose() throws {
        let player = PlaybackController()
        defer { player.stop() }
        let url = try XCTUnwrap(URL(string: "https://example.com/original.mp4"))

        player.open(url, direct115: true, autoRecover: false, deferAutoPlay: true)
        XCTAssertTrue(player.playing, "预热暂挂不改变用户的播放意图，避免首帧闪现暂停按钮")
        XCTAssertTrue(player.buffering)

        player.releaseRevealHold()
        player.receiveEventForTesting(.fileLoaded)
        player.receiveEventForTesting(.playbackRestart)
        XCTAssertTrue(player.hasPlayed)
        XCTAssertTrue(player.playing)
        XCTAssertFalse(player.buffering)

        // 若窗口在淡入前就被关闭，随后到达的 releaseRevealHold 不能重新恢复播放
        player.open(url, direct115: true, autoRecover: false, deferAutoPlay: true)
        player.pauseForClose()
        player.releaseRevealHold()
        XCTAssertFalse(player.playing)
    }

    func testDiskCacheTierDefaultsToTwoGBAndSupportsTwentyGB() {
        let key = "player.cacheStorageMode"
        let previous = UserDefaults.standard.string(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(CacheStorageMode.saved, .disk)
        XCTAssertEqual(CacheStorageMode.disk.diskCapMiB, 2048)
        XCTAssertEqual(CacheStorageMode.diskLarge.diskCapMiB, 20480)

        // 旧版本若曾保存过 "memory"，回退后自动安全回落到默认磁盘 2GB
        UserDefaults.standard.set("memory", forKey: key)
        XCTAssertEqual(CacheStorageMode.saved, .disk)

        let large = PlayerDiskCache.limitMiB(capMiB: CacheStorageMode.diskLarge.diskCapMiB)
        XCTAssertGreaterThanOrEqual(large, 64)
        XCTAssertLessThanOrEqual(large, 20480)
        XCTAssertGreaterThanOrEqual(large, PlayerDiskCache.limitMiB())
    }
}
