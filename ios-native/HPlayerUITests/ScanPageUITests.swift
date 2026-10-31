import XCTest

final class ScanPageUITests: XCTestCase {
    func testIdleScanPageAndPerformerControlsInBothAppearances() {
        continueAfterFailure = false
        for style in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchEnvironment["HPLAYER_SCAN_TEST_STYLE"] = style
            app.launch()

            XCTAssertTrue(app.staticTexts["扫描你的 115 片库"].waitForExistence(timeout: 10),
                          "Opening the page must leave the scanner idle")
            XCTAssertTrue(app.buttons["scan.start"].exists)
            XCTAssertFalse(app.buttons["scan.pause"].exists,
                           "The page must not start a scan on entry")

            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "115 scan page - \(style)"
            screenshot.lifetime = .keepAlways
            add(screenshot)

            let sources = app.buttons["scan.sources"]
            if !sources.isHittable { app.swipeUp() }
            XCTAssertTrue(sources.waitForExistence(timeout: 5))
            sources.tap()
            let adultMatching = app.switches["scan.adultMatching"]
            XCTAssertTrue(adultMatching.waitForExistence(timeout: 5))
            let originallyEnabled = adultMatching.value as? String == "1"
            if !originallyEnabled { setSwitch(adultMatching, enabled: true) }
            let sourcesBar = app.navigationBars["资料来源"]
            XCTAssertTrue(sourcesBar.buttons["媒体库管理"].waitForExistence(timeout: 5))
            sourcesBar.buttons["媒体库管理"].tap()
            XCTAssertTrue(app.navigationBars["媒体库管理"].waitForExistence(timeout: 5))
            let enrich = app.buttons["scan.enrichPerformers"]
            if !enrich.isHittable { app.swipeUp() }
            XCTAssertTrue(enrich.waitForExistence(timeout: 5),
                          "Enabling catalog matching should expose performer enrichment")
            XCTAssertFalse(enrich.isEnabled, "There are no recognized videos to enrich in the empty test library")
            if !originallyEnabled {
                if !sources.isHittable { app.swipeDown() }
                sources.tap()
                setSwitch(adultMatching, enabled: false)
            }
            app.terminate()
        }
    }
    private func setSwitch(_ control: XCUIElement, enabled: Bool) {
        // In a Form the accessibility frame includes the label. Hit the actual
        // trailing switch, rather than tapping the middle of the label cell.
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let expected = enabled ? "1" : "0"
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            control.value as? String == expected
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed,
                       "Catalog matching switch should change before returning")
    }

}
