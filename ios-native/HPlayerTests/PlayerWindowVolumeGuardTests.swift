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
        XCTAssertTrue(UIView.areAnimationsEnabled, "关闭流程不能把全局动画留在关着的状态")
    }

    func testLandscapeCloseFollowsReferenceTiming() {
        // 参考 App 录屏逐帧量的：切黑后黑约 0.17 秒，ease-in-out 约 0.25 秒淡完，大约 0.42 秒关完
        XCTAssertGreaterThanOrEqual(PlayerWindowController.exitBlackHold, 0.15)
        XCTAssertLessThanOrEqual(PlayerWindowController.exitBlackHold, 0.2)
        XCTAssertEqual(PlayerWindowController.exitBlackHold + PlayerWindowController.exitFadeDuration, 0.42, accuracy: 0.03)
        XCTAssertLessThan(PlayerWindowController.exitStatusBarFade, PlayerWindowController.exitBlackHold,
                          "状态栏在页面淡出来之前就在黑屏上出现了")
    }

    func testExitControllerStartsLandscapeThenTurnsPortraitInBlack() {
        let exit = PlayerExitController()
        exit.loadViewIfNeeded()
        XCTAssertEqual(exit.supportedInterfaceOrientations, .landscape, "换上时先保持横屏，窗口不会被立刻改成竖屏")
        exit.orientations = .portrait
        XCTAssertEqual(exit.supportedInterfaceOrientations, .portrait, "之后只支持竖屏，场景在黑屏里转回去")
        XCTAssertEqual(exit.view.backgroundColor, .black, "收尾的窗口是全黑的，转屏看不出来")
        XCTAssertFalse(exit.view.isUserInteractionEnabled)
        XCTAssertTrue(exit.prefersStatusBarHidden, "黑屏转屏时状态栏藏着，不会看到它跟着转")
        XCTAssertTrue(exit.prefersHomeIndicatorAutoHidden, "黑屏时底部横条和横屏播放一样自动隐藏")
        exit.statusBarVisible = true
        XCTAssertFalse(exit.prefersStatusBarHidden, "转好竖屏后状态栏先在黑屏上出现")
        XCTAssertEqual(exit.preferredStatusBarStyle, .lightContent, "黑屏上是白字状态栏，和参考 App 一样")
        XCTAssertTrue(exit.prefersHomeIndicatorAutoHidden, "底部横条等页面淡出来时才出现")
        exit.homeIndicatorVisible = true
        XCTAssertFalse(exit.prefersHomeIndicatorAutoHidden, "页面淡出来时底部横条照常显示")
        exit.pageStatusBarStyle = .darkContent
        exit.statusBarStyle = exit.pageStatusBarStyle
        XCTAssertEqual(exit.preferredStatusBarStyle, .darkContent, "淡完后状态栏换成页面自己的样式（跟随 App 外观）")
    }
}
