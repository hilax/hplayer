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
        // 中文片名走番组计划：「仙逆.Renegade.Immortal.S01E05…」要配上「仙逆」这部剧，而不是随便一个搜索结果
        let chineseSeries = app.descendants(matching: .any)["home.series.bgm:400602"].firstMatch
        XCTAssertTrue(chineseSeries.waitForExistence(timeout: 30), "Chinese title should match through Bangumi")

        dune.press(forDuration: 1)
        app.buttons["匹配封面"].tap()
        let result = app.buttons["metadata.result.tt1160419"]
        XCTAssertTrue(result.waitForExistence(timeout: 15), "Manual matching should show title search results")
        result.tap()
        XCTAssertTrue(app.buttons["home.sources"].waitForExistence(timeout: 5))

        // 结束进程后禁用资料服务：下一次首页必须直接复用本机封面，而不是先闪空片库再联网匹配。
        app.terminate()
        app.launchEnvironment["HPLAYER_METADATA_TEST_ENDPOINT"] = "http://127.0.0.1:1"
        app.launch()
        XCTAssertTrue(app.buttons["home.poster.tt1160419"].firstMatch.waitForExistence(timeout: 5), "Cold launch should restore cached posters without metadata network access")
        XCTAssertFalse(app.otherElements["home.emptyLibrary"].exists, "A saved library must not render the empty onboarding state")
        XCTAssertFalse(app.buttons["home.scanStatus"].exists, "Home never shows scan or matching maintenance")
        XCTAssertFalse(app.otherElements["home.matchingState"].exists)
        app.tabBars.buttons["资源库"].tap()
        let manage = app.buttons["library.manage"]
        if !manage.isHittable { app.swipeUp() }
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        manage.tap()
        XCTAssertTrue(app.navigationBars["媒体库管理"].waitForExistence(timeout: 5))
        let unmatched = app.buttons["scan.unmatched"]
        if !unmatched.isHittable { app.swipeUp() }
        XCTAssertTrue(unmatched.waitForExistence(timeout: 5), "Unmatched media is managed from Resources")
    }
}
