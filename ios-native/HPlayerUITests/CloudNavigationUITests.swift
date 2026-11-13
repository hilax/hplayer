import XCTest

final class CloudNavigationUITests: XCTestCase {
    func testBothCloudBrowseEntriesOpenFoldersAndSupportBreadcrumbReturn() {
        for entryID in ["library.account", "cloud.browse"] {
            let app = launchCloud()
            defer { app.terminate() }
            let cloud = app.tabButton("网盘")
            let entry = app.buttons[entryID]
            XCTAssertTrue(entry.waitForExistence(timeout: 25))
            entry.tap()

            let movies = app.buttons["library.file.100"]
            XCTAssertTrue(movies.waitForExistence(timeout: 10), "The real browse entry must resolve to a directory")
            XCTAssertTrue(app.navigationBars["115 网盘"].exists)
            XCTAssertFalse(cloud.isHittable)
            movies.tap()
            let scienceFiction = app.buttons["library.file.101"]
            XCTAssertTrue(scienceFiction.waitForExistence(timeout: 5))
            scienceFiction.tap()
            XCTAssertTrue(app.buttons["library.file.science-fiction"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.navigationBars["科幻"].exists)
            attach("CloudNavigation-nested-\(entryID)")

            app.buttons["library.crumb.0"].tap()
            XCTAssertTrue(movies.isHittable, "The root breadcrumb pops both child folders")
            XCTAssertFalse(cloud.isHittable, "The directory root still covers the Cloud tab")
            app.buttons["library.file.200"].tap()
            XCTAssertTrue(app.buttons["library.file.episode"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["library.crumb.0"].isHittable)
            XCTAssertFalse(app.buttons["library.crumb.100"].exists, "The new sibling must not inherit the old breadcrumb path")

            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(movies.isHittable)
            let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            edge.press(forDuration: 0.05,
                       thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)),
                       withVelocity: .slow, thenHoldForDuration: 0.3)
            XCTAssertTrue(movies.isHittable)
            XCTAssertFalse(cloud.isHittable)
            edge.press(forDuration: 0.05,
                       thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)),
                       withVelocity: .slow, thenHoldForDuration: 0.1)
            XCTAssertTrue(cloud.isHittable && cloud.isSelected)
            XCTAssertTrue(entry.isHittable)
            attach("CloudNavigation-returned-\(entryID)")
        }
    }

    func testCloudTransferCenterResolvesNestedPagesAndReturnsToCloudRoot() {
        let app = launchCloud()
        defer { app.terminate() }
        let cloud = app.tabButton("网盘")
        let transfers = app.buttons["cloud.transfers"]
        XCTAssertTrue(transfers.waitForExistence(timeout: 25))
        transfers.tap()
        let downloads = app.buttons["transfers.downloads"]
        XCTAssertTrue(downloads.waitForExistence(timeout: 10))
        XCTAssertFalse(cloud.isHittable)
        downloads.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.downloads"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(cloud.isHittable)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(downloads.isHittable)
        XCTAssertFalse(cloud.isHittable)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(transfers.isHittable)
        XCTAssertTrue(cloud.isHittable && cloud.isSelected)
        attach("CloudNavigation-transfer-returned")
    }

    private func launchCloud() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_DESIGN_SCREEN"] = "library"
        app.launch()
        return app
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
