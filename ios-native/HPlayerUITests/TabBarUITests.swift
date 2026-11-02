import XCTest

final class TabBarUITests: XCTestCase {
    func testLiquidGlassTabsInBothAppearances() {
        exerciseTabs(frosted: false, style: "dark")
        exerciseTabs(frosted: false, style: "light")
    }

    func testFrostedFallbackTabsInBothAppearances() {
        exerciseTabs(frosted: true, style: "dark")
        exerciseTabs(frosted: true, style: "light")
    }

    private func exerciseTabs(frosted: Bool, style: String) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_DESIGN_SCREEN"] = "home"
        app.launchEnvironment["HPLAYER_DESIGN_STYLE"] = style
        if frosted { app.launchEnvironment["HPLAYER_UI_TEST_FROSTED_TAB"] = "1" }
        app.launch()
        defer { app.terminate() }

        let home = app.buttons["tab.home"]
        let cloud = app.buttons["tab.cloud"]
        XCTAssertTrue(home.waitForExistence(timeout: 25))
        XCTAssertTrue(home.isHittable)
        XCTAssertTrue(home.isSelected, "The current tab should be announced as selected")
        XCTAssertTrue(cloud.isHittable)

        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(home.frame.minY, window.minY + window.height * 0.7,
                             "The tab bar should remain at the bottom")
        XCTAssertLessThanOrEqual(home.frame.maxY, window.maxY)

        cloud.tap()
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in cloud.isSelected }, object: nil)], timeout: 10) == .completed,
                      "Switching tabs should update the selected state")
        XCTAssertFalse(home.isSelected)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "TabGlass-\(frosted ? "frosted" : "system")-\(style)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
