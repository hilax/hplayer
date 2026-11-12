import XCTest
import UIKit

final class RedesignFlowUITests: XCTestCase {
    func testHomeCarouselChangesTheAmbientBackground() throws {
        let app = launch("home")
        defer { app.terminate() }
        let position = app.descendants(matching: .any)["home.carouselPosition"].firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 25))
        XCTAssertTrue(app.buttons["home.heroPlay"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        let before = XCUIScreen.main.screenshot()
        let firstPosition = try XCTUnwrap(position.value as? String)

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.28))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.28))
        start.press(forDuration: 0.05, thenDragTo: end)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let current = position.value as? String else { return false }
            return current != firstPosition
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 10), .completed)
        Thread.sleep(forTimeInterval: 2)
        let after = XCUIScreen.main.screenshot()
        let firstColor = try backgroundSample(before)
        let secondColor = try backgroundSample(after)
        let difference = zip(firstColor, secondColor).reduce(0) { $0 + abs($1.0 - $1.1) }
        XCTAssertGreaterThan(difference, 10, "The page colour should follow the selected artwork")

        for (name, screenshot) in [("Home artwork tint first cover", before), ("Home artwork tint next cover", after)] {
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testHomeCarouselSwipeKeepsTheShelvesInPlace() throws {
        continueAfterFailure = false
        let app = launch("home")
        defer { app.terminate() }
        let position = app.descendants(matching: .any)["home.carouselPosition"].firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 25))
        let movies = app.staticTexts["home.shelf.movies"].firstMatch
        XCTAssertTrue(movies.waitForExistence(timeout: 10))
        let shelfFrame = movies.frame
        let before = position.value as? String

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.28))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.28))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (position.value as? String) != before
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 10), .completed)
        XCTAssertEqual(movies.frame.minY, shelfFrame.minY, accuracy: 1, "Swiping the carousel must not scroll the page")
        // Only the visible slide is exposed, so its play button is the one found.
        let play = app.buttons["home.heroPlay"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(play.isHittable)
        // The whole card is the play target and it settled on a whole page, not half a page away.
        XCTAssertEqual(play.frame.minX, 16, accuracy: 3, "The carousel must settle on a whole page")
        XCTAssertLessThanOrEqual(play.frame.maxY, position.frame.maxY + 8, "The tap target stays inside the card")
        XCTAssertFalse(app.buttons["影片选项"].exists, "The carousel has no buttons of its own; options live in the long-press menu")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Home carousel after swipe"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testHomeCarouselAdvancesOnItsOwn() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_DESIGN_SCREEN"] = "home"
        app.launchEnvironment["HPLAYER_CAROUSEL_AUTOPLAY"] = "1"
        app.launch()
        defer { app.terminate() }
        let position = app.descendants(matching: .any)["home.carouselPosition"].firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 25))
        let before = position.value as? String
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (position.value as? String) != before
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 12), .completed, "The carousel turns the page by itself")
    }

    private func backgroundSample(_ screenshot: XCUIScreenshot) throws -> [Int] {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        // The narrow left margin at the very top carries the ambient colour of the current slide.
        let rect = CGRect(x: CGFloat(image.width / 100), y: CGFloat(image.height * 5 / 100),
                          width: CGFloat(max(1, image.width / 100)), height: CGFloat(max(1, image.height / 100)))
        let sample = try XCTUnwrap(image.cropping(to: rect))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                              bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .high
        context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel.prefix(3).map(Int.init)
    }

    func testNavigationTitleDoesNotRepeatInContent() {
        let app = launch("metadata")
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["资料来源"].waitForExistence(timeout: 20))
        let page = app.scrollViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        XCTAssertFalse(page.staticTexts["资料来源"].exists)
        XCTAssertFalse(app.staticTexts["METADATA SOURCES"].exists)
    }

    func testSourcePanelAndFilmMatchingRoute() {
        let app = launch("home")
        defer { app.terminate() }
        let sources = app.buttons["home.sources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 20))
        sources.tap()
        XCTAssertTrue(app.staticTexts["添加影片"].waitForExistence(timeout: 5))
        for title in ["导入本机视频", "添加 115 文件夹", "打开磁力链接"] { XCTAssertTrue(app.staticTexts[title].exists) }
        XCTAssertFalse(app.staticTexts["开始全盘扫描"].exists, "Home's add panel only concerns playable content")
        app.buttons["关闭"].tap()
        // 轮播卡片上没有按钮：长按卡片弹出菜单，「更多选项」打开影片选项面板。
        app.buttons["home.heroPlay"].firstMatch.press(forDuration: 1.2)
        let more = app.buttons["更多选项"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "Long-pressing a featured slide shows its menu")
        XCTAssertTrue(app.buttons["匹配封面"].firstMatch.exists)
        more.tap()
        XCTAssertTrue(app.staticTexts["影片选项"].waitForExistence(timeout: 5))
        app.staticTexts["匹配封面"].tap()
        XCTAssertTrue(app.textFields["metadata.query"].waitForExistence(timeout: 5))
    }

    func testBatchSelectionExcludesFoldersAndUpdatesPlayCount() {
        // 导入流程里的目录选择：只能选视频，文件夹点不了
        let app = launch("files-import")
        defer { app.terminate() }
        let selected = app.buttons["播放所选 · 2 项"]
        XCTAssertTrue(selected.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["library.file.dir-1"].exists)
        app.buttons["library.file.movie-0"].tap()
        XCTAssertTrue(app.buttons["播放所选 · 1 项"].exists)
        app.buttons["全选"].tap()
        XCTAssertTrue(app.buttons["播放所选 · 4 项"].exists)
        app.buttons["全不选"].tap()
        let empty = app.buttons["播放所选 · 0 项"]
        XCTAssertTrue(empty.exists)
        XCTAssertFalse(empty.isEnabled)
    }

    func testFileManagementSelectionCountsItemsAndGatesSingleItemActions() {
        let app = launch("files-select")
        defer { app.terminate() }
        let title = app.staticTexts["library.selectionTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertEqual(title.label, "已选 3 项")
        // 选了多项：能移动、复制、删除，但不能重命名，也不能看单个文件的信息
        XCTAssertTrue(app.buttons["library.dock.move"].isEnabled)
        XCTAssertTrue(app.buttons["library.dock.delete"].isEnabled)
        XCTAssertFalse(app.buttons["library.dock.rename"].isEnabled)
        XCTAssertFalse(app.buttons["library.dock.info"].isEnabled)
        // 取消一个视频和文件夹，只剩一个视频：重命名和信息可用
        app.buttons["library.file.movie-1"].tap()
        app.buttons["library.file.dir-3"].tap()
        XCTAssertTrue(wait { title.label == "已选 1 项" })
        XCTAssertTrue(app.buttons["library.dock.rename"].isEnabled)
        XCTAssertTrue(app.buttons["library.dock.info"].isEnabled)
        // 全选之后再全不选：没有选中项时，删除不可用
        app.buttons["全选"].tap()
        XCTAssertTrue(wait { title.label == "已选 7 项" })
        app.buttons["全不选"].tap()
        XCTAssertTrue(wait { title.label == "选择项目" })
        XCTAssertFalse(app.buttons["library.dock.delete"].isEnabled)
    }

    func testRecycleBinSelectionShowsRestoreAndPermanentDelete() {
        let app = launch("recycle")
        defer { app.terminate() }
        let summary = app.staticTexts["library.recycle.dock.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 20))
        XCTAssertEqual(summary.label, "已选 2 项")
        XCTAssertTrue(app.buttons["library.recycle.restore"].isEnabled)
        XCTAssertTrue(app.buttons["library.recycle.delete"].isEnabled)
        // 全部取消选择后，底部的操作栏消失
        app.buttons["library.recycle.row.9003"].tap()
        app.buttons["library.recycle.row.9004"].tap()
        XCTAssertTrue(wait { !app.buttons["library.recycle.restore"].exists })
    }

    func testOfflineTasksSwitchBetweenRunningDoneAndFailed() {
        let app = launch("offline")
        defer { app.terminate() }
        let running = app.buttons["library.offline.segment.running"]
        XCTAssertTrue(running.waitForExistence(timeout: 20))
        XCTAssertTrue(running.isSelected)
        app.buttons["library.offline.segment.done"].tap()
        XCTAssertTrue(wait { app.buttons["library.offline.segment.done"].isSelected })
        app.buttons["library.offline.segment.failed"].tap()
        XCTAssertTrue(wait { app.buttons["library.offline.segment.failed"].isSelected })
        XCTAssertFalse(running.isSelected)
    }

    private func wait(_ predicate: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)], timeout: 10) == .completed
    }

    func testPlayerPanelsCloseBackToPlayback() {
        let app = launch("portrait")
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["playback.more"].waitForExistence(timeout: 20))
        app.buttons["playback.more"].tap()
        XCTAssertTrue(app.staticTexts["播放设置"].waitForExistence(timeout: 5))
        app.buttons["1.5"].tap()
        app.buttons["关闭设置"].tap()
        app.buttons["playback.tracks"].tap()
        XCTAssertTrue(app.staticTexts["字幕与音轨"].exists)
        XCTAssertTrue(app.buttons["关闭字幕"].exists)
        XCTAssertTrue(app.staticTexts["音轨"].firstMatch.exists)
        app.buttons["关闭设置"].tap()
        let aspect = app.buttons["playback.aspect"]
        XCTAssertTrue(aspect.waitForExistence(timeout: 5))
        XCTAssertTrue(aspect.isHittable)
        XCTAssertGreaterThanOrEqual(aspect.frame.height, 44)
        aspect.tap()
        XCTAssertTrue(app.staticTexts["画面比例"].waitForExistence(timeout: 5))
        app.buttons["关闭画面比例"].tap()
        app.buttons["playback.playlist"].tap()
        XCTAssertTrue(app.buttons["关闭选集"].waitForExistence(timeout: 5))
        app.buttons["关闭选集"].tap()
        XCTAssertTrue(app.buttons["playback.playPause"].isHittable)
    }

    private func launch(_ screen: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_DESIGN_SCREEN"] = screen
        app.launchEnvironment["HPLAYER_DESIGN_STYLE"] = "dark"
        app.launchEnvironment["HPLAYER_UI_TEST_115_HEADERS"] = "1"
        app.launchEnvironment["HPLAYER_UI_TEST_115_COOKIE"] = "UID=ui-test; CID=ui-test; SEID=ui-test; KID=ui-test"
        app.launchEnvironment["HPLAYER_UI_TEST_URL"] = "http://127.0.0.1:8765/hls-fixture/index.m3u8"
        app.launch()
        return app
    }
}
