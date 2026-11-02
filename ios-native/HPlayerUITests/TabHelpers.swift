import XCTest

extension XCUIApplication {
    /// 系统标签栏上的按钮，按标签名字找：首页 / 片库 / 网盘 / 我的。
    func tabButton(_ title: String) -> XCUIElement {
        tabBars.buttons[title]
    }
}
