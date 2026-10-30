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

    /// 关闭播放器之前调用：先让播放器自己转回竖屏，旋转动画一走完就执行 completion（真正关闭）。
    ///
    /// 整个 App 共用一个窗口，播放器横屏时下面的列表也跟着是横的。
    /// 如果先关播放器再转方向，列表会带着黑边在用户眼前整个翻转一次；
    /// 先在播放器里转好再关，回到列表时它已经是竖屏。
    ///
    /// 旋转期间播放画面自己跟着旋转动画缩放（见 PlayerVideoViewController），
    /// 所以这里不需要等一段固定时间，收到「过渡结束」的通知就关。
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

        PortraitRotation(scene: scene, completion: completion).start()
    }

    /// 等一次「转回竖屏」走完：播放画面所在页面的尺寸过渡一结束就算完成。
    /// 兜底：方向已经切过去却一直没收到过渡结束的通知（系统没有走旋转过渡），按旋转动画的时长再等一会儿；
    /// 1.5 秒还没转过来（例如系统拒绝）就不再等，直接完成。
    @MainActor
    private final class PortraitRotation {
        private let scene: UIWindowScene
        private var completion: (() -> Void)?
        private var observer: NSObjectProtocol?

        init(scene: UIWindowScene, completion: @escaping () -> Void) {
            self.scene = scene
            self.completion = completion
        }

        func start() {
            // 先登记再发请求，不会错过旋转动画结束的通知
            observer = NotificationCenter.default.addObserver(
                forName: .playerSizeTransitionDidFinish, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.transitionDidFinish() }
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
            poll(remainingChecks: 30)
        }

        private func transitionDidFinish() {
            if OrientationSupport.matches(scene.effectiveGeometry.interfaceOrientation, .portrait) { finish() }
        }

        private func poll(remainingChecks: Int) {
            guard completion != nil else { return }
            if OrientationSupport.matches(scene.effectiveGeometry.interfaceOrientation, .portrait) {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    self.finish()
                }
                return
            }
            guard remainingChecks > 0 else {
                finish()
                return
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                self.poll(remainingChecks: remainingChecks - 1)
            }
        }

        private func finish() {
            guard let completion else { return }
            self.completion = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            completion()
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

@MainActor
final class HPlayerAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationSupport.supportedOrientations
    }
}
