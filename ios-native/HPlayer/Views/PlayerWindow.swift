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
        pendingDebug = []
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
            // 等窗口成为 key window、系统登记完它的支持方向，再请求转屏
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard let self, self.window != nil else { return }
                self.requestOrientation(Self.preferredLandscape(), in: scene)
            }
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
        debugLabel = nil
        debugLines = []
        pendingDebug = []
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

    /// 请求系统把界面转到指定方向。失败（或没转成）时重试，最后用旧办法兜底；
    /// 过程和结果显示在播放页左上角的小字里，方便真机排查。
    private func requestOrientation(_ mask: UIInterfaceOrientationMask, in scene: UIWindowScene, attempt: Int = 0) {
        let wantLandscape = !mask.contains(.portrait)
        host?.setNeedsUpdateOfSupportedInterfaceOrientations()
        window?.makeKey()
        debug("请求\(Self.name(mask)) #\(attempt) 窗口=\(window.map { Self.name($0.allowedOrientations) } ?? "-")")
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] error in
            Task { @MainActor in self?.debug("系统拒绝：\(error.localizedDescription)") }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, self.window != nil else { return }
            let landscape = scene.interfaceOrientation.isLandscape
            self.debug("结果 scene=\(scene.interfaceOrientation.rawValue) 窗口=\(Int(self.window?.bounds.width ?? 0))×\(Int(self.window?.bounds.height ?? 0))")
            if landscape == wantLandscape { self.reveal(); return }
            if attempt < 2 {
                self.requestOrientation(mask, in: scene, attempt: attempt + 1)
            } else {
                // 旧办法：直接改设备方向再让系统重新评估
                let target: UIInterfaceOrientation = wantLandscape ? .landscapeRight : .portrait
                UIDevice.current.setValue(target.rawValue, forKey: "orientation")
                UIViewController.attemptRotationToDeviceOrientation()
                self.debug("旧办法兜底")
                self.reveal()
            }
        }
    }

    private static func name(_ mask: UIInterfaceOrientationMask) -> String {
        switch mask {
        case .portrait: return "竖"
        case .landscape: return "横"
        case .landscapeLeft: return "横L"
        case .landscapeRight: return "横R"
        default: return "?\(mask.rawValue)"
        }
    }

    // MARK: 原型调试信息（验证通过后删掉）

    private var debugLabel: UILabel?
    private var debugLines: [String] = []
    private var pendingDebug: [String] = []

    /// 系统问「这个窗口支持哪些方向」时也记一笔（AppDelegate 调用），看系统到底传的是哪个窗口
    func logOrientationQuery(window: UIWindow?, answer: UIInterfaceOrientationMask) {
        let kind: String
        if window == nil { kind = "nil" } else if window is PlayerWindow { kind = "播放器窗" } else { kind = "主窗" }
        debug("询问 \(kind) → \(Self.name(answer))")
    }

    private func debug(_ text: String) {
        pendingDebug.append(text)
        if pendingDebug.count > 8 { pendingDebug.removeFirst() }
        guard let window else { return }
        debugLines = pendingDebug
        let label: UILabel
        if let existing = debugLabel { label = existing } else {
            label = UILabel()
            label.numberOfLines = 0
            label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            label.textColor = .yellow
            label.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            label.isUserInteractionEnabled = false
            window.addSubview(label)
            debugLabel = label
        }
        label.text = debugLines.joined(separator: "\n")
        label.accessibilityIdentifier = "player.debug"
        label.accessibilityLabel = label.text
        let width = min(window.bounds.width - 120, 320)
        let size = label.sizeThatFits(CGSize(width: width, height: 200))
        label.frame = CGRect(x: 60, y: 4, width: width, height: size.height)
        window.bringSubviewToFront(label)
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
