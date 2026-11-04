import MediaPlayer
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
}
