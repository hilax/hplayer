import XCTest

final class SocialComposerUITests: XCTestCase {
    func testDanmakuOverlayAndDockedCommentBarKeyboardBehavior() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_COMPOSER_TEST"] = "1"
        app.launch()
        defer { app.terminate() }

        let state = app.staticTexts["composerTest.state"]
        XCTAssertTrue(state.waitForExistence(timeout: 15))
        XCTAssertEqual(state.label, "closed")

        let sendButton = app.buttons["composer.send"]
        let dismissMask = app.buttons["收起输入框"]

        // 1. 弹幕浮层：字数不足按键盘发送保留并提示，点遮罩可收起
        app.buttons["composerTest.openDanmaku"].tap()
        let danmakuField = app.textFields["composer.text"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5))
        XCTAssertTrue(danmakuField.waitForExistence(timeout: 5))
        XCTAssertEqual(state.label, "open")

        danmakuField.tap()
        danmakuField.typeText("ab\n")
        XCTAssertTrue(app.staticTexts["至少写 3 个字"].waitForExistence(timeout: 3), "字数不足提示应显示")
        XCTAssertTrue(sendButton.exists, "字数不足时输入栏不能被误关")

        dismissMask.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        XCTAssertTrue(wait(timeout: 3) { !sendButton.exists && state.label == "closed" }, "点遮罩应关闭输入栏")

        // 2. 弹幕浮层：键盘收起后自动滑落关闭
        app.buttons["composerTest.openDanmaku"].tap()
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5))
        XCTAssertTrue(danmakuField.waitForExistence(timeout: 5))
        danmakuField.tap()
        danmakuField.typeText("abc")
        if wait(timeout: 2, { app.keyboards.count > 0 }) {
            app.buttons["composerTest.dismissKeyboard"].tap()
            XCTAssertTrue(wait(timeout: 3) { app.keyboards.count == 0 }, "键盘应已收起")
            XCTAssertTrue(wait(timeout: 3) { !sendButton.exists && state.label == "closed" },
                          "键盘收起后弹幕输入栏必须随之关闭隐藏")
        } else {
            dismissMask.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
            XCTAssertTrue(wait(timeout: 3) { !sendButton.exists && state.label == "closed" })
        }

        // 3. 评论页常驻底栏：只有一个底部输入框，键盘顶上来，收起后随键盘退回原底部
        app.buttons["composerTest.openCommentsPage"].tap()
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5))
        let commentField = app.textViews["composer.text"].exists ? app.textViews["composer.text"] : app.textFields["composer.text"]
        XCTAssertTrue(commentField.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "composer.send").count, 1, "评论页底部只能有一个发送栏")
        let restingMinY = sendButton.frame.minY

        commentField.tap()
        commentField.typeText("abc")
        XCTAssertEqual(app.buttons.matching(identifier: "composer.send").count, 1, "弹出键盘时不能再叠加第二个输入栏")
        if wait(timeout: 2, { app.keyboards.count > 0 }) {
            XCTAssertTrue(wait(timeout: 3) { sendButton.frame.minY < restingMinY - 100 },
                          "键盘出现时底部输入框应被顶到键盘上方")
            app.buttons["composerTest.dismissCommentsKeyboard"].tap()
            XCTAssertTrue(wait(timeout: 3) { app.keyboards.count == 0 }, "键盘应已收起")
            XCTAssertTrue(commentField.exists && sendButton.exists, "键盘收起后评论页底部输入框应继续常驻")
            XCTAssertTrue(wait(timeout: 3) { abs(sendButton.frame.minY - restingMinY) <= 2 },
                          "键盘收起后评论页底部输入框应随键盘退回原来的底部位置")
        }
    }

    private func wait(timeout: TimeInterval = 5, _ predicate: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)],
                       timeout: timeout) == .completed
    }
}
