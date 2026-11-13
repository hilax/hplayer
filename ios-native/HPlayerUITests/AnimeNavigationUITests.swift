import XCTest

final class AnimeNavigationUITests: XCTestCase {
    func testBackButtonStaysStillWhenAnimeDetailFinishesLoading() {
        for style in ["dark", "light"] {
            exerciseDetailNavigation(style: style, fails: false)
        }
    }

    func testBackButtonStaysUsableWhenAnimeDetailFailsToLoad() {
        exerciseDetailNavigation(style: "light", fails: true)
    }

    private func exerciseDetailNavigation(style: String, fails: Bool) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_DESIGN_SCREEN"] = "home"
        app.launchEnvironment["HPLAYER_DESIGN_STYLE"] = style
        app.launchEnvironment["HPLAYER_ANIME_DETAIL_DELAY"] = "1"
        app.launchEnvironment["HPLAYER_ANIME_DETAIL_FAILURE"] = fails ? "1" : "0"
        app.launch()
        defer { app.terminate() }

        let home = app.tabButton("首页")
        XCTAssertTrue(home.waitForExistence(timeout: 25))
        let poster = app.buttons["anime.poster.900001"].firstMatch
        for _ in 0..<8 where !poster.isHittable { app.swipeUp() }
        XCTAssertTrue(poster.isHittable)
        let posterFrame = poster.frame
        poster.tap()

        let loading = app.progressIndicators["anime.loading"]
        XCTAssertTrue(loading.waitForExistence(timeout: 3), "Exercise a real loading-to-content transition")
        let navigationBar = app.navigationBars.firstMatch
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 3), "The back button is available while loading")
        let back = navigationBar.buttons.element(boundBy: 0)
        XCTAssertTrue(back.isHittable)
        let backFrame = back.frame
        let barFrame = navigationBar.frame
        let watchlist = app.buttons["anime.watchlist.900001"]
        XCTAssertTrue(watchlist.exists)
        XCTAssertFalse(watchlist.isEnabled)
        XCTAssertFalse(home.isHittable)
        attach("AnimeNavigation-\(style)-loading-\(fails)")

        if fails {
            XCTAssertTrue(app.buttons["重新加载"].firstMatch.waitForExistence(timeout: 15))
            XCTAssertFalse(watchlist.isEnabled)
        } else {
            XCTAssertTrue(app.buttons["anime.play"].waitForExistence(timeout: 15))
            XCTAssertTrue(watchlist.isEnabled)
        }
        assertSameFrame(back.frame, backFrame, message: "Loading must not move or resize the back button")
        assertSameFrame(navigationBar.frame, barFrame, message: "Loading must not change the navigation bar height")
        XCTAssertTrue(back.isHittable)
        attach("AnimeNavigation-\(style)-\(fails ? "error" : "loaded")")

        if fails {
            back.tap()
        } else {
            let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            edge.press(forDuration: 0.05,
                       thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)),
                       withVelocity: .slow, thenHoldForDuration: 0.3)
            XCTAssertTrue(back.isHittable, "Cancelling a return gesture keeps the detail navigation usable")
            assertSameFrame(back.frame, backFrame, message: "A cancelled swipe must restore the same back button position")
            XCTAssertFalse(home.isHittable)
            edge.press(forDuration: 0.05,
                       thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)),
                       withVelocity: .slow, thenHoldForDuration: 0.1)
        }

        XCTAssertTrue(home.isHittable && home.isSelected)
        XCTAssertTrue(poster.isHittable)
        XCTAssertEqual(poster.frame.minY, posterFrame.minY, accuracy: 1, "Returning preserves the home scroll position")
        attach("AnimeNavigation-\(style)-returned-\(fails)")
    }

    private func assertSameFrame(_ actual: CGRect, _ expected: CGRect, message: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, message, file: file, line: line)
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
