import XCTest

final class SettingsUITests: XCTestCase {
    func testAppIconChoicesAreAccessibleFromSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_HOME_TEST"] = "1"
        app.launchEnvironment["HPLAYER_METADATA_TEST_ENDPOINT"] = "http://127.0.0.1:8765"
        app.launch()

        openIconSettings(in: app)
        let names = ["prism", "classic", "night", "aurora", "sunset", "ocean", "mint", "iris", "coral"]
        var found = Set<String>()
        var selected = Set<String>()
        for _ in 0..<6 {
            for name in names {
                let button = app.buttons["settings.appIcon.\(name)"]
                if button.exists {
                    found.insert(name)
                    if button.isSelected { selected.insert(name) }
                }
            }
            if found.count == names.count { break }
            app.swipeUp()
        }
        XCTAssertEqual(found, Set(names), "All bundled styles should appear in settings")
        XCTAssertEqual(selected.count, 1, "Exactly one installed icon should be selected")
    }

    func testCanRestoreDefaultPrismAfterChangingIcon() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_HOME_TEST"] = "1"
        app.launchEnvironment["HPLAYER_METADATA_TEST_ENDPOINT"] = "http://127.0.0.1:8765"
        app.launch()
        openIconSettings(in: app)

        let ocean = app.buttons["settings.appIcon.ocean"]
        for _ in 0..<6 {
            if ocean.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(ocean.isHittable)
        XCTAssertTrue(ocean.isEnabled)
        ocean.tap()
        dismissIconChangeAlert(in: app)
        XCTAssertTrue(wait { ocean.isSelected }, "The system should switch to the requested alternate")

        let restore = app.buttons["settings.appIcon.restoreDefault"]
        for _ in 0..<6 {
            if restore.isHittable { break }
            app.swipeDown()
        }
        XCTAssertTrue(restore.isHittable)
        XCTAssertTrue(restore.isEnabled)
        restore.tap()
        dismissIconChangeAlert(in: app)
        let prism = app.buttons["settings.appIcon.prism"]
        XCTAssertTrue(wait { prism.isSelected && !restore.isEnabled },
                      "Restore must return the system to its primary icon, not another named alternate")

        app.terminate()
        app.launch()
        openIconSettings(in: app)
        XCTAssertTrue(prism.isSelected, "The restored primary icon should remain selected after relaunch")
        XCTAssertFalse(restore.isEnabled)
    }

    func testAppearanceSelectionAndLicenseNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_HOME_TEST"] = "1"
        app.launchEnvironment["HPLAYER_METADATA_TEST_ENDPOINT"] = "http://127.0.0.1:8765"
        app.launch()

        let settings = app.tabButton("我的")
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

    private func openIconSettings(in app: XCUIApplication) {
        let settings = app.tabButton("我的")
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        let iconSettings = app.buttons["settings.appIcon"]
        if !iconSettings.isHittable { app.swipeUp() }
        XCTAssertTrue(iconSettings.waitForExistence(timeout: 10))
        iconSettings.tap()
        XCTAssertTrue(app.navigationBars["应用图标"].waitForExistence(timeout: 10))
    }

    private func dismissIconChangeAlert(in app: XCUIApplication) {
        for owner in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
            let alert = owner.alerts.firstMatch
            if alert.waitForExistence(timeout: 2) { alert.buttons.firstMatch.tap() }
        }
    }

    private func wait(timeout: TimeInterval = 10, _ predicate: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)], timeout: timeout) == .completed
    }
}
