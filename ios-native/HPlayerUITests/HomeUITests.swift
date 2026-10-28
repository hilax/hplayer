import XCTest

final class HomeUITests: XCTestCase {
    func testPosterLibraryAndManualMatching() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_HOME_TEST"] = "1"
        app.launchEnvironment["HPLAYER_METADATA_TEST_ENDPOINT"] = "http://127.0.0.1:8765"
        app.launch()
        let dune = app.buttons["home.poster.tt1160419"].firstMatch
        XCTAssertTrue(dune.waitForExistence(timeout: 30), "Imported movie should receive metadata")
        XCTAssertTrue(app.buttons["home.sources"].exists)
        XCTAssertTrue(app.buttons["home.heroPlay"].firstMatch.isHittable, "Featured play button must fit inside the card")
        XCTAssertTrue(app.descendants(matching: .any)["home.artwork.Dune"].firstMatch.waitForExistence(timeout: 25), "Artwork should load successfully")
        let frame = app.windows.firstMatch.frame
        XCTAssertGreaterThan(frame.height, frame.width, "The home screen stays in portrait")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "HPlayer poster library"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.swipeUp()
        dune.press(forDuration: 1)
        app.buttons["匹配封面"].tap()
        let result = app.buttons["metadata.result.tt1160419"]
        XCTAssertTrue(result.waitForExistence(timeout: 15), "Manual matching should show title search results")
        result.tap()
        XCTAssertTrue(app.buttons["home.sources"].waitForExistence(timeout: 5))
    }
}
