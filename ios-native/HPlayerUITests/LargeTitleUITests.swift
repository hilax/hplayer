import XCTest

/// 片库、网盘、我的用系统导航栏的大标题（和系统「设置」一样）：
/// 大标题靠左、跟着内容滚动；滚上去后收成顶部居中的小标题；滚回顶部再展开。搜索按钮一直在导航栏右侧。
final class LargeTitleUITests: XCTestCase {
    func testLibraryTitleCollapsesWhenScrolled() {
        check(screen: "catalog", title: "片库", probe: "catalog.kind.all", search: "catalog.search")
    }

    func testCloudTitleCollapsesWhenScrolled() {
        check(screen: "library", title: "网盘", probe: "library.magnet", search: "cloud.search")
    }

    func testMineTitleCollapsesWhenScrolled() {
        check(screen: "settings", title: "我的", probe: "mine.manage", search: nil)
    }

    /// probe：页面里一个会随内容一起滚动的按钮，用来判断这一页的内容够不够长、到底滚没滚。
    /// 内容不够长时（比如测试数据很少的片库）系统本来就不会收缩标题，这种情况只截图、不断言收缩。
    private func check(screen: String, title: String, probe: String, search: String?) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_DESIGN_SCREEN"] = screen
        app.launch()
        defer { app.terminate() }

        let bar = app.navigationBars[title]
        XCTAssertTrue(bar.waitForExistence(timeout: 25), "\(screen): the system navigation bar should carry the title")
        let label = bar.staticTexts[title]
        XCTAssertTrue(label.waitForExistence(timeout: 5), "\(screen): the title text sits in the navigation bar")
        if let search {
            XCTAssertTrue(app.buttons[search].waitForExistence(timeout: 5), "\(screen): search stays in the navigation bar")
        }
        let content = app.buttons[probe]
        XCTAssertTrue(content.waitForExistence(timeout: 25), "\(screen): page content should be loaded")
        Thread.sleep(forTimeInterval: 1.0)

        let width = app.frame.width
        XCTAssertLessThan(label.frame.minX, width * 0.2, "\(screen): the large title sits at the leading edge; frame=\(label.frame)")
        let startY = content.frame.minY
        attach(app, "\(screen)-large-title")

        for _ in 0..<3 { app.swipeUp() }
        Thread.sleep(forTimeInterval: 1.0)
        attach(app, "\(screen)-scrolled")

        let scrolled = abs(content.frame.minY - startY) > 40
        if scrolled {
            let collapsed = bar.staticTexts[title]
            XCTAssertTrue(collapsed.exists, "\(screen): the title stays in the bar after scrolling")
            XCTAssertEqual(collapsed.frame.midX, width / 2, accuracy: 30,
                           "\(screen): the collapsed title is centered like Settings; frame=\(collapsed.frame)")

            for _ in 0..<5 { app.swipeDown() }
            Thread.sleep(forTimeInterval: 1.0)
            XCTAssertLessThan(bar.staticTexts[title].frame.minX, width * 0.2,
                              "\(screen): scrolling back to the top expands the large title again")
            attach(app, "\(screen)-expanded-again")
        }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "LargeTitle-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
