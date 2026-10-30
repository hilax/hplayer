import UIKit

@MainActor
enum OrientationSupport {
    private(set) static var supportedOrientations: UIInterfaceOrientationMask = .portrait

    static func request(
        _ orientations: UIInterfaceOrientationMask,
        completion: @escaping (Error?) -> Void = { _ in }
    ) {
        supportedOrientations = orientations
        guard let scene = activeScene, let window = keyWindow(in: scene), let root = window.rootViewController else {
            completion(OrientationError.noActiveWindow)
            return
        }

        let controllers = viewControllers(startingAt: root)
        refreshSupportedOrientations(controllers)

        // UIKit recalculates the presented controller's mask after the current run loop.
        DispatchQueue.main.async {
            performRequest(
                scene: scene,
                controllers: controllers,
                orientations: orientations,
                completion: completion,
                retryCount: 1
            )
        }
    }

    /// 关闭播放器之前调用：先让播放器自己转回竖屏，等旋转动画走完再执行 completion（真正关闭）。
    ///
    /// 整个 App 共用一个窗口，播放器横屏时下面的列表也跟着是横的。
    /// 如果先关播放器再转方向，列表会带着黑边在用户眼前整个翻转一次；
    /// 先在播放器里转好再关，回到列表时它已经是竖屏。
    static func rotateToPortrait(then completion: @escaping () -> Void) {
        supportedOrientations = .portrait
        guard let scene = activeScene, let window = keyWindow(in: scene), let root = window.rootViewController else {
            completion()
            return
        }
        refreshSupportedOrientations(viewControllers(startingAt: root))
        if matches(scene.effectiveGeometry.interfaceOrientation, .portrait) {
            completion()
            return
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        waitForPortrait(scene: scene, remainingChecks: 30, completion: completion)
    }

    private static func waitForPortrait(scene: UIWindowScene, remainingChecks: Int, completion: @escaping () -> Void) {
        if matches(scene.effectiveGeometry.interfaceOrientation, .portrait) {
            // 方向已经切过去了，再等旋转动画走完
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { completion() }
            return
        }
        guard remainingChecks > 0 else {
            // 1.5 秒还没转过来（例如系统拒绝），不再等，直接关闭
            completion()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            waitForPortrait(scene: scene, remainingChecks: remainingChecks - 1, completion: completion)
        }
    }

    /// 退出播放器时转回竖屏（兜底：播放器不是从关闭按钮退出时）。关闭动画进行中 iOS 可能不理第一次请求，没转过来就隔一会儿再请求，最多三次；
    /// 期间如果又打开了播放器（方向限制已经不是竖屏），就不再坚持。
    static func restorePortrait(attempts: Int = 3) {
        request(.portrait) { _ in
            guard attempts > 1, supportedOrientations == .portrait else { return }
            if let scene = activeScene, matches(scene.effectiveGeometry.interfaceOrientation, .portrait) { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard supportedOrientations == .portrait else { return }
                restorePortrait(attempts: attempts - 1)
            }
        }
    }

    /// Normal dismissal already requested portrait. Retry only when it did not
    /// take effect, and never override a newly opened landscape player.
    static func restorePortraitIfNeeded() {
        guard supportedOrientations == .portrait, let scene = activeScene,
              !matches(scene.effectiveGeometry.interfaceOrientation, .portrait) else { return }
        restorePortrait()
    }

    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    private static func keyWindow(in scene: UIWindowScene) -> UIWindow? {
        scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
    }

    private static func refreshSupportedOrientations(_ controllers: [UIViewController]) {
        controllers.forEach { $0.setNeedsUpdateOfSupportedInterfaceOrientations() }
        UIViewController.attemptRotationToDeviceOrientation()
    }

    private static func performRequest(
        scene: UIWindowScene,
        controllers: [UIViewController],
        orientations: UIInterfaceOrientationMask,
        completion: @escaping (Error?) -> Void,
        retryCount: Int
    ) {
        // A later player may already have requested a different orientation.
        guard supportedOrientations == orientations else { completion(nil); return }
        refreshSupportedOrientations(controllers)
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { error in
            // Some iOS versions report an error for the first request while UIKit is
            // still recalculating a presented controller's supported orientations.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                if matches(scene.effectiveGeometry.interfaceOrientation, orientations) {
                    completion(nil)
                } else if retryCount > 0 {
                    performRequest(
                        scene: scene,
                        controllers: controllers,
                        orientations: orientations,
                        completion: completion,
                        retryCount: retryCount - 1
                    )
                } else {
                    completion(error)
                }
            }
        }
    }

    private static func matches(
        _ orientation: UIInterfaceOrientation,
        _ mask: UIInterfaceOrientationMask
    ) -> Bool {
        switch orientation {
        case .portrait, .portraitUpsideDown:
            return mask.contains(.portrait)
        case .landscapeLeft, .landscapeRight:
            return mask.contains(.landscape)
        default:
            return false
        }
    }

    private static func viewControllers(startingAt root: UIViewController) -> [UIViewController] {
        var result: [UIViewController] = []
        var pending = [root]

        while let controller = pending.popLast() {
            result.append(controller)
            if let presented = controller.presentedViewController {
                pending.append(presented)
            }
            if let navigation = controller as? UINavigationController, let visible = navigation.visibleViewController {
                pending.append(visible)
            }
            if let tab = controller as? UITabBarController, let selected = tab.selectedViewController {
                pending.append(selected)
            }
            pending.append(contentsOf: controller.children)
        }
        return result
    }

    private enum OrientationError: LocalizedError {
        case noActiveWindow

        var errorDescription: String? {
            "播放页尚未连接到活动窗口"
        }
    }
}

/// A non-key window keeps the rotation and the full-screen dismissal hidden until
/// SwiftUI has actually removed the player. It never takes over keyboard focus.
@MainActor
enum PlayerDismissCover {
    private static var window: UIWindow?
    private static var currentID: UUID?

    static func show(then covered: @escaping (UUID?) -> Void) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            covered(nil)
            return
        }
        removeImmediately()
        let id = UUID()
        let cover = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view.backgroundColor = .black
        controller.view.isAccessibilityElement = false
        cover.rootViewController = controller
        cover.backgroundColor = .black
        cover.windowLevel = .normal + 1
        cover.frame = scene.coordinateSpace.bounds
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.alpha = 0
        cover.isHidden = false // Do not call makeKeyAndVisible().
        currentID = id
        window = cover
        UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
            cover.alpha = 1
        } completion: { _ in
            guard currentID == id else { return }
            covered(id)
        }
    }

    static func reveal(_ id: UUID?) {
        guard let id, currentID == id, let cover = window else { return }
        // SwiftUI can report onDisappear before the full-screen transition ends.
        // Keep the cover until UIKit finishes dismissing; when no coordinator is
        // exposed, leave enough time for the standard dismissal animation.
        if let scene = cover.windowScene, let coordinator = transitionCoordinator(in: scene),
           coordinator.animate(alongsideTransition: nil, completion: { _ in fadeOut(id) }) {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { fadeOut(id) }
    }

    private static func fadeOut(_ id: UUID) {
        guard currentID == id, let cover = window else { return }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
            cover.alpha = 0
        } completion: { _ in
            guard currentID == id else { return }
            removeImmediately()
        }
    }

    private static func transitionCoordinator(in scene: UIWindowScene) -> UIViewControllerTransitionCoordinator? {
        guard let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return nil }
        var pending = [root]
        while let controller = pending.popLast() {
            if let coordinator = controller.transitionCoordinator { return coordinator }
            if let presented = controller.presentedViewController { pending.append(presented) }
            pending.append(contentsOf: controller.children)
        }
        return nil
    }

    static func removeImmediately() {
        window?.isHidden = true
        window = nil
        currentID = nil
    }
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
