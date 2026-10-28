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
            refreshSupportedOrientations(controllers)
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations), errorHandler: completion)
        }
    }

    static func restorePortrait() {
        request(.portrait)
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
