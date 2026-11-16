import XCTest

final class SocialComposerUITests: XCTestCase {
    func testComposerClosesAutomaticallyWhenKeyboardDismisses() {
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

        // 1. 弹幕模式字数不足按键盘发送：提示错误且保持打开，之后点遮罩可正常收起
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

        // 2. 弹幕模式正常输入后收起键盘：输入栏必须自动关闭隐藏
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

        // 3. 评论模式（多行输入框）输入后收起键盘：输入栏同样必须自动关闭隐藏
        app.buttons["composerTest.openComment"].tap()
        let commentField = app.textViews["composer.text"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5))
        XCTAssertTrue(commentField.waitForExistence(timeout: 5))
        XCTAssertEqual(state.label, "open")

        commentField.tap()
        commentField.typeText("abc")
        if wait(timeout: 2, { app.keyboards.count > 0 }) {
            app.buttons["composerTest.dismissKeyboard"].tap()
            XCTAssertTrue(wait(timeout: 3) { app.keyboards.count == 0 }, "键盘应已收起")
            XCTAssertTrue(wait(timeout: 3) { !sendButton.exists && state.label == "closed" },
                          "键盘收起后评论输入栏必须随之关闭隐藏")
        } else {
            dismissMask.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
            XCTAssertTrue(wait(timeout: 3) { !sendButton.exists && state.label == "closed" })
        }
    }

    private func wait(timeout: TimeInterval = 5, _ predicate: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)],
                       timeout: timeout) == .completed
    }
}
