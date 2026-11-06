import XCTest
@testable import HPlayer

@MainActor
final class PlaybackBoostTests: XCTestCase {
    private func player(width: Int64 = 1920, height: Int64 = 1080) throws -> PlaybackController {
        let player = PlaybackController()
        player.open(try XCTUnwrap(URL(string: "https://example.com/video.mp4")), autoRecover: false)
        player.receiveEventForTesting(.fileLoaded)
        player.receiveEventForTesting(.property("duration", .double(300)))
        player.receiveEventForTesting(.property("seekable", .flag(true)))
        player.receiveEventForTesting(.property("video-params/w", .int(width)))
        player.receiveEventForTesting(.property("video-params/h", .int(height)))
        player.receiveEventForTesting(.playbackRestart)
        player.receiveEventForTesting(.property("time-pos", .double(20)))
        return player
    }

    func test4KBoostStartsAtTwoAndReleaseRestoresSelectedSpeed() throws {
        // Include widescreen 4K with black bars cropped from its encoded height.
        for dimensions: (Int64, Int64) in [(3840, 2160), (3840, 1600), (2160, 3840)] {
            let player = try player(width: dimensions.0, height: dimensions.1)
            defer { player.stop() }
            player.setRate(1.25)
            player.setBoost(true)
            XCTAssertEqual(player.effectiveRate, 2)
            XCTAssertEqual(player.rate, 1.25)
            player.setBoost(false)
            XCTAssertEqual(player.effectiveRate, 1.25)
        }
    }

    func testSustainedDriftReducesOnlyTemporarySpeed() throws {
        let player = try player(width: 3840, height: 2160)
        defer { player.stop() }
        player.setRate(1.5)
        player.setBoost(true)
        player.checkBoostSyncForTesting(0.3, at: 10)
        XCTAssertEqual(player.effectiveRate, 2, "A single transient must not change speed")
        player.checkBoostSyncForTesting(0.4, at: 11)
        XCTAssertEqual(player.effectiveRate, 1.5)
        player.checkBoostSyncForTesting(0.4, at: 11.5)
        player.checkBoostSyncForTesting(0.4, at: 12.5)
        XCTAssertEqual(player.effectiveRate, 1.5, "Avoid rapid repeated rate changes")
        player.checkBoostSyncForTesting(0.4, at: 13)
        XCTAssertEqual(player.effectiveRate, 1)
        player.checkBoostSyncForTesting(0.5, at: 14)
        player.checkBoostSyncForTesting(0.5, at: 15)
        XCTAssertEqual(player.effectiveRate, 1, "Never slow below normal playback")
        player.setBoost(false)
        XCTAssertEqual(player.effectiveRate, 1.5)
        XCTAssertEqual(player.rate, 1.5)
    }

    func testHealthyAndTransientDriftDoNotReduceHDAcceleration() throws {
        let player = try player()
        defer { player.stop() }
        player.setBoost(true)
        XCTAssertEqual(player.effectiveRate, 3)
        for (time, offset): (Double, Double?) in [(10, 0.3), (11, 0.01), (12, 0.3), (13, nil), (14, .nan), (15, 0.02)] {
            player.checkBoostSyncForTesting(offset, at: time)
        }
        XCTAssertEqual(player.effectiveRate, 3)
        player.setBoost(false)
        player.checkBoostSyncForTesting(0.5, at: 20)
        player.checkBoostSyncForTesting(0.5, at: 22)
        XCTAssertEqual(player.effectiveRate, 1, "Normal playback speed is never adapted")
    }

    func testBufferingAndSeekingDoNotCountAsDecoderDrift() throws {
        let player = try player()
        defer { player.stop() }
        player.setBoost(true)
        player.checkBoostSyncForTesting(0.3, at: 10)
        player.receiveEventForTesting(.property("paused-for-cache", .flag(true)))
        player.checkBoostSyncForTesting(1, at: 11)
        player.receiveEventForTesting(.property("paused-for-cache", .flag(false)))
        player.checkBoostSyncForTesting(0.3, at: 12)
        XCTAssertEqual(player.effectiveRate, 3)
        player.seek(to: 100)
        player.checkBoostSyncForTesting(1, at: 14)
        XCTAssertEqual(player.effectiveRate, 3)
    }

    func testLate4KMetadataAndSoftwareFallbackLimitAnActiveBoost() throws {
        let player = try player()
        defer { player.stop() }
        player.setBoost(true)
        player.receiveEventForTesting(.property("video-params/w", .int(3840)))
        XCTAssertEqual(player.effectiveRate, 2)
        player.setBoost(false)
        player.open(try XCTUnwrap(URL(string: "https://example.com/next.mp4")), autoRecover: false)
        XCTAssertEqual(player.effectiveRate, player.rate, "Opening a video clears temporary acceleration")
        player.setBoost(true)
        XCTAssertEqual(player.effectiveRate, 3, "A new file must not inherit the previous resolution")
        player.receiveEventForTesting(.property("hwdec-current", .string("no")))
        XCTAssertEqual(player.effectiveRate, 2)
    }
}
