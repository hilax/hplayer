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
            controller.willClose()
            controller.dismiss(token: token)
            XCTAssertFalse(controller.isPresented)
            return
        }
        defer { controller.dismiss(token: token) }

        XCTAssertTrue(controller.isShowing(token))
        controller.willClose()
        XCTAssertFalse(controller.needsRevealHold, "开始关闭后不再等转屏淡入")
        controller.dismiss(token: token)
        XCTAssertFalse(controller.isPresented)
        XCTAssertFalse(controller.isShowing(token))
        XCTAssertFalse(dismissedExternally, "自己关掉的不算被顶替")
    }

    func testCloseBackdropSitsUnderEverythingAndFollowsPortraitBounds() throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("单元测试宿主没有可用的场景")
        }
        if scene.interfaceOrientation.isLandscape { throw XCTSkip("只在竖屏宿主里检查摆放") }
        let window = PlayerWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let snapshot = UIView()
        window.showCloseBackdrop(snapshot)

        XCTAssertTrue(window.hasCloseBackdrop)
        XCTAssertTrue(window.subviews.first === snapshot, "截图垫在播放画面最下面")
        XCTAssertFalse(snapshot.isUserInteractionEnabled, "截图不接收点击")
        XCTAssertTrue(snapshot.transform.isIdentity, "竖屏时截图正着放")
        XCTAssertEqual(snapshot.frame.width, window.bounds.width, accuracy: 0.5)
        XCTAssertEqual(snapshot.frame.height, window.bounds.height, accuracy: 0.5)

        window.removeCloseBackdrop()
        XCTAssertNil(snapshot.superview)
        XCTAssertFalse(window.hasCloseBackdrop)
    }
}
