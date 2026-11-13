import XCTest

final class TabBarUITests: XCTestCase {
    /// 系统原生标签栏（iOS 26 上是悬浮的 Liquid Glass 胶囊），深浅两种外观各检查一次。
    func testNativeTabBarInBothAppearances() {
        exerciseTabs(style: "dark")
        exerciseTabs(style: "light")
    }

    func testBackButtonReturnsEachTabWithItsNativeBar() {
        exerciseNavigationReturn(usingGesture: false)
    }

    func testEdgeSwipeCanCancelAndReturnEachTabWithItsNativeBar() {
        exerciseNavigationReturn(usingGesture: true)
    }

    func testNestedMinePageOnlyRevealsTheTabBarAtTheMineRoot() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_DESIGN_SCREEN"] = "settings"
        app.launch()
        defer { app.terminate() }

        let mine = app.tabButton("我的")
        XCTAssertTrue(mine.waitForExistence(timeout: 25))
        app.buttons["mine.transfers"].tap()
        let downloads = app.buttons["transfers.downloads"]
        XCTAssertTrue(downloads.waitForExistence(timeout: 10))
        downloads.tap()
        XCTAssertFalse(downloads.isHittable)
        XCTAssertFalse(mine.isHittable)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(downloads.isHittable, "The first pop returns to the transfer center")
        XCTAssertFalse(mine.isHittable, "A nested pop must not reveal the root tab bar")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(mine.isHittable && mine.isSelected)
        XCTAssertTrue(app.buttons["mine.transfers"].isHittable)
    }

    /// 从片库、网盘点搜索再返回：原来的页面应该纹丝不动，不能随键盘弹出 / 收起而回弹。
    func testSearchRoundTripLeavesLibraryAndCloudStill() {
        for (screen, searchID) in [("catalog", "catalog.search"), ("library", "cloud.search")] {
            continueAfterFailure = false
            XCUIDevice.shared.orientation = .portrait
            let app = XCUIApplication()
            app.launchEnvironment["HPLAYER_DESIGN_SCREEN"] = screen
            app.launch()
            defer { app.terminate() }

            let search = app.buttons[searchID]
            XCTAssertTrue(search.waitForExistence(timeout: 25), "\(screen): search entry should exist")
            let before = search.frame

            search.tap()
            let query = app.textFields["search.query"]
            XCTAssertTrue(query.waitForExistence(timeout: 10), "\(screen): search page should open")
            query.tap()
            Thread.sleep(forTimeInterval: 1.0)
            app.buttons["search.back"].tap()
            XCTAssertTrue(search.waitForExistence(timeout: 10) && XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in search.isHittable }, object: nil)], timeout: 10) == .completed,
                          "\(screen): the page should be back")
            Thread.sleep(forTimeInterval: 1.0)

            let after = search.frame
            XCTAssertEqual(after.minY, before.minY, accuracy: 0.5, "\(screen): the page must not move after returning from search")
            XCTAssertEqual(after.minX, before.minX, accuracy: 0.5)
        }
    }

    private func exerciseNavigationReturn(usingGesture: Bool) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        for (screen, title, entryID) in [
            ("home", "首页", "home.series.tt11280740"),
            ("catalog", "首页", "catalog.series.tt11280740"),
            ("magnet-tab", "磁力", "magnet.studio.s1"),
            ("library", "网盘", "cloud.local"),
            ("settings", "我的", "settings.appearance")
        ] {
            let app = XCUIApplication()
            app.launchEnvironment["HPLAYER_DESIGN_SCREEN"] = screen
            app.launch()
            defer { app.terminate() }

            let tab = app.tabButton(title)
            XCTAssertTrue(tab.waitForExistence(timeout: 25))
            if screen == "magnet-tab" {
                app.buttons["magnet.category.topics"].tap()
            }
            let entry = app.buttons[entryID].firstMatch
            for _ in 0..<8 where !entry.isHittable { app.swipeUp() }
            XCTAssertTrue(entry.isHittable, "\(title): the secondary-page entry must be visible")
            let before = entry.frame
            entry.tap()
            XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10))
            XCTAssertFalse(tab.isHittable, "\(title): secondary pages cover the whole tab root")

            if usingGesture {
                let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                // 慢拖不到一半再停住松手：取消返回，详情页和标签栏显隐都应保持原样。
                edge.press(forDuration: 0.05,
                           thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)),
                           withVelocity: .slow, thenHoldForDuration: 0.3)
                XCTAssertTrue(app.navigationBars.firstMatch.exists)
                XCTAssertFalse(tab.isHittable, "\(title): cancelling a swipe must keep the tab bar covered")

                edge.press(forDuration: 0.05,
                           thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)),
                           withVelocity: .slow, thenHoldForDuration: 0.1)
            } else {
                app.navigationBars.buttons.element(boundBy: 0).tap()
            }

            // 不给胶囊栏另留等待时间：返回操作结束时，内容和系统标签按钮都应可用。
            XCTAssertTrue(entry.isHittable, "\(title): returning keeps the original page usable")
            XCTAssertTrue(tab.isHittable && tab.isSelected, "\(title): the native bar returns with its page")
            XCTAssertEqual(entry.frame.minY, before.minY, accuracy: 1, "\(title): returning preserves the scroll position")

            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "TabReturn-\(screen)-\(usingGesture ? "swipe" : "button")"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
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
