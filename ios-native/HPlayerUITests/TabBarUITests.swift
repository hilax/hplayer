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
        // 「我的」里三层深的路径：关于 → 开源许可 → 许可全文
        let about = app.buttons["settings.about"]
        XCTAssertTrue(about.waitForExistence(timeout: 10))
        for _ in 0..<8 where !about.isHittable { app.swipeUp() }
        about.tap()
        let licenses = app.buttons["settings.licenses"]
        XCTAssertTrue(licenses.waitForExistence(timeout: 10))
        XCTAssertFalse(mine.isHittable)
        licenses.tap()
        let mpv = app.buttons["settings.license.MPVKit-LICENSE"]
        XCTAssertTrue(mpv.waitForExistence(timeout: 10))
        mpv.tap()
        XCTAssertTrue(app.navigationBars["mpv / MPVKit"].waitForExistence(timeout: 10))
        XCTAssertFalse(mpv.isHittable)
        XCTAssertFalse(mine.isHittable)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(mpv.waitForExistence(timeout: 5) && mpv.isHittable, "The first pop returns to the license list")
        XCTAssertFalse(mine.isHittable, "A nested pop must not reveal the root tab bar")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(licenses.waitForExistence(timeout: 5) && licenses.isHittable, "The second pop returns to About")
        XCTAssertFalse(mine.isHittable, "A nested pop must not reveal the root tab bar")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(mine.isHittable && mine.isSelected)
        XCTAssertTrue(about.waitForExistence(timeout: 5) && about.isHittable)
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

    /// 真实首页环境下打开、关闭搜索页（首开与二次打开）：验证键盘与搜索页同步出现与消失，且页面不跳动。
    func testSearchKeyboardOpenAndCloseRoundTrip() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_HOME_TEST"] = "1"
        app.launchEnvironment["HPLAYER_METADATA_TEST_ENDPOINT"] = "http://127.0.0.1:1"
        app.launch()
        defer { app.terminate() }

        let searchEntry = app.buttons["home.search"]
        XCTAssertTrue(searchEntry.waitForExistence(timeout: 25))
        let homeFrameBefore = searchEntry.frame
        let query = app.textFields["search.query"]
        let back = app.buttons["search.back"]

        // 1st open
        searchEntry.tap()
        XCTAssertTrue(waitFor(timeout: 10) { query.isHittable }, "1st open: search field must become interactive")
        let keyboardShownFirst = waitFor(timeout: 3) { app.keyboards.count > 0 }
        let queryFrameFirst = query.frame
        Thread.sleep(forTimeInterval: 0.35)
        XCTAssertEqual(query.frame.minY, queryFrameFirst.minY, accuracy: 0.5, "1st open: search field must not jump vertically")

        // 1st close
        back.tap()
        XCTAssertTrue(waitFor(timeout: 10) { searchEntry.isHittable }, "1st close: home search bar must return")
        if keyboardShownFirst {
            XCTAssertTrue(waitFor(timeout: 2) { app.keyboards.count == 0 }, "1st close: software keyboard must dismiss with search page")
        }
        XCTAssertEqual(searchEntry.frame.minY, homeFrameBefore.minY, accuracy: 0.5, "1st close: home search bar must not shift")

        // 2nd open
        searchEntry.tap()
        XCTAssertTrue(waitFor(timeout: 10) { query.isHittable }, "2nd open: search field must become interactive")
        let keyboardShownSecond = waitFor(timeout: 3) { app.keyboards.count > 0 }
        let queryFrameSecond = query.frame
        Thread.sleep(forTimeInterval: 0.35)
        XCTAssertEqual(query.frame.minY, queryFrameSecond.minY, accuracy: 0.5, "2nd open: search field must not jump vertically")

        // 2nd close
        back.tap()
        XCTAssertTrue(waitFor(timeout: 10) { searchEntry.isHittable }, "2nd close: home search bar must return")
        if keyboardShownSecond {
            XCTAssertTrue(waitFor(timeout: 2) { app.keyboards.count == 0 }, "2nd close: software keyboard must dismiss with search page")
        }
        XCTAssertEqual(searchEntry.frame.minY, homeFrameBefore.minY, accuracy: 0.5, "2nd close: home search bar must not shift")
    }

    /// 首页最左「推荐」不能继续向右拖、最右「MissAV」不能继续向左拖；中间页左右切换仍正常工作。
    func testHomeChannelEdgesDoNotOverscroll() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_DESIGN_SCREEN"] = "home"
        app.launch()
        defer { app.terminate() }

        let recommend = app.buttons["home.channel.recommend"]
        let anime = app.buttons["home.channel.anime"]
        let jable = app.buttons["home.channel.jable"]
        let missav = app.buttons["home.channel.missav"]
        XCTAssertTrue(recommend.waitForExistence(timeout: 25))
        XCTAssertTrue(recommend.isSelected)

        let heroPlay = app.buttons["home.heroPlay"].firstMatch
        XCTAssertTrue(heroPlay.waitForExistence(timeout: 10))
        let heroFrameBefore = heroPlay.frame

        let screen = app.frame
        let recommendTitles = ["home.shelf.continue", "home.shelf.trending", "home.shelf.movies", "home.shelf.watchlist"]
            .map { app.descendants(matching: .any)[$0].firstMatch }
        let title = try XCTUnwrap(recommendTitles.first { $0.exists && $0.frame.minY > 200 && $0.frame.maxY < screen.maxY - 120 },
                                  "A Recommend shelf title must be on screen")
        let recommendRow = title.frame.midY / screen.height
        let recommendLeft = app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: recommendRow))
        let recommendRight = app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: recommendRow))

        // 最左「推荐」向右拖：停在首页不露白边也不切页
        recommendLeft.press(forDuration: 0.05, thenDragTo: recommendRight, withVelocity: .slow, thenHoldForDuration: 0.6)
        XCTAssertTrue(recommend.isSelected)
        XCTAssertEqual(heroPlay.frame.minX, heroFrameBefore.minX, accuracy: 1.0, "Swiping right on Recommend must not shift content")

        // 中间正常向左滑：推荐 -> 动漫
        recommendRight.press(forDuration: 0.05, thenDragTo: recommendLeft, withVelocity: .default, thenHoldForDuration: 0.05)
        XCTAssertTrue(waitFor(timeout: 5) { anime.isSelected }, "Swiping left on Recommend moves to Anime")

        // 点到最右「MissAV」再向左拖：停在末页不露白边
        if !missav.isHittable {
            app.descendants(matching: .any)["home.channels"].firstMatch.swipeLeft()
        }
        missav.tap()
        XCTAssertTrue(waitFor(timeout: 5) { missav.isSelected }, "Tapping MissAV selects the rightmost channel")

        let missavShortcut = app.buttons["missav.shortcut.new"].firstMatch
        XCTAssertTrue(missavShortcut.waitForExistence(timeout: 10))
        let missavFrameBefore = missavShortcut.frame
        let missavGapY = max(missavShortcut.frame.minY - 8, 220) / screen.height
        let missavLeft = app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: missavGapY))
        let missavRight = app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: missavGapY))

        missavRight.press(forDuration: 0.05, thenDragTo: missavLeft, withVelocity: .slow, thenHoldForDuration: 0.6)
        XCTAssertTrue(missav.isSelected)
        XCTAssertEqual(missavShortcut.frame.minX, missavFrameBefore.minX, accuracy: 1.0, "Swiping left on MissAV must not shift content")

        // 从末页向右滑仍能正常切回 Jable
        missavLeft.press(forDuration: 0.05, thenDragTo: missavRight, withVelocity: .default, thenHoldForDuration: 0.05)
        XCTAssertTrue(waitFor(timeout: 5) { jable.isSelected }, "Swiping right on MissAV moves back to Jable")
    }

    private func waitFor(timeout: TimeInterval, _ predicate: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)], timeout: timeout) == .completed
    }

    private func exerciseNavigationReturn(usingGesture: Bool) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        for (screen, title, entryID) in [
            ("home", "首页", "home.series.tt11280740"),
            ("catalog", "首页", "catalog.series.tt11280740"),
            ("home", "首页", "home.performer."),
            ("magnet-tab", "磁力", "magnet.studio.s1"),
            ("library", "网盘", "cloud.offline"),
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
            let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", entryID)).firstMatch
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
                let back = app.navigationBars.buttons.element(boundBy: 0)
                let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    back.isEnabled && back.isHittable
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed,
                               "\(title): the destination's back button must be interactive before tapping")
                back.tap()
            }

            // 不给胶囊栏另留等待时间：返回操作结束时，内容和系统标签按钮都应可用。
            XCTAssertTrue(entry.isHittable, "\(title): returning keeps the original page usable")
            XCTAssertTrue(tab.isHittable && tab.isSelected, "\(title): the native bar returns with its page")
            XCTAssertEqual(entry.frame.minY, before.minY, accuracy: 1, "\(title): returning preserves the scroll position")

            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "TabReturn-\(screen)-\(entryID)-\(usingGesture ? "swipe" : "button")"
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
