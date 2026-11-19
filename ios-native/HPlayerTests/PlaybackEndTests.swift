import XCTest
@testable import HPlayer

@MainActor
final class PlaybackEndTests: XCTestCase {
    private func player(at time: Double, duration: Double = 300) throws -> PlaybackController {
        let player = PlaybackController()
        player.open(try XCTUnwrap(URL(string: "https://example.com/video.mkv")), autoRecover: false)
        player.receiveEventForTesting(.fileLoaded)
        player.receiveEventForTesting(.property("duration", .double(duration)))
        player.receiveEventForTesting(.property("seekable", .flag(true)))
        player.receiveEventForTesting(.playbackRestart)
        player.receiveEventForTesting(.property("time-pos", .double(time)))
        return player
    }

    func testSeekTargetNearEndDoesNotCountAsPlaybackAtTheEnd() throws {
        let player = try player(at: 20)
        player.seek(to: 295)
        XCTAssertEqual(player.confirmedTime ?? -1, 20, accuracy: 0.01)
        player.receiveEventForTesting(.property("time-pos", .double(299)))
        player.receiveEventForTesting(.property("eof-reached", .flag(true)))
        player.receiveEventForTesting(.playbackRestart)
        XCTAssertFalse(player.ended, "A requested seek target is not a confirmed playback position")
        XCTAssertEqual(player.confirmedTime ?? -1, 20, accuracy: 0.01, "A stale position must not overwrite viewing history")

        player.receiveEventForTesting(.property("seeking", .flag(true)))
        player.receiveEventForTesting(.property("eof-reached", .flag(false)))
        player.receiveEventForTesting(.property("time-pos", .double(294)))
        player.receiveEventForTesting(.playbackRestart)
        player.receiveEventForTesting(.property("seeking", .flag(false)))
        XCTAssertFalse(player.ended)
        XCTAssertEqual(player.confirmedTime ?? -1, 294, accuracy: 0.01)

        for time in [295.0, 296, 297, 298, 299.5] {
            player.receiveEventForTesting(.property("time-pos", .double(time)))
        }
        player.receiveEventForTesting(.property("eof-reached", .flag(true)))
        XCTAssertTrue(player.ended, "A real EOF after playback reaches the end must still advance")
    }

    func testStaleEndEventsDuringBackwardSeekCannotEndTheVideo() throws {
        let player = try player(at: 299)
        player.seek(to: 100)
        player.receiveEventForTesting(.property("time-pos", .double(299)))
        player.receiveEventForTesting(.property("eof-reached", .flag(true)))
        player.receiveEventForTesting(.playbackRestart)
        XCTAssertFalse(player.ended)
        XCTAssertEqual(player.currentTime, 100, accuracy: 0.01)

        player.receiveEventForTesting(.property("time-pos", .double(100)))
        player.receiveEventForTesting(.property("seeking", .flag(false)))
        XCTAssertFalse(player.ended)
        XCTAssertEqual(player.currentTime, 100, accuracy: 0.01)
    }

    func testRapidSeeksKeepTheMostRecentTarget() throws {
        let player = try player(at: 10)
        player.seek(to: 180)
        player.seek(to: 70)
        player.receiveEventForTesting(.property("time-pos", .double(180)))
        player.receiveEventForTesting(.playbackRestart)
        player.receiveEventForTesting(.property("eof-reached", .flag(true)))
        XCTAssertFalse(player.ended)
        XCTAssertEqual(player.currentTime, 70, accuracy: 0.01)

        player.receiveEventForTesting(.property("time-pos", .double(70)))
        player.receiveEventForTesting(.property("seeking", .flag(false)))
        XCTAssertFalse(player.ended)
        XCTAssertEqual(player.currentTime, 70, accuracy: 0.01)
    }

    func testBufferingRestartCannotConfirmASeekOrFinishTheVideo() throws {
        let player = try player(at: 20)
        defer { player.stop() }
        player.seek(to: 120)
        player.receiveEventForTesting(.property("paused-for-cache", .flag(true)))
        player.receiveEventForTesting(.property("time-pos", .double(120)))
        player.receiveEventForTesting(.playbackRestart)
        XCTAssertEqual(player.confirmedTime ?? -1, 20, accuracy: 0.01,
                       "A target reported while still buffering is not decoded playback")
        player.receiveEventForTesting(.property("time-pos", .double(299.5)))
        player.receiveEventForTesting(.property("eof-reached", .flag(true)))
        XCTAssertFalse(player.ended)
        XCTAssertEqual(player.currentTime, 120, accuracy: 0.01)

        player.receiveEventForTesting(.property("eof-reached", .flag(false)))
        player.receiveEventForTesting(.property("time-pos", .double(120)))
        player.receiveEventForTesting(.property("paused-for-cache", .flag(false)))
        player.receiveEventForTesting(.property("time-pos", .double(121)))
        XCTAssertEqual(player.confirmedTime ?? -1, 121, accuracy: 0.01)
        XCTAssertTrue(player.playing)
    }

    func testUnrequestedJumpToEOFJustAfterSeekCannotFinishPlayback() throws {
        let player = try player(at: 20)
        defer { player.stop() }
        player.seek(to: 120)
        player.receiveEventForTesting(.property("time-pos", .double(120)))
        player.receiveEventForTesting(.playbackRestart)
        XCTAssertEqual(player.confirmedTime ?? -1, 120, accuracy: 0.01)

        // A failed network read can report the file tail after seeking has cleared.
        player.receiveEventForTesting(.property("time-pos", .double(299.5)))
        player.receiveEventForTesting(.endFile(reason: 0, error: nil))
        XCTAssertFalse(player.ended)
        XCTAssertEqual(player.currentTime, 120, accuracy: 0.01)
        XCTAssertEqual(player.confirmedTime ?? -1, 120, accuracy: 0.01,
                       "Neither the timeline nor viewing history may jump to an unplayed ending")

        player.seek(to: 100)
        XCTAssertTrue(player.playing)
        XCTAssertFalse(player.ended)
        XCTAssertEqual(player.currentTime, 100, accuracy: 0.01)
    }

    func testInvalidTimeNotificationsCannotCorruptTheTimeline() throws {
        let player = try player(at: 20)
        defer { player.stop() }
        for value in [Double.nan, .infinity, -.infinity, -1] {
            player.receiveEventForTesting(.property("time-pos", .double(value)))
        }
        XCTAssertEqual(player.currentTime, 20, accuracy: 0.01)
        XCTAssertEqual(player.confirmedTime ?? -1, 20, accuracy: 0.01)
    }

    func testAnUnplayedTailAfterANearEndSeekDoesNotFinishPlayback() throws {
        let player = try player(at: 20)
        defer { player.stop() }
        player.seek(to: 295)
        player.receiveEventForTesting(.property("time-pos", .double(295)))
        player.receiveEventForTesting(.playbackRestart)
        player.receiveEventForTesting(.property("time-pos", .double(299.5)))
        player.receiveEventForTesting(.property("eof-reached", .flag(true)))
        XCTAssertFalse(player.ended, "Even a seek near the end must play the remaining video")
        XCTAssertEqual(player.currentTime, 295, accuracy: 0.01)
        player.receiveEventForTesting(.property("eof-reached", .flag(false)))
        for time in [296.0, 297, 298, 299.5] {
            player.receiveEventForTesting(.property("time-pos", .double(time)))
        }
        player.receiveEventForTesting(.property("eof-reached", .flag(true)))
        XCTAssertTrue(player.ended, "Natural progress through the tail must still finish playback")
    }

    func testKeptOpenEOFDuringSeekRecoversDespiteIncomingCacheData() throws {
        let player = PlaybackController()
        defer { player.stop() }
        player.open(try XCTUnwrap(URL(string: "https://example.com/video.mkv")))
        player.receiveEventForTesting(.fileLoaded)
        player.receiveEventForTesting(.property("duration", .double(300)))
        player.receiveEventForTesting(.property("seekable", .flag(true)))
        player.receiveEventForTesting(.playbackRestart)
        player.receiveEventForTesting(.property("time-pos", .double(20)))
        player.seek(to: 200)
        player.receiveEventForTesting(.property("time-pos", .double(299.5)))
        player.receiveEventForTesting(.property("eof-reached", .flag(true)))
        player.receiveEventForTesting(.playbackRestart)
        player.receiveEventForTesting(.property("cache-speed", .int(1024)))
        player.checkHealthForTesting()
        XCTAssertFalse(player.ended)
        XCTAssertTrue(player.playing)
        XCTAssertTrue(player.buffering)
        XCTAssertTrue(player.statusNote.contains("跳转未完成"), "A false EOF must recover even if packets keep arriving")
        XCTAssertEqual(player.currentTime, 200, accuracy: 0.01)
        XCTAssertEqual(player.confirmedTime ?? -1, 20, accuracy: 0.01)
    }

    func testEOFPauseDuringRapidSeeksDoesNotBecomeAUserPause() throws {
        let player = try player(at: 20)
        defer { player.stop() }
        player.seek(to: 295)
        player.receiveEventForTesting(.property("pause", .flag(true)))
        player.receiveEventForTesting(.property("eof-reached", .flag(true)))
        player.seek(to: 120)
        // The first seek's pause can arrive after the second seek was sent.
        player.receiveEventForTesting(.property("pause", .flag(true)))
        player.receiveEventForTesting(.property("time-pos", .double(299)))
        player.receiveEventForTesting(.playbackRestart)
        XCTAssertTrue(player.playing, "An EOF pause must not disable seek recovery")
        XCTAssertFalse(player.ended)
        XCTAssertEqual(player.currentTime, 120, accuracy: 0.01)
        XCTAssertEqual(player.confirmedTime ?? -1, 20, accuracy: 0.01)

        player.receiveEventForTesting(.property("eof-reached", .flag(false)))
        player.receiveEventForTesting(.property("time-pos", .double(120)))
        player.receiveEventForTesting(.property("seeking", .flag(false)))
        player.receiveEventForTesting(.property("time-pos", .double(121)))
        XCTAssertTrue(player.playing)
        XCTAssertEqual(player.confirmedTime ?? -1, 121, accuracy: 0.01)
    }

    func testPausedRapidSeeksStayPausedDespiteStaleEvents() throws {
        let player = try player(at: 20)
        defer { player.stop() }
        player.toggle()
        player.seek(to: 295)
        player.receiveEventForTesting(.property("eof-reached", .flag(true)))
        player.seek(to: 120)
        XCTAssertFalse(player.playing, "An unconfirmed EOF must not resume a paused video")
        player.receiveEventForTesting(.property("pause", .flag(false)))
        player.receiveEventForTesting(.property("eof-reached", .flag(false)))
        player.receiveEventForTesting(.property("time-pos", .double(120)))
        player.receiveEventForTesting(.playbackRestart)
        XCTAssertFalse(player.playing, "A queued pause notification must not override the latest control")
        XCTAssertFalse(player.ended)
        XCTAssertEqual(player.currentTime, 120, accuracy: 0.01)
    }

    func testRestartCannotConfirmASeekWhileTheEngineIsStillSeeking() throws {
        let player = try player(at: 20)
        defer { player.stop() }
        player.seek(to: 180)
        player.seek(to: 170)
        player.receiveEventForTesting(.property("seeking", .flag(true)))
        player.receiveEventForTesting(.property("time-pos", .double(170)))
        player.receiveEventForTesting(.playbackRestart)
        XCTAssertEqual(player.confirmedTime ?? -1, 20, accuracy: 0.01)
        player.receiveEventForTesting(.property("time-pos", .double(299.5)))
        player.receiveEventForTesting(.property("eof-reached", .flag(true)))
        XCTAssertFalse(player.ended)
        XCTAssertEqual(player.currentTime, 170, accuracy: 0.01)

        player.receiveEventForTesting(.property("eof-reached", .flag(false)))
        player.receiveEventForTesting(.property("time-pos", .double(170)))
        player.receiveEventForTesting(.property("seeking", .flag(false)))
        XCTAssertEqual(player.confirmedTime ?? -1, 170, accuracy: 0.01)
        XCTAssertTrue(player.playing)
    }

    func testReplayAfterKeptOpenEOFTracksTheSeekFromZero() throws {
        let player = try player(at: 299.5)
        defer { player.stop() }
        player.receiveEventForTesting(.property("eof-reached", .flag(true)))
        XCTAssertTrue(player.ended)
        player.toggle()
        XCTAssertFalse(player.ended)
        XCTAssertTrue(player.playing)
        XCTAssertEqual(player.currentTime, 0, accuracy: 0.01)

        player.receiveEventForTesting(.property("time-pos", .double(299.5)))
        player.receiveEventForTesting(.property("eof-reached", .flag(true)))
        XCTAssertFalse(player.ended, "The previous ending must not finish the replay")
        XCTAssertEqual(player.currentTime, 0, accuracy: 0.01)
        player.receiveEventForTesting(.property("eof-reached", .flag(false)))
        player.receiveEventForTesting(.property("time-pos", .double(0)))
        player.receiveEventForTesting(.playbackRestart)
        player.receiveEventForTesting(.property("time-pos", .double(1)))
        XCTAssertTrue(player.playing)
        XCTAssertEqual(player.confirmedTime ?? -1, 1, accuracy: 0.01)
    }

    func testReplayReloadsAFileThatTheEngineAlreadyClosed() throws {
        let player = try player(at: 299.5)
        defer { player.stop() }
        player.receiveEventForTesting(.endFile(reason: 0, error: nil))
        XCTAssertTrue(player.ended)
        player.toggle()
        XCTAssertFalse(player.ended)
        XCTAssertTrue(player.playing)
        XCTAssertTrue(player.buffering, "A closed file needs to be reopened before replay")
        XCTAssertEqual(player.currentTime, 0, accuracy: 0.01)
    }

    func testInterruptedPausedSeekCanResumeFromTheLatestTarget() throws {
        let player = try player(at: 20)
        defer { player.stop() }
        player.toggle()
        player.seek(to: 200)
        player.receiveEventForTesting(.endFile(reason: 0, error: nil))
        XCTAssertFalse(player.ended)
        XCTAssertFalse(player.playing)
        player.toggle()
        XCTAssertTrue(player.playing)
        XCTAssertTrue(player.buffering)
        XCTAssertEqual(player.currentTime, 200, accuracy: 0.01)
    }

    func testRejectedSeekDoesNotChangeTheDisplayedPosition() throws {
        let player = try player(at: 20)
        defer { player.stop() }
        player.receiveEventForTesting(.property("seekable", .flag(false)))
        player.seek(to: 200)
        XCTAssertEqual(player.currentTime, 20, accuracy: 0.01)
        XCTAssertEqual(player.confirmedTime ?? -1, 20, accuracy: 0.01)
    }

    func testPrematureEOFNearButNotAtTheEndDoesNotAdvance() throws {
        let player = try player(at: 296)
        player.receiveEventForTesting(.property("eof-reached", .flag(true)))
        XCTAssertFalse(player.ended)

        player.receiveEventForTesting(.property("eof-reached", .flag(false)))
        player.receiveEventForTesting(.property("time-pos", .double(297)))
        player.receiveEventForTesting(.property("time-pos", .double(298)))
        player.receiveEventForTesting(.property("time-pos", .double(299)))
        player.receiveEventForTesting(.property("eof-reached", .flag(true)))
        XCTAssertTrue(player.ended)
    }

    func testEndFileAtTheActualEndStillFinishesPlayback() throws {
        let player = try player(at: 299.5)
        player.receiveEventForTesting(.endFile(reason: 0, error: nil))
        XCTAssertTrue(player.ended)
        XCTAssertFalse(player.playing)
    }

    func testOldEndEventCannotFinishANewlyOpeningVideo() throws {
        let player = try player(at: 299.5)
        player.open(try XCTUnwrap(URL(string: "https://example.com/next.mkv")), autoRecover: false)
        player.receiveEventForTesting(.endFile(reason: 0, error: nil))
        player.receiveEventForTesting(.property("eof-reached", .flag(true)))
        XCTAssertFalse(player.ended)
        XCTAssertTrue(player.error.isEmpty)

        player.receiveEventForTesting(.fileLoaded)
        player.receiveEventForTesting(.playbackRestart)
        player.receiveEventForTesting(.property("duration", .double(90)))
        player.receiveEventForTesting(.property("time-pos", .double(1)))
        XCTAssertFalse(player.ended)
        XCTAssertEqual(player.confirmedTime ?? -1, 1, accuracy: 0.01)
    }

    func testEndFileDuringSeekWithoutAutoRecoveryShowsRetryInsteadOfAdvancing() throws {
        let player = try player(at: 20)
        player.seek(to: 200)
        // MPV_END_FILE_REASON_EOF is zero; an interrupted transfer can report EOF.
        player.receiveEventForTesting(.endFile(reason: 0, error: nil))
        XCTAssertFalse(player.ended)
        XCTAssertFalse(player.error.isEmpty)
    }

    func testTrickleSpeedBelowThresholdStillTriggersRecoveryAndPreservesCustomHeaders() async throws {
        let player = PlaybackController()
        defer { player.stop() }
        player.open(
            try XCTUnwrap(URL(string: "https://example.com/video.mkv")),
            customHeaders: ["Referer": "https://ref.example.com/", "User-Agent": "CustomUA"],
            autoRecover: true
        )
        player.receiveEventForTesting(.fileLoaded)
        player.receiveEventForTesting(.property("duration", .double(300)))
        player.receiveEventForTesting(.property("seekable", .flag(true)))
        player.receiveEventForTesting(.playbackRestart)
        player.receiveEventForTesting(.property("time-pos", .double(25)))
        player.receiveEventForTesting(.property("paused-for-cache", .flag(true)))

        // 模拟 115 被限速到极慢（2 KB/s < 32 KB/s）并持续 8 秒无法攒出有效缓冲
        var cacheSeconds = 0.0
        for _ in 0..<8 {
            cacheSeconds += 0.05
            player.receiveEventForTesting(.property("cache-speed", .int(2048)))
            player.receiveEventForTesting(.property("demuxer-cache-duration", .double(cacheSeconds)))
            player.checkHealthForTesting()
        }

        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(player.recoveryCountForTesting, 1, "龟速保活（< 32 KB/s）也必须触发恢复，不能永久转圈")
        XCTAssertEqual(player.customHeadersForTesting["Referer"], "https://ref.example.com/")
        XCTAssertEqual(player.customHeadersForTesting["User-Agent"], "CustomUA")
    }

    func testPreLoadStallTriggersRecoveryBefore45SecondOpenTimeout() throws {
        let player = PlaybackController()
        defer { player.stop() }
        player.open(try XCTUnwrap(URL(string: "https://example.com/video.mkv")), autoRecover: true)

        for _ in 0..<14 {
            player.checkHealthForTesting()
        }

        XCTAssertEqual(player.recoveryCountForTesting, 1, "起播阶段卡死必须在 14 秒左右主动触发重连，而不必干等 45 秒")
    }

    func testHealthyPlaybackClearsRecoveryBudgetAfter25Seconds() async throws {
        let player = PlaybackController()
        defer { player.stop() }
        player.open(try XCTUnwrap(URL(string: "https://example.com/video.mkv")), autoRecover: true)
        player.receiveEventForTesting(.fileLoaded)
        player.receiveEventForTesting(.property("duration", .double(300)))
        player.receiveEventForTesting(.property("seekable", .flag(true)))
        player.receiveEventForTesting(.playbackRestart)
        player.receiveEventForTesting(.property("time-pos", .double(25)))
        player.receiveEventForTesting(.property("paused-for-cache", .flag(true)))

        for _ in 0..<8 { player.checkHealthForTesting() }
        XCTAssertEqual(player.recoveryCountForTesting, 1)
        try await Task.sleep(nanoseconds: 80_000_000)

        // 重开后恢复正常播放并稳定持续 25 秒
        player.receiveEventForTesting(.fileLoaded)
        player.receiveEventForTesting(.playbackRestart)
        player.receiveEventForTesting(.property("paused-for-cache", .flag(false)))
        player.receiveEventForTesting(.property("time-pos", .double(26)))
        for _ in 0..<25 { player.checkHealthForTesting() }

        XCTAssertEqual(player.recoveryCountForTesting, 0, "稳定播放 25 秒后必须归零连续失败计数，保证长片后续还能自动恢复")
    }

    func testGradualSubThresholdCacheGrowthDoesNotTriggerFalseStallRecovery() throws {
        let player = PlaybackController()
        defer { player.stop() }
        player.open(try XCTUnwrap(URL(string: "https://example.com/video.mkv")), autoRecover: true)
        player.receiveEventForTesting(.fileLoaded)
        player.receiveEventForTesting(.property("duration", .double(300)))
        player.receiveEventForTesting(.property("seekable", .flag(true)))
        player.receiveEventForTesting(.playbackRestart)
        player.receiveEventForTesting(.property("time-pos", .double(25)))
        player.receiveEventForTesting(.property("paused-for-cache", .flag(true)))

        // 模拟高码率视频每秒内多次细碎回调（每次只涨 0.08s < 0.25s，但整秒累计涨 0.40s >= 0.25s）
        var cacheSeconds = 0.0
        for _ in 0..<10 {
            for _ in 0..<5 {
                cacheSeconds += 0.08
                player.receiveEventForTesting(.property("demuxer-cache-duration", .double(cacheSeconds)))
            }
            player.checkHealthForTesting()
        }

        XCTAssertEqual(player.recoveryCountForTesting, 0, "整秒累计缓冲持续上涨时不得误判为卡死并触发重连或切节点")
    }

    func testBufferingResumeClearsTransientStatusNoteWithoutPlaybackRestart() throws {
        let player = PlaybackController()
        defer { player.stop() }
        player.open(try XCTUnwrap(URL(string: "https://example.com/video.mkv")), autoRecover: true)
        player.receiveEventForTesting(.fileLoaded)
        player.receiveEventForTesting(.property("duration", .double(300)))
        player.receiveEventForTesting(.property("seekable", .flag(true)))
        player.receiveEventForTesting(.playbackRestart)
        player.receiveEventForTesting(.property("time-pos", .double(25)))
        player.receiveEventForTesting(.property("paused-for-cache", .flag(true)))
        player.receiveEventForTesting(.property("paused-for-cache", .flag(false)))

        XCTAssertEqual(player.statusNote, "")
        XCTAssertFalse(player.buffering)
    }
}
