import XCTest

final class HomeUITests: XCTestCase {
    func testAccountInformationStaysVisibleWhenSwitchingTabs() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_ACCOUNT_TEST"] = "1"
        app.launch()
        defer { app.terminate() }

        let library = app.tabButton("网盘")
        let settings = app.tabButton("我的")
        XCTAssertTrue(library.waitForExistence(timeout: 20))
        library.tap()
        let account = app.buttons["library.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 10))
        XCTAssertTrue(wait {
            (account.label.contains("测试账号 1") || app.staticTexts["测试账号 1"].exists) &&
            (account.label.contains("1 GB") || app.staticTexts["已使用 1 GB"].exists)
        },
                      "The shared account and capacity should load once")

        settings.tap()
        XCTAssertTrue(app.staticTexts["测试账号 1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["检查中"].exists)
        library.tap()
        XCTAssertTrue(wait {
            (account.label.contains("测试账号 1") || app.staticTexts["测试账号 1"].exists) &&
            (account.label.contains("1 GB") || app.staticTexts["已使用 1 GB"].exists)
        })
        XCTAssertFalse(app.staticTexts["检查中"].exists)
        settings.tap()
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertTrue(app.staticTexts["测试账号 1"].exists, "Switching tabs should not start another account request")
        XCTAssertFalse(app.staticTexts["测试账号 2"].exists)
        library.tap()
        XCTAssertTrue(account.label.contains("1 GB") || app.staticTexts["已使用 1 GB"].exists,
                      "Switching tabs should not repeat the capacity request")
        XCTAssertFalse(account.label.contains("2 GB"))
        settings.tap()

        app.buttons["settings.account.logout"].tap()
        app.buttons.matching(identifier: "settings.account.confirmLogout").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["尚未登录 115"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["测试账号 1"].exists, "Signing out must hide the previous account")
        library.tap()
        XCTAssertTrue(wait { account.label.contains("连接 115 网盘") })
        XCTAssertFalse(account.label.contains("测试账号 1"))
    }

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

        // 首页布局变了：先滑回顶部，保证要长按的那张海报在屏幕里。
        for _ in 0..<3 where !dune.isHittable { app.swipeDown() }
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
        app.tabButton("网盘").tap()
        // 2.0：云端离线、本机下载、边下边播合并进传输中心
        let transfers = app.buttons["cloud.transfers"]
        XCTAssertTrue(transfers.waitForExistence(timeout: 5), "Cloud tab offers the transfer center")
        transfers.tap()
        XCTAssertTrue(app.buttons["transfers.offline"].waitForExistence(timeout: 5), "Transfer center links to cloud offline tasks")
        XCTAssertTrue(app.buttons["transfers.downloads"].exists, "Transfer center links to local downloads")
        XCTAssertTrue(app.buttons["transfers.bt"].exists, "Transfer center links to BT streaming")
        app.navigationBars["传输中心"].buttons.firstMatch.tap()
        XCTAssertTrue(transfers.waitForExistence(timeout: 5), "Back returns to the Cloud tab")
        XCTAssertFalse(app.buttons["library.manage"].exists, "Library management lives in the Mine tab only")
        // 2.0：磁力是一级 Tab。磁力聚合：搜索框 + 四个分类标签；专题是固定的片商入口，不依赖网络
        app.tabButton("磁力").tap()
        XCTAssertTrue(app.textFields["magnet.search"].waitForExistence(timeout: 5), "Magnet tab offers one search field")
        XCTAssertTrue(app.buttons["magnet.linkPlayer"].exists, "Magnet tab offers the paste-a-link player")
        for key in ["latest", "topics", "actresses", "hot"] {
            XCTAssertTrue(app.buttons["magnet.category.\(key)"].exists, "Category tab \(key) exists")
        }
        app.buttons["magnet.category.topics"].tap()
        XCTAssertTrue(app.buttons["magnet.studio.s1"].waitForExistence(timeout: 5), "Topics lists the studios")
        // 智能输入：输入框认出信息哈希时直接给出解析面板，不去站点搜索
        let magnetField = app.textFields["magnet.search"]
        magnetField.tap()
        magnetField.typeText("0123456789abcdef0123456789abcdef01234567")
        XCTAssertTrue(app.buttons["magnet.link.play"].waitForExistence(timeout: 5), "A pasted hash shows the parse panel")
        XCTAssertTrue(app.buttons["magnet.link.save115"].exists, "The parse panel can save to 115")
        XCTAssertTrue(app.buttons["magnet.category.topics"].exists, "A link does not switch into search results")
        capture("Magnet link panel - redesign", in: app)
        app.buttons["清除搜索"].tap()
        XCTAssertFalse(app.buttons["magnet.link.play"].waitForExistence(timeout: 1), "Clearing the field hides the panel")
        app.tabButton("网盘").tap()
        XCTAssertTrue(app.buttons["cloud.transfers"].waitForExistence(timeout: 5), "Switching back shows the Cloud tab")
        capture("Resources - redesign", in: app)
        // 媒体库管理只留在「我的」页
        app.tabButton("我的").tap()
        let manage = app.buttons["mine.manage"]
        if !manage.isHittable { app.swipeUp() }
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        manage.tap()
        XCTAssertTrue(app.navigationBars["媒体库管理"].waitForExistence(timeout: 5))
        capture("Library management - redesign", in: app)
        let unmatched = app.buttons["scan.unmatched"]
        if !unmatched.isHittable { app.swipeUp() }
        XCTAssertTrue(unmatched.waitForExistence(timeout: 5), "Unmatched media is managed from Resources")
    }
    private func wait(timeout: TimeInterval = 10, _ predicate: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)], timeout: timeout) == .completed
    }

    private func capture(_ name: String, in app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

}
