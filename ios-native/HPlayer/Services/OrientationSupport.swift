import UIKit

/// 方向策略：主窗口始终竖屏，只有播放器所在的独立窗口可以横屏。
///
/// 每个 UIWindow 按自己根控制器支持的方向决定要不要跟着转。
/// 播放器放进单独的 `PlayerWindow`：它横屏时，主窗口（首页、详情页……）因为只支持竖屏，
/// 不会跟着转；系统层面的东西（控制中心、屏幕录制、系统弹窗、旋转锁定）看到的是真实的横屏。
/// 关闭播放器只是把这个窗口淡出移除，主窗口从头到尾没转过，所以没有翻转。
@MainActor
final class HPlayerAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        if let player = window as? PlayerWindow { return player.allowedOrientations }
        // 没有指明窗口时（系统偶尔这样问），播放器在前台就按播放器来
        if window == nil, let player = PlayerWindowController.shared.window { return player.allowedOrientations }
        return .portrait
    }
}
