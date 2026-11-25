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

    func testDiskCacheTierDefaultsToTwentyGBAndSupportsTwoGB() {
        let key = "player.cacheStorageMode"
        let previous = UserDefaults.standard.string(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(CacheStorageMode.saved, .diskLarge)
        XCTAssertEqual(CacheStorageMode.diskLarge.diskCapMiB, 20480)
        XCTAssertEqual(CacheStorageMode.diskLarge.diskBackMiB, 1024)
        XCTAssertEqual(CacheStorageMode.disk.diskCapMiB, 2048)
        XCTAssertEqual(CacheStorageMode.disk.diskBackMiB, 256)

        // 旧版本若曾保存过 "memory"，回退后自动安全回落到默认磁盘 20GB（仍受设备剩余空间限制）
        UserDefaults.standard.set("memory", forKey: key)
        XCTAssertEqual(CacheStorageMode.saved, .diskLarge)

        let large = PlayerDiskCache.limitMiB(capMiB: CacheStorageMode.diskLarge.diskCapMiB)
        XCTAssertGreaterThanOrEqual(large, 64)
        XCTAssertLessThanOrEqual(large, 20480)
        XCTAssertGreaterThanOrEqual(large, PlayerDiskCache.limitMiB())
    }

    func testRapidSeekIgnoresStaleRestartWhileCommandInFlightAndAvoidsTransientBuffering() throws {
        let player = try playingController()
        defer { player.stop() }

        player.seek(to: 180)
        XCTAssertFalse(player.buffering, "普通快速关键帧跳转未欠载时不应强制置 buffering，避免闪烁和阻止控件隐藏")

        // 模拟更新一次异步 seek 仍在 mpv 命令队列中未回包：旧的 playbackRestart 不得提前结算
        player.setInFlightSeekCommandsForTesting(1)
        player.receiveEventForTesting(.property("time-pos", .double(180)))
        player.receiveEventForTesting(.playbackRestart)
        XCTAssertEqual(player.confirmedTime ?? -1, 10, accuracy: 0.01, "在途 seek 命令未完成前不得误结算旧 playbackRestart")

        // 在途命令回包归零后，新的 playbackRestart 才正式确认落地位置
        player.setInFlightSeekCommandsForTesting(0)
        player.receiveEventForTesting(.property("time-pos", .double(180)))
        player.receiveEventForTesting(.playbackRestart)
        XCTAssertEqual(player.confirmedTime ?? -1, 180, accuracy: 0.01)
    }

    func testHealthyPlaybackResetsLargerPauseWaitAfter25Seconds() async throws {
        let player = PlaybackController()
        defer { player.stop() }
        player.open(try XCTUnwrap(URL(string: "https://example.com/video.mkv")), autoRecover: true)
        player.receiveEventForTesting(.fileLoaded)
        player.receiveEventForTesting(.property("duration", .double(300)))
        player.receiveEventForTesting(.property("seekable", .flag(true)))
        player.receiveEventForTesting(.playbackRestart)
        player.receiveEventForTesting(.property("time-pos", .double(25)))
        player.receiveEventForTesting(.property("paused-for-cache", .flag(true)))

        // 触发一次恢复，开启保守的 2.5s cache-pause-wait
        for _ in 0..<8 { player.checkHealthForTesting() }
        XCTAssertTrue(player.preferLargerPauseWaitForTesting)
        try await Task.sleep(nanoseconds: 80_000_000)

        // 重开并稳定播放满 25 秒后，应自动恢复为轻快 1s 档位
        player.receiveEventForTesting(.fileLoaded)
        player.receiveEventForTesting(.playbackRestart)
        player.receiveEventForTesting(.property("paused-for-cache", .flag(false)))
        player.receiveEventForTesting(.property("time-pos", .double(26)))
        for _ in 0..<25 { player.checkHealthForTesting() }

        XCTAssertFalse(player.preferLargerPauseWaitForTesting, "稳定播放 25 秒后应把 cache-pause-wait 恢复回默认 1 秒")
    }

    func testKeyframeSeekAllowsDecodedKeyframeRollbackWithoutFalseJumpDiscard() throws {
        let player = try playingController()
        defer { player.stop() }

        // 复现真机日志场景：从 02:05 关键帧跳转到 04:32，mpv 先按目标 04:32 重启，紧接着上报真实关键帧 04:26
        player.seek(to: 125)
        player.receiveEventForTesting(.property("time-pos", .double(125)))
        player.receiveEventForTesting(.playbackRestart)

        player.seek(to: 272)
        player.receiveEventForTesting(.property("time-pos", .double(272)))
        player.receiveEventForTesting(.playbackRestart)
        XCTAssertEqual(player.confirmedTime ?? -1, 272, accuracy: 0.01)

        player.receiveEventForTesting(.property("time-pos", .double(266)))
        XCTAssertEqual(player.currentTime, 266, accuracy: 0.01, "真实解码出的关键帧回落不应被误判为异常跳变")
        XCTAssertEqual(player.confirmedTime ?? -1, 266, accuracy: 0.01)
        XCTAssertFalse(player.diagnostics.contains("忽略未播放的位置跳变"), player.diagnostics)

        // 紧跟着若出现异常直冲片尾的脏时间，依然必须拦截
        player.receiveEventForTesting(.property("time-pos", .double(599.5)))
        XCTAssertEqual(player.confirmedTime ?? -1, 266, accuracy: 0.01)
    }

    func testSlowSeekShowsBufferingAfterThresholdAndClearsOnSettle() async throws {
        let player = try playingController()
        defer { player.stop() }

        player.seek(to: 180)
        XCTAssertFalse(player.buffering, "刚触发快速跳转时不应立刻闪烁缓冲态")

        // 超过 0.6s 仍未出画时点亮缓冲态，避免像死机一样无反馈
        try await Task.sleep(nanoseconds: 750_000_000)
        XCTAssertTrue(player.buffering, "长时间未落地的慢跳转应显示缓冲状态")

        player.receiveEventForTesting(.property("time-pos", .double(180)))
        player.receiveEventForTesting(.playbackRestart)
        XCTAssertFalse(player.buffering, "跳转落地后必须立即清除缓冲态")
    }

    func testSeekCommandFlagsUseKeyframesForAllNetworkScrubDistances() {
        // 网络流滑动/拖动：无论 15 秒短滑还是跨度很大的拖动，统一走关键帧
        let shortScrub = PlaybackController.seekCommandFlags(target: 25, duration: 600, isLocalFile: false, exact: false)
        XCTAssertEqual(shortScrub.flags, "absolute+keyframes")
        XCTAssertTrue(shortScrub.usesKeyframes)

        let farScrub = PlaybackController.seekCommandFlags(target: 360, duration: 600, isLocalFile: false, exact: false)
        XCTAssertEqual(farScrub.flags, "absolute+keyframes")
        XCTAssertTrue(farScrub.usesKeyframes)

        let unknownDuration = PlaybackController.seekCommandFlags(target: 40, duration: 0, isLocalFile: false, exact: false)
        XCTAssertEqual(unknownDuration.flags, "absolute+keyframes")
        XCTAssertTrue(unknownDuration.usesKeyframes)

        // 显式精确跳转（双击快进退、画中画步进）、本地文件、以及紧贴片尾 15 秒内仍保持精确
        let explicitExact = PlaybackController.seekCommandFlags(target: 25, duration: 600, isLocalFile: false, exact: true)
        XCTAssertEqual(explicitExact.flags, "absolute+exact")
        XCTAssertFalse(explicitExact.usesKeyframes)

        let localFile = PlaybackController.seekCommandFlags(target: 300, duration: 600, isLocalFile: true, exact: false)
        XCTAssertEqual(localFile.flags, "absolute+exact")
        XCTAssertFalse(localFile.usesKeyframes)

        let nearTail = PlaybackController.seekCommandFlags(target: 590, duration: 600, isLocalFile: false, exact: false)
        XCTAssertEqual(nearTail.flags, "absolute+exact")
        XCTAssertFalse(nearTail.usesKeyframes)
    }
}
