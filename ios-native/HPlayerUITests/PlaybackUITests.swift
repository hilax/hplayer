import XCTest

final class PlaybackUITests: XCTestCase {
    func testVLCPlaybackControlsAndLandscape() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_UI_TEST_URL"] = "http://127.0.0.1:8765/magnet-fixture.mp4"
        app.launch()
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48))
        let pause = app.buttons["暂停"]
        for _ in 0..<30 {
            if pause.exists { break }
            center.tap()
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(pause.exists, "VLC should start playing the test video")

        center.doubleTap()
        XCTAssertTrue(app.buttons["播放"].waitForExistence(timeout: 5), "Double tap should pause")
        center.doubleTap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "Double tap should resume")

        app.buttons["锁定"].tap()
        XCTAssertTrue(app.buttons["解锁"].waitForExistence(timeout: 3))
        XCTAssertFalse(pause.exists, "Playback controls should be hidden while locked")
        app.buttons["解锁"].tap()

        app.buttons["播放列表"].tap()
        XCTAssertTrue(app.buttons["测试下一集"].waitForExistence(timeout: 3))
        app.buttons["测试下一集"].tap()
        XCTAssertTrue(app.staticTexts["测试下一集"].waitForExistence(timeout: 10))
        if !app.buttons["横屏"].exists { center.tap() }
        app.buttons["横屏"].tap()
        var rotated = false
        for _ in 0..<20 {
            let frame = app.windows.firstMatch.frame
            if frame.width > frame.height { rotated = true; break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(rotated, "Landscape button should rotate the player window")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "HPlayer landscape VLC controls"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
