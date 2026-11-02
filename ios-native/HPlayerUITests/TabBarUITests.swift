import XCTest

final class TabBarUITests: XCTestCase {
    /// 系统原生标签栏（iOS 26 上是悬浮的 Liquid Glass 胶囊），深浅两种外观各检查一次。
    func testNativeTabBarInBothAppearances() {
        exerciseTabs(style: "dark")
        exerciseTabs(style: "light")
    }

    private func exerciseTabs(style: String) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_DESIGN_SCREEN"] = "home"
        app.launchEnvironment["HPLAYER_DESIGN_STYLE"] = style
        app.launch()
        defer { app.terminate() }

        let home = app.tabButton("首页")
        let cloud = app.tabButton("网盘")
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
        screenshot.name = "TabGlass-system-\(style)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
