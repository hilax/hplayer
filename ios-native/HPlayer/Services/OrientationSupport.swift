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

    /// 退出播放器时转回竖屏。关闭动画进行中 iOS 可能不理第一次请求，没转过来就隔一会儿再请求，最多三次；
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

@MainActor
final class HPlayerAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationSupport.supportedOrientations
    }
}
