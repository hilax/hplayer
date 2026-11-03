import SwiftUI
import UIKit

// MARK: - 独立播放器窗口

/// 播放器专用窗口。`allowedOrientations` 决定它能不能横屏：
/// 横屏播放时是 `.landscape`，切回竖屏小窗时是 `.portrait`。
final class PlayerWindow: UIWindow {
    var allowedOrientations: UIInterfaceOrientationMask = .landscape
}

final class PlayerHostingController: UIHostingController<AnyView> {
    /// 方向变化结束（含动画）后回调，用来在转好之后再淡入
    var onRotated: (() -> Void)?

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        (view.window as? PlayerWindow)?.allowedOrientations ?? .landscape
    }
    override var shouldAutorotate: Bool { true }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.onRotated?() }
    }
}

/// 打开 / 关闭播放器窗口。同一时间只有一个播放器。
@MainActor
final class PlayerWindowController {
    static let shared = PlayerWindowController()

    private(set) var window: PlayerWindow?
    private var host: PlayerHostingController?
    private var onDismissed: (() -> Void)?
    private var revealed = false
    private var revealTask: Task<Void, Never>?

    var isPresented: Bool { window != nil }

    /// 默认直接横屏播放；界面预览里只有「横屏」设计稿是横屏
    nonisolated static var startsInLandscape: Bool {
        !(InterfacePreview.active && InterfacePreview.screen != "landscape")
    }

    private func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private func mainWindow(in scene: UIWindowScene?) -> UIWindow? {
        scene?.windows.first { !($0 is PlayerWindow) && $0.windowLevel == .normal && !$0.isHidden }
            ?? scene?.windows.first { !($0 is PlayerWindow) && $0.windowLevel == .normal }
    }

    /// 弹出播放器窗口。`onDismissed` 在窗口被我们以外的原因关掉时调用，让调用方把自己的状态复位。
    func present(_ root: AnyView, landscape: Bool, onDismissed: @escaping () -> Void) {
        guard window == nil else { return }
        guard let scene = activeScene() else { onDismissed(); return }
        self.onDismissed = onDismissed
        revealed = false

        let player = PlayerWindow(windowScene: scene)
        player.allowedOrientations = landscape ? .landscape : .portrait
        player.overrideUserInterfaceStyle = .dark
        player.backgroundColor = .clear
        // 窗口层级必须比主窗口高，同时保持透明：关闭时淡出会露出下面的页面
        player.windowLevel = UIWindow.Level.normal + 1
        player.isOpaque = false

        let host = PlayerHostingController(rootView: root)
        host.view.backgroundColor = .clear
        host.onRotated = { [weak self] in self?.reveal() }
        player.rootViewController = host
        player.alpha = 0
        player.makeKeyAndVisible()

        self.window = player
        self.host = host
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()

        if landscape {
            requestOrientation(Self.preferredLandscape(), in: scene)
        } else {
            reveal()
        }
        // 兜底：方向没变化（已经是横屏、模拟器不转、系统拒绝）时也要显示出来
        revealTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            self?.reveal()
        }
    }

    /// 播放页里的「横屏 / 竖屏」按钮
    func setLandscape(_ landscape: Bool) {
        guard let window, let scene = window.windowScene else { return }
        window.allowedOrientations = landscape ? .landscape : .portrait
        requestOrientation(landscape ? Self.preferredLandscape() : .portrait, in: scene)
    }

    /// 关闭：窗口移除，系统方向回到竖屏。主窗口一直是竖屏，不会有翻转。
    func dismiss() {
        guard let player = window else { return }
        let scene = player.windowScene
        revealTask?.cancel()
        window = nil
        host = nil
        onDismissed = nil
        player.isHidden = true
        player.rootViewController = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()

        let main = mainWindow(in: scene)
        main?.makeKey()
        main?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
    }

    // MARK: 内部

    private func reveal() {
        guard !revealed, let window else { return }
        revealed = true
        revealTask?.cancel()
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) { window.alpha = 1 }
    }

    private func requestOrientation(_ mask: UIInterfaceOrientationMask, in scene: UIWindowScene) {
        host?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] _ in
            Task { @MainActor in self?.reveal() }
        }
    }

    /// 手机现在往哪边横放，界面就转向哪边（设备的 landscapeLeft 对应界面的 landscapeRight）；
    /// 竖着拿时默认 landscapeRight。
    private static func preferredLandscape() -> UIInterfaceOrientationMask {
        switch UIDevice.current.orientation {
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default: return .landscapeRight
        }
    }
}

// MARK: - SwiftUI 入口

private struct DismissPlayerWindowKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// 播放页关闭自己时调用；在独立窗口里没有 `dismiss`
    var dismissPlayerWindow: (() -> Void)? {
        get { self[DismissPlayerWindowKey.self] }
        set { self[DismissPlayerWindowKey.self] = newValue }
    }
}

private struct PlayerWindowModifier<Root: View>: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @Binding var isPresented: Bool
    let root: () -> Root

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { show in
                show ? present() : PlayerWindowController.shared.dismiss()
            }
            .onAppear { if isPresented { present() } }
    }

    private func present() {
        let binding = $isPresented
        let view = root()
            .environmentObject(appState)
            .environment(\.dismissPlayerWindow, { binding.wrappedValue = false })
        PlayerWindowController.shared.present(
            AnyView(view),
            landscape: PlayerWindowController.startsInLandscape,
            onDismissed: { binding.wrappedValue = false }
        )
    }
}

extension View {
    /// 代替 `fullScreenCover(isPresented:)`：把播放器放进独立窗口里横屏播放
    func playerWindow<Root: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Root) -> some View {
        modifier(PlayerWindowModifier(isPresented: isPresented, root: content))
    }

    /// 代替 `fullScreenCover(item:)`
    func playerWindow<Item: Identifiable, Root: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Root) -> some View {
        playerWindow(
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            ),
            content: {
                if let value = item.wrappedValue { content(value) }
            }
        )
    }
}
