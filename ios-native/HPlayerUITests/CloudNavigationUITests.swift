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
        XCTAssertTrue(app.buttons["cloud.offline"].exists && app.buttons["cloud.recycleBin"].exists, "Quick entries stay on the root")
        XCTAssertFalse(app.buttons["cloud.transfers"].exists, "The transfer center is gone")
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

    /// 离线下载从网盘页进，返回后网盘根页和标签栏都回来
    func testCloudOfflineEntryReturnsToCloudRoot() {
        let app = launchCloud()
        defer { app.terminate() }
        let cloud = app.tabButton("网盘")
        let offline = app.buttons["cloud.offline"]
        XCTAssertTrue(offline.waitForExistence(timeout: 25))
        offline.tap()
        XCTAssertTrue(app.navigationBars["离线下载"].waitForExistence(timeout: 10))
        XCTAssertFalse(cloud.isHittable)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(offline.waitForExistence(timeout: 5) && offline.isHittable)
        XCTAssertTrue(cloud.isHittable && cloud.isSelected)
        attach("CloudNavigation-offline-returned")
    }

    /// 本机视频（含正在下载）在「我的」页
    func testMineLocalVideosOpensAndReturns() {
        let app = launchCloud()
        defer { app.terminate() }
        let mine = app.tabButton("我的")
        XCTAssertTrue(mine.waitForExistence(timeout: 25))
        mine.tap()
        let local = app.buttons["mine.local"]
        XCTAssertTrue(local.waitForExistence(timeout: 10))
        local.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.local"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["本机视频"].exists)
        XCTAssertFalse(mine.isHittable)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(local.waitForExistence(timeout: 5) && local.isHittable)
        XCTAssertTrue(mine.isHittable && mine.isSelected)
        attach("CloudNavigation-local-returned")
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
