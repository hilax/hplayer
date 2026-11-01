import XCTest

final class SettingsUITests: XCTestCase {
    func testAccountInformationStaysVisibleWhenSwitchingTabs() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_ACCOUNT_TEST"] = "1"
        app.launch()
        defer { app.terminate() }

        let library = app.tabBars.buttons["资源库"]
        let settings = app.tabBars.buttons["设置"]
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
        XCTAssertTrue(app.staticTexts["尚未登录 115"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["测试账号 1"].exists, "Signing out must hide the previous account")
        library.tap()
        XCTAssertTrue(wait { account.label.contains("连接 115 网盘") })
        XCTAssertFalse(account.label.contains("测试账号 1"))
    }

    func testAppearanceSelectionAndLicenseNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_HOME_TEST"] = "1"
        app.launchEnvironment["HPLAYER_METADATA_TEST_ENDPOINT"] = "http://127.0.0.1:8765"
        app.launch()

        let settings = app.tabBars.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()

        let appearance = app.buttons["settings.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        let settingsShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        settingsShot.name = "Settings - redesign"
        settingsShot.lifetime = .keepAlways
        add(settingsShot)
        appearance.tap()
        let light = app.buttons["settings.appearance.light"]
        let dark = app.buttons["settings.appearance.dark"]
        let system = app.buttons["settings.appearance.system"]
        XCTAssertTrue(light.waitForExistence(timeout: 10))
        light.tap()
        XCTAssertTrue(wait { light.isSelected }, "Light appearance should become selected")
        dark.tap()
        XCTAssertTrue(wait { dark.isSelected }, "Dark appearance should become selected")
        system.tap()
        XCTAssertTrue(wait { system.isSelected }, "System appearance should become selected")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        let licenses = app.buttons["settings.licenses"]
        if !licenses.isHittable { app.swipeUp() }
        XCTAssertTrue(licenses.waitForExistence(timeout: 5))
        XCTAssertTrue(licenses.isHittable)
        licenses.tap()
        XCTAssertTrue(app.navigationBars["开源许可"].waitForExistence(timeout: 5),
                      "License entry should open the bundled license list")
        XCTAssertTrue(app.staticTexts["mpv / MPVKit"].waitForExistence(timeout: 5),
                      "The shipped MPVKit license should be listed")
    }

    private func wait(timeout: TimeInterval = 10, _ predicate: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)], timeout: timeout) == .completed
    }
}
