import XCTest

final class PerformerCollectionUITests: XCTestCase {
    func testEachPerformerLinkOpensItsOwnCollection() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_PERFORMER_TEST"] = "1"
        app.launch()

        open("演员甲", id: "演员甲", works: ["作品甲1", "作品甲2"], excludedWork: "作品乙1", in: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        open("演员乙", id: "演员乙", works: ["作品乙1", "作品乙2"], excludedWork: "作品甲1", in: app)
    }

    /// 真实的横版封面卡片（和首页「演员合集」同一套视图）：封面按高度铺满后比卡片宽得多，
    /// 伸出去的那一截不能抢右边相邻卡片的点击；演员页里的封面同理，点哪张就播放哪张。
    func testWideJacketCardsAndCoversOnlyRespondToTheirOwnTaps() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_PERFORMER_TEST"] = "wide"
        app.launchEnvironment["HPLAYER_UI_TEST_KEEP_CONTROLS_VISIBLE"] = "1"
        // 测试不写播放记录，免得首页的「继续观看」里多出测试影片
        app.launchEnvironment["HPLAYER_UI_TEST_URL"] = "about:blank"
        app.launch()
        addFailureDiagnostics(app)

        // 演员甲在左边，演员乙的横版封面向左伸出来盖在它上面：点的正是被盖住的那一块
        open("演员甲", id: "演员甲", works: ["作品甲1", "作品甲2"], excludedWork: "作品乙1", in: app,
             tapping: tapArtwork)

        // 演员页是三列网格：作品甲1在第一列，作品甲2的封面同样向左伸出来盖在它上面
        let firstCover = app.buttons["performer.work.fixture:作品甲1"].firstMatch
        XCTAssertTrue(firstCover.waitForExistence(timeout: 5))
        firstCover.tap()
        XCTAssertTrue(app.staticTexts["作品甲1.mp4"].waitForExistence(timeout: 20),
                      "Tapping the first cover must play its own video; titles on screen: \(visibleTitles(app))")
        XCTAssertFalse(app.staticTexts["作品甲2.mp4"].exists, "The neighbouring cover must not take the tap")

        let close = app.buttons["playback.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(app.navigationBars["演员甲"].waitForExistence(timeout: 20), "Closing the player returns to the collection")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // 最右边的卡片只响应自己
        open("演员乙", id: "演员乙", works: ["作品乙1", "作品乙2"], excludedWork: "作品甲1", in: app)
    }

    /// 对照：修复之前的卡片写法，点同一个位置（左边卡片封面正中间）。
    /// 如果这条测试不通过，说明「封面伸出去抢点击」不是演员对不上的原因。
    func testControlLegacyJacketOverlapStealsTheNeighbourTap() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_PERFORMER_TEST"] = "legacy"
        app.launch()
        addFailureDiagnostics(app)

        let left = app.descendants(matching: .any)["performerTest.演员甲"]
        let right = app.descendants(matching: .any)["performerTest.演员乙"]
        XCTAssertTrue(left.waitForExistence(timeout: 10))
        XCTAssertTrue(right.waitForExistence(timeout: 10))
        // 封面图是异步加载的，等它出来、伸出去的那一截才存在
        Thread.sleep(forTimeInterval: 1.5)
        let frames = "left card \(left.frame), right card \(right.frame), window \(app.windows.firstMatch.frame)"

        tapArtwork(of: left, in: app)
        XCTAssertTrue(app.navigationBars["演员乙"].waitForExistence(timeout: 5),
                      "Legacy layout: the left card's tap is expected to land on the right card; navigation bars: \(app.navigationBars.allElementsBoundByIndex.map(\.identifier)); \(frames)")
    }

    /// 点卡片封面「看得见的那一块」的正中间（封面 118×177，贴着卡片右边缘）。
    /// 不用元素自带的 tap()：它点的是辅助功能边框的中心，旧写法里那个边框把伸出去的封面也算了进去，
    /// 中心落在屏幕边上，根本没点到卡片。
    private func tapArtwork(of card: XCUIElement, in app: XCUIApplication) {
        let frame = card.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.maxX - 59, dy: frame.minY + 88))
            .tap()
    }

    private func open(
        _ name: String, id: String, works: [String], excludedWork: String, in app: XCUIApplication,
        tapping tap: ((XCUIElement, XCUIApplication) -> Void)? = nil
    ) {
        let link = app.descendants(matching: .any)["performerTest.\(id)"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        if let tap { tap(link, app) } else { link.tap() }
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5),
                      "Expected \(name)'s collection; navigation bars: \(app.navigationBars.allElementsBoundByIndex.map(\.identifier)); card frame \(link.frame)")
        for work in works {
            XCTAssertTrue(app.staticTexts[work].waitForExistence(timeout: 5))
        }
        XCTAssertFalse(app.staticTexts[excludedWork].exists,
                       "A collection must never reuse another performer's works")
    }

    private func visibleTitles(_ app: XCUIApplication) -> [String] {
        app.staticTexts.allElementsBoundByIndex.map(\.label)
    }

    private func addFailureDiagnostics(_ app: XCUIApplication) {
        addTeardownBlock {
            if self.testRun?.hasSucceeded == false {
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.lifetime = .keepAlways
                self.add(hierarchy)
                let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                screenshot.lifetime = .keepAlways
                self.add(screenshot)
            }
        }
    }
}
