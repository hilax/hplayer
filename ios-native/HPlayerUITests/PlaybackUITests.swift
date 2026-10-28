import XCTest

final class PlaybackUITests: XCTestCase {
    func testVLCPlaybackControlsAndLandscape() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_UI_TEST_URL"] = "http://127.0.0.1:8765/hls-fixture/index.m3u8"
        app.launchEnvironment["HPLAYER_UI_TEST_115_HEADERS"] = "1"
        app.launch()
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48))
        let pause = app.buttons["playback.playPause"]
        let elapsed = app.staticTexts["playback.elapsed"]
        var advanced = false
        for _ in 0..<45 {
            if elapsed.exists && elapsed.label != "00:00" { advanced = true; break }
            if !elapsed.exists { center.tap() }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(advanced, "VLC should render and advance the HLS test stream")
        XCTAssertTrue(pause.exists, "VLC should start playing the test video")

        center.doubleTap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "Double tap should pause")
        expectation(for: NSPredicate(format: "value == %@", "paused"), evaluatedWith: pause)
        waitForExpectations(timeout: 5)
        center.doubleTap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "Double tap should resume")
        expectation(for: NSPredicate(format: "value == %@", "playing"), evaluatedWith: pause)
        waitForExpectations(timeout: 5)
        center.press(forDuration: 1.2)
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "Releasing a long press should keep playback running")

        app.buttons["playback.lock"].tap()
        XCTAssertTrue(app.buttons["playback.unlock"].waitForExistence(timeout: 3))
        XCTAssertFalse(pause.exists, "Playback controls should be hidden while locked")
        app.buttons["playback.unlock"].tap()

        app.buttons["playback.playlist"].tap()
        let nextEpisode = app.buttons["playback.item.direct|测试下一集|http://127.0.0.1:8765/hls-fixture/index.m3u8"]
        XCTAssertTrue(nextEpisode.waitForExistence(timeout: 3))
        nextEpisode.tap()
        XCTAssertTrue(app.staticTexts["测试下一集"].waitForExistence(timeout: 10))
        if !app.buttons["playback.orientation"].exists { center.tap() }
        app.buttons["playback.orientation"].tap()
        let surface = app.otherElements["playback.surface"]
        var rotated = false
        for _ in 0..<20 {
            let frame = app.windows.firstMatch.frame
            let surfaceFrame = surface.frame
            let orientationLabel = app.buttons["playback.orientation"].label
            if frame.width > frame.height
                && surfaceFrame.width > surfaceFrame.height
                && abs(surfaceFrame.width - frame.width) < 2
                && abs(surfaceFrame.height - frame.height) < 2
                && orientationLabel == "竖屏" {
                rotated = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(rotated, "Landscape button should relayout the player surface and controls")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "HPlayer landscape VLC controls"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
