import XCTest

final class CloudNavigationUITests: XCTestCase {
    /// 登录了 115 时网盘页本身就是根目录：不用再点入口，文件直接显示；子目录的面包屑第一级回到网盘页
    func testCloudRootShowsFilesDirectlyAndBreadcrumbReturnsToIt() {
        let app = launchCloud()
        defer { app.terminate() }
        let cloud = app.tabButton("网盘")
        let movies = app.buttons["library.file.100"]
        XCTAssertTrue(movies.waitForExistence(timeout: 25), "Signed in, the Cloud tab lists the root folder directly")
        XCTAssertTrue(app.buttons["library.account"].exists, "The account strip sits above the files")
        XCTAssertTrue(app.buttons["cloud.transfers"].exists && app.buttons["cloud.local"].exists, "Quick entries stay on the root")
        XCTAssertFalse(app.buttons["cloud.browse"].exists, "There is no separate browse entry any more")
        XCTAssertTrue(cloud.isHittable && cloud.isSelected)
        attach("CloudNavigation-root")

        movies.tap()
        let scienceFiction = app.buttons["library.file.101"]
        XCTAssertTrue(scienceFiction.waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["电影"].exists)
        XCTAssertFalse(cloud.isHittable, "A folder covers the Cloud tab")
        scienceFiction.tap()
        XCTAssertTrue(app.buttons["library.file.science-fiction"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["科幻"].exists)
        attach("CloudNavigation-nested")

        app.buttons["library.crumb.0"].tap()
        XCTAssertTrue(movies.waitForExistence(timeout: 5) && movies.isHittable, "The root breadcrumb returns to the Cloud tab")
        XCTAssertTrue(cloud.isHittable && cloud.isSelected)

        app.buttons["library.file.200"].tap()
        XCTAssertTrue(app.buttons["library.file.episode"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["library.crumb.0"].isHittable)
        XCTAssertFalse(app.buttons["library.crumb.100"].exists, "The new sibling must not inherit the old breadcrumb path")

        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        edge.press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(app.buttons["library.file.episode"].isHittable, "A cancelled swipe stays in the folder")
        XCTAssertFalse(cloud.isHittable)
        edge.press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(movies.waitForExistence(timeout: 5) && movies.isHittable)
        XCTAssertTrue(cloud.isHittable && cloud.isSelected)
        attach("CloudNavigation-returned")
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
