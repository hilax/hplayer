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

    private func open(_ name: String, id: String, works: [String], excludedWork: String, in app: XCUIApplication) {
        let link = app.descendants(matching: .any)["performerTest.\(id)"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5))
        for work in works {
            XCTAssertTrue(app.staticTexts[work].waitForExistence(timeout: 5))
        }
        XCTAssertFalse(app.staticTexts[excludedWork].exists,
                       "A collection must never reuse another performer's works")
    }
}
