import XCTest

final class SettingsUITests: XCTestCase {
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
