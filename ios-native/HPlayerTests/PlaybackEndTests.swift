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

        player.receiveEventForTesting(.property("time-pos", .double(299.5)))
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

    func testPrematureEOFNearButNotAtTheEndDoesNotAdvance() throws {
        let player = try player(at: 296)
        player.receiveEventForTesting(.property("eof-reached", .flag(true)))
        XCTAssertFalse(player.ended)

        player.receiveEventForTesting(.property("eof-reached", .flag(false)))
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
}
