import XCTest

final class PlaybackUITests: XCTestCase {
    func testVLCPlaybackControlsAndLandscape() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_UI_TEST_URL"] = "http://127.0.0.1:8765/hls-fixture/index.m3u8"
        app.launchEnvironment["HPLAYER_UI_TEST_115_HEADERS"] = "1"
        app.launch()
        let surface = app.otherElements["playback.surface"]
        let orientation = app.buttons["playback.orientation"]
        func waitForLayout(landscape: Bool, label: String, timeout: TimeInterval = 10) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                let frame = app.windows.firstMatch.frame
                let surfaceFrame = surface.frame
                let matchesOrientation = landscape
                    ? frame.width > frame.height && surfaceFrame.width > surfaceFrame.height
                    : frame.height > frame.width && surfaceFrame.height > surfaceFrame.width
                if matchesOrientation
                    && abs(surfaceFrame.width - frame.width) < 2
                    && abs(surfaceFrame.height - frame.height) < 2
                    && orientation.label == label {
                    return true
                }
                Thread.sleep(forTimeInterval: 0.25)
            } while Date() < deadline
            return false
        }
        let startedInLandscape = waitForLayout(landscape: true, label: "竖屏", timeout: 20)
        if !startedInLandscape {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Default landscape failure hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Default landscape failure screen"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertTrue(startedInLandscape, "Playback should start in landscape")

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
        if !orientation.exists { center.tap() }
        orientation.tap()
        XCTAssertTrue(waitForLayout(landscape: false, label: "横屏"), "Orientation button should switch to portrait")
        if !orientation.exists { center.tap() }
        orientation.tap()
        XCTAssertTrue(waitForLayout(landscape: true, label: "竖屏"), "Orientation button should return to landscape")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "HPlayer landscape VLC controls"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
