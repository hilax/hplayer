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

    func testWillCloseCompletesAndResetsStateAcrossDismiss() throws {
        let controller = PlayerWindowController.shared
        let token = UUID()
        var dismissedExternally = false
        let presented = controller.present(AnyView(Color.clear), token: token, landscape: false) {
            dismissedExternally = true
        }
        guard presented != nil else {
            // 无窗口场景时 willClose 仍应立即触发完成回调
            var completed = false
            controller.willClose(animated: false) { completed = true }
            XCTAssertTrue(completed)
            XCTAssertFalse(dismissedExternally)
            return
        }
        defer { controller.dismiss(token: token) }

        XCTAssertTrue(controller.isShowing(token))
        var completed = false
        controller.willClose(animated: false) {
            completed = true
            controller.dismiss(token: token)
        }
        XCTAssertTrue(completed, "无动画关闭应立即完成并卸掉窗口")
        XCTAssertFalse(controller.isPresented)
        XCTAssertFalse(controller.isShowing(token))
        XCTAssertFalse(dismissedExternally)
    }
}
