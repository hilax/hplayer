import XCTest

final class MotionUITests: XCTestCase {
    func testHistoryUpdatesAndRemovesRecordsWithReducedMotion() {
        exerciseHistory(reduceMotion: true)
    }

    func testHistoryUpdatesAndRemovesRecordsWithMotion() {
        exerciseHistory(reduceMotion: false)
    }

    func testCarouselAndSeriesNavigationRemainUsable() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_DESIGN_SCREEN"] = "home"
        app.launch()
        defer { app.terminate() }
        let carousel = app.descendants(matching: .any)["home.carouselPosition"].firstMatch
        XCTAssertTrue(carousel.waitForExistence(timeout: 20))
        let before = carousel.value as? String
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: end)
        let changed = NSPredicate { _, _ in (carousel.value as? String) != before }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: 8), .completed)

        let series = app.buttons.matching(identifier: "home.series.tt11280740").firstMatch
        for _ in 0..<5 where !series.isHittable { app.swipeUp() }
        XCTAssertTrue(series.waitForExistence(timeout: 5))
        series.tap()
        XCTAssertTrue(app.staticTexts["人生切割术"].firstMatch.waitForExistence(timeout: 10))
        // 返回和更多都在系统导航栏上
        let more = app.buttons["series.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "The options button sits in the system navigation bar")
        let detailShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        detailShot.name = "Series detail navigation bar"
        detailShot.lifetime = .keepAlways
        add(detailShot)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(series.waitForExistence(timeout: 5), "Returning from detail should keep the shelf usable")
        XCTAssertTrue(more.waitForNonExistence(timeout: 3), "The navigation bar buttons must leave with the page")
    }

    private func exerciseHistory(reduceMotion: Bool) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_DESIGN_SCREEN"] = "continue"
        app.launchEnvironment["HPLAYER_HISTORY_MOTION_TEST"] = "1"
        if reduceMotion { app.launchEnvironment["HPLAYER_REDUCE_MOTION_TEST"] = "1" }
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["3 条记录"].waitForExistence(timeout: 20))
        app.buttons["history.testProgress"].tap()
        let first = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "继续播放 沙丘 2")).firstMatch
        let updated = NSPredicate { _, _ in
            app.staticTexts["80%"].exists || (first.value as? String)?.contains("80%") == true
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: updated, object: nil)], timeout: 5), .completed,
                       "Progress must update in place and remain accessible")
        let more = app.buttons.matching(NSPredicate(format: "label == %@", "沙丘 2 的更多选项")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        app.buttons.matching(NSPredicate(format: "label == %@", "从继续观看移除")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["2 条记录"].waitForExistence(timeout: 5))
        XCTAssertFalse(more.exists, "Removed records must not return after the transition")
        app.buttons["历史选项"].tap()
        app.buttons.matching(NSPredicate(format: "label == %@", "清空记录")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["还没有播放记录"].waitForExistence(timeout: 5))
    }
}
