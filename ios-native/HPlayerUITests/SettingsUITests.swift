import XCTest

final class SettingsUITests: XCTestCase {
    func testAppIconChoicesAreAccessibleFromSettings() {
        continueAfterFailure = false
        let app = launchIconTestApp()

        openIconSettings(in: app)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "AppIconSettings - redesigned collection"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let names = ["prism", "classic", "ocean", "mint", "iris", "coral"]
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
        let app = launchIconTestApp()
        openIconSettings(in: app)

        let ocean = app.buttons["settings.appIcon.ocean"]
        for _ in 0..<6 {
            if ocean.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(ocean.isHittable)
        XCTAssertTrue(ocean.isEnabled)
        ocean.tap()
        XCTAssertTrue(wait { ocean.isSelected }, "Selection must follow the tap immediately, before any system callback")
        let notice = app.descendants(matching: .any)["settings.appIcon.notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "The redesigned in-app confirmation should appear")
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

    func testConfirmationNoticeUndoRestoresPreviousIcon() {
        continueAfterFailure = false
        let app = launchIconTestApp()
        openIconSettings(in: app)

        let coral = app.buttons["settings.appIcon.coral"]
        for _ in 0..<6 {
            if coral.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(coral.isHittable)
        coral.tap()
        let undo = app.buttons["settings.appIcon.notice.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "Success notice should offer undo")
        undo.tap()
        let prism = app.buttons["settings.appIcon.prism"]
        XCTAssertTrue(wait { prism.isSelected }, "Undo must return the selection to the previous icon")
        let done = app.buttons["settings.appIcon.notice.done"]
        if done.waitForExistence(timeout: 3) { done.tap() }
        XCTAssertTrue(wait { !app.descendants(matching: .any)["settings.appIcon.notice"].exists },
                      "Dismissing the notice should remove it")
    }

    func testSelectedIconSurvivesStaleSystemReadBackgroundReentryAndRelaunch() {
        continueAfterFailure = false
        // The simulated system deliberately keeps reporting the old primary icon.
        let app = launchIconTestApp(staleSystem: true)
        openIconSettings(in: app)
        let ocean = app.buttons["settings.appIcon.ocean"]
        for _ in 0..<6 {
            if ocean.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(ocean.isHittable)
        ocean.tap()
        XCTAssertTrue(wait { ocean.isSelected && ocean.isEnabled })

        XCUIDevice.shared.press(.home)
        // Cross the old two-second settling window before the scene becomes active.
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        XCTAssertTrue(wait { ocean.isSelected }, "Returning from the background must not restore the old selection")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        openIconSettings(in: app)
        XCTAssertTrue(ocean.isSelected, "Recreating the settings page must retain the confirmed style")

        app.terminate()
        app.launch()
        openIconSettings(in: app)
        XCTAssertTrue(ocean.isSelected, "The choice must survive relaunch even when the system getter is stale")
        XCTAssertFalse(app.buttons["settings.appIcon.prism"].isSelected)
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
        // 3.0 起「我的」多了播放、弹幕两组，外观在第一屏下面一点
        for _ in 0..<6 where !appearance.isHittable { app.swipeUp() }
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
        for _ in 0..<8 where !licenses.isHittable { app.swipeUp() }
        XCTAssertTrue(licenses.waitForExistence(timeout: 5))
        XCTAssertTrue(licenses.isHittable)
        licenses.tap()
        XCTAssertTrue(app.navigationBars["开源许可"].waitForExistence(timeout: 5),
                      "License entry should open the bundled license list")
        XCTAssertTrue(app.staticTexts["mpv / MPVKit"].waitForExistence(timeout: 5),
                      "The shipped MPVKit license should be listed")
    }

    private func launchIconTestApp(staleSystem: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_HOME_TEST"] = "1"
        app.launchEnvironment["HPLAYER_METADATA_TEST_ENDPOINT"] = "http://127.0.0.1:8765"
        app.launchEnvironment["HPLAYER_ICON_TEST_RESET"] = "1"
        if staleSystem { app.launchEnvironment["HPLAYER_ICON_STALE_SYSTEM"] = "1" }
        app.launch()
        // Subsequent launches in this test verify persistence rather than resetting it.
        app.launchEnvironment.removeValue(forKey: "HPLAYER_ICON_TEST_RESET")
        return app
    }

    private func openIconSettings(in app: XCUIApplication) {
        let settings = app.tabButton("我的")
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        let iconSettings = app.buttons["settings.appIcon"]
        for _ in 0..<6 where !iconSettings.isHittable { app.swipeUp() }
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
