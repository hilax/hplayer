import UIKit

/// 整个 App 只用竖屏。
///
/// 播放器的「横屏」是界面层面的横屏（把播放页内容旋转 90°），App 的真实方向始终是竖屏：
/// 这样播放页下面的页面不会跟着转，关闭播放器时也就没有翻转动画。
@MainActor
enum OrientationSupport {
    static let supportedOrientations: UIInterfaceOrientationMask = .portrait
}

@MainActor
final class HPlayerAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationSupport.supportedOrientations
    }
}
