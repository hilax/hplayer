import MediaPlayer
import SwiftUI
import XCTest
@testable import HPlayer

@MainActor
final class PlayerWindowVolumeGuardTests: XCTestCase {
    func testVolumeHUDGuardIsInstalledOnceAndStaysInvisible() throws {
        let window = PlayerWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        XCTAssertTrue(window.subviews.compactMap { $0 as? MPVolumeView }.isEmpty)

        window.installVolumeHUDGuard()
        window.installVolumeHUDGuard()

        let guards = window.subviews.compactMap { $0 as? MPVolumeView }
        XCTAssertEqual(guards.count, 1, "重复安装只保留一个，不会越叠越多")
        let view = try XCTUnwrap(guards.first)
        XCTAssertFalse(view.isHidden, "隐藏的音量控件系统不认，音量条还是会弹出来")
        XCTAssertGreaterThan(view.alpha, 0)
        XCTAssertLessThan(view.alpha, 0.1, "几乎透明，不能被看见")
        XCTAssertFalse(view.isUserInteractionEnabled, "不能挡住播放页的手势")
    }

    func testWillCloseThenDismissResetsState() throws {
        let controller = PlayerWindowController.shared
        let token = UUID()
        var dismissedExternally = false
        let presented = controller.present(AnyView(Color.clear), token: token, landscape: false) {
            dismissedExternally = true
        }
        guard presented != nil else {
            // 没有可用的场景：关闭流程什么都不做，也不能崩
            XCTAssertFalse(controller.willClose())
            controller.dismiss(token: token)
            XCTAssertFalse(controller.isPresented)
            return
        }
        defer { controller.dismiss(token: token) }

        XCTAssertTrue(controller.isShowing(token))
        XCTAssertFalse(controller.willClose(), "竖屏播放器走整页淡出，不切黑")
        XCTAssertFalse(controller.willClose(), "重复调用不再处理")
        XCTAssertFalse(controller.needsRevealHold, "开始关闭后不再等转屏淡入")
        controller.dismiss(token: token)
        XCTAssertFalse(controller.isPresented)
        XCTAssertFalse(controller.isShowing(token))
        XCTAssertFalse(dismissedExternally, "自己关掉的不算被顶替")
    }

    func testExitControllerIsBlackPortraitOnly() {
        let exit = PlayerExitController()
        exit.loadViewIfNeeded()
        XCTAssertEqual(exit.supportedInterfaceOrientations, .portrait, "收尾时只支持竖屏，场景才能在黑屏里转回去")
        XCTAssertEqual(exit.view.backgroundColor, .black, "收尾的窗口是全黑的，转屏看不出来")
        XCTAssertFalse(exit.view.isUserInteractionEnabled)
        exit.statusBarStyle = .darkContent
        XCTAssertEqual(exit.preferredStatusBarStyle, .darkContent, "状态栏跟随 App 外观")
    }
}
