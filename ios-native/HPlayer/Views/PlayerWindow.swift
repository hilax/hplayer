import MediaPlayer
import SwiftUI
import UIKit

// MARK: - 独立播放器窗口

/// 播放器专用窗口。`allowedOrientations` 决定它能不能横屏：
/// 横屏播放时是 `.landscape`，切回竖屏小窗时是 `.portrait`。
final class PlayerWindow: UIWindow {
    var allowedOrientations: UIInterfaceOrientationMask = .landscape

    private var volumeHUDGuard: MPVolumeView?
    /// 调音量（滑动手势、音量键）时，系统只有在 App 里有一个「看得见」的 MPVolumeView 才不弹自带的音量条。
    /// 播放器窗口刚创建时 alpha 是 0（要等转好屏才淡入），那时登记的音量控件会被系统当成不可见，
    /// 结果音量条照样弹出来、盖在播放页自己的音量提示上面。
    /// 所以窗口真正可见之后（以及 App 回到前台后）再放一个新的；它几乎透明、不接收触摸，只是让系统知道「播放页自己管音量」。
    func installVolumeHUDGuard() {
        volumeHUDGuard?.removeFromSuperview()
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        addSubview(view)
        volumeHUDGuard = view
    }
}

final class PlayerHostingController: UIHostingController<AnyView> {
    /// 方向变化结束（含动画）后回调，用来在转好之后再淡入
    var onRotated: (() -> Void)?

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        (view.window as? PlayerWindow)?.allowedOrientations ?? .landscape
    }
    override var shouldAutorotate: Bool { true }

    /// 看视频时底部的横条（回桌面指示条）自动隐藏
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    /// 横屏时底边先交给播放器：贴着底边起手的横滑能直接快进快退，不会被「上滑回桌面」的系统手势先截走、
    /// 拖了没反应；要回桌面就在底边连续上滑两次（和系统视频播放器一样）。顶边不推迟，下拉控制中心照常。
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        view.bounds.width > view.bounds.height ? [.bottom] : []
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            self?.setNeedsUpdateOfHomeIndicatorAutoHidden()
            self?.onRotated?()
        }
    }
}

/// 横屏关闭时接手播放器窗口的全黑控制器。
/// 换上时仍按横屏（窗口不会被立刻改成竖屏），之后再改成只支持竖屏，让场景走正常的转屏流程——这样能拿到
/// 「转屏结束」的回调。改竖屏之前全局关掉了 UIView 动画，系统这次转屏的时长是 0，一下子就转完；
/// 页面照样要等这个回调才露出来（万一系统还是转了动画，也不会在转的时候露出来）。
/// 转屏时画面全黑、状态栏和底部横条都藏着，看不到任何东西在转；转好后和参考 App 一样，
/// 白字状态栏先在黑屏上淡出来，页面再在它下面从黑里淡出来，最后状态栏换成页面自己的样式。
final class PlayerExitController: UIViewController {
    /// 系统开始转屏，带上这次转屏的时长（关了动画时应该是 0），只用来记诊断
    var onWillRotate: ((TimeInterval) -> Void)?
    var onRotated: (() -> Void)?
    var orientations: UIInterfaceOrientationMask = .landscape
    /// 黑屏上是白字；页面淡完以后换成 `pageStatusBarStyle`
    var statusBarStyle: UIStatusBarStyle = .lightContent
    /// 页面自己的状态栏样式（跟随 App 外观：浅色是黑字、深色是白字）
    var pageStatusBarStyle: UIStatusBarStyle = .lightContent
    /// 转好竖屏后才设为 true：状态栏先在黑屏上淡出来
    var statusBarVisible = false
    /// 页面开始淡出来时才设为 true：底部横条和页面一起出现
    var homeIndicatorVisible = false

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { orientations }
    override var shouldAutorotate: Bool { true }
    override var preferredStatusBarStyle: UIStatusBarStyle { statusBarStyle }
    override var prefersStatusBarHidden: Bool { !statusBarVisible }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
    /// 黑屏时和横屏播放一样让底部横条自动隐藏，不会看到它从横屏的底边跳到竖屏的底边
    override var prefersHomeIndicatorAutoHidden: Bool { !homeIndicatorVisible }

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        self.view = view
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        onWillRotate?(coordinator.transitionDuration)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.onRotated?()
        }
    }
}

/// 打开 / 关闭播放器窗口。同一时间只有一个播放器。
@MainActor
final class PlayerWindowController {
    static let shared = PlayerWindowController()

    private init() {
        // 从后台回来后系统会重新判断哪些音量控件在屏幕上，窗口已经可见时重新放一个
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let window = self?.window, window.alpha > 0.5, !window.isHidden else { return }
                window.installVolumeHUDGuard()
            }
        }
    }

    private(set) var window: PlayerWindow?
    private var host: PlayerHostingController?
    private var onDismissed: (() -> Void)?
    private var revealed = false
    /// 打开时要不要横屏：要横屏的话，窗口真的转成横屏以后才淡入，避免先露出竖屏那一帧
    private var wantsLandscape = false
    private var revealTask: Task<Void, Never>?
    private var revealWaiters: [CheckedContinuation<Void, Never>] = []
    /// 播放期间暂时隐藏的主窗口：系统校验「支持的方向」时会把它也算进去，它只支持竖屏，横屏请求就被拒绝
    private var hiddenMain: UIWindow?
    /// 播放页已经开始关闭淡出：晚到的转屏重试、淡入都不再执行
    private var closing = false
    /// 横屏关闭的收尾：播放器窗口已经切成全黑，等场景在黑屏里转回竖屏，再放回主窗口、让黑屏淡掉
    private var exitingWindow: PlayerWindow?
    /// 兜底：没等到转屏结束的回调时，场景报竖屏后再等一整段转屏时长（0.5 秒）才收尾，最多等 1.1 秒
    private var exitWatch: Task<Void, Never>?
    /// 点关闭、画面切黑的那一刻；黑屏多久从这里算
    private var blackCutAt: Date?
    private var exitStartedAt = Date()
    /// 为了让系统瞬间转完屏，横屏关闭收尾期间全局关掉了 UIView 动画；淡出前（或被新的播放打断时）一定要恢复
    private var animationsPausedForExit = false
    /// 每次横屏关闭收尾加一：上一次收尾晚到的「恢复动画」不会把新一次收尾关掉的动画提前打开
    private var exitGeneration = 0
    /// 最近一次横屏关闭的时间线（从切黑算起），附在「复制播放诊断信息」里；下次打开播放器也保留，方便真机核对节奏
    private var closeLog: [String] = []
    /// 按参考 App 录屏逐帧量出来的节奏：切黑后约 0.06 秒白字状态栏用约 0.12 秒在黑屏上淡出来；
    /// 切黑后 0.17 秒页面开始淡出来，先慢后快再慢（ease-in-out）0.25 秒淡完，大约 0.42 秒整个关完
    static let exitBlackHold: TimeInterval = 0.17
    static let exitFadeDuration: TimeInterval = 0.25
    static let exitStatusBarFade: TimeInterval = 0.12
    /// 这一次弹出的标记。关闭只认自己弹出的那个窗口：别的播放入口复位状态时，不会把正在播的窗口误关掉。
    private var token: UUID?
    /// 每发起一轮转屏请求加一：旧一轮的重试看到编号变了就停下，不和新一轮（比如点了横竖屏按钮）打架。
    private var orientationRound = 0
    /// 最近一次打开播放器的转屏过程和主线程卡顿，附在「复制播放诊断信息」里，真机排查不用开调试文字。
    private var log: [String] = []
    private var presentedAt = Date()
    private var watchdog: Task<Void, Never>?

    var isPresented: Bool { window != nil }
    /// 播放器窗口还在转屏、尚未显示：可先在后台预热并暂停在首帧，等窗口淡入那一刻立刻起播
    var needsRevealHold: Bool { window != nil && !revealed && !closing }

    /// 播放器窗口本身固定深色（这样状态栏文字是白的、系统控件也是深色），
    /// 竖屏页面的信息区和面板要跟随的是 App 当前的外观，读主窗口实际生效的模式。
    var appColorScheme: ColorScheme {
        let scene = window?.windowScene ?? activeScene()
        let main = hiddenMain ?? mainWindow(in: scene)
        // 根控制器的外观比窗口更准：SwiftUI 的 preferredColorScheme 设在根控制器上
        let traits = main?.rootViewController?.traitCollection ?? main?.traitCollection
        return traits?.userInterfaceStyle == .light ? .light : .dark
    }

    /// 这个标记对应的窗口是不是还开着
    func isShowing(_ token: UUID) -> Bool { window != nil && self.token == token }

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

    /// 弹出播放器窗口，返回这次弹出的标记（关闭时要带上）。
    /// `onDismissed` 在窗口被调用方以外的原因关掉时调用（被新的播放顶替、没有可用的场景），让调用方把自己的状态复位。
    @discardableResult
    func present(_ root: AnyView, token requestedToken: UUID = UUID(), landscape: Bool,
                 onDismissed: @escaping () -> Void) -> UUID? {
        if window != nil {
            // 另一个入口要播放时，正在播的窗口让位：先关掉它、通知它的入口复位，再弹出新的。
            // 例如磁力页从 BT 播放改用 115 播放：关旧窗口和开新窗口发生在同一次刷新里，两边的回调谁先谁后不固定，
            // 以前新窗口先到时会被直接忽略，115 播放就再也打不开。
            let previous = self.onDismissed
            dismiss(replacing: true)
            previous?()
        }
        // 上一次横屏关闭还在收尾（黑屏里转竖屏中）：直接撤掉它，还藏着的主窗口交给这一次
        abandonExit()
        blackCutAt = nil
        pendingDebug = []
        log = []
        presentedAt = Date()
        guard let scene = activeScene() else {
            restoreMain()
            onDismissed()
            return nil
        }
        self.onDismissed = onDismissed
        revealed = false
        closing = false
        wantsLandscape = landscape
        debug("打开 横屏=\(landscape) 设备方向=\(UIDevice.current.orientation.rawValue) 场景方向=\(scene.interfaceOrientation.rawValue)")
        if landscape {
            // 主窗口只支持竖屏，它可见时系统会拒绝横屏请求：在播放器窗口出来之前就先藏好，
            // 不再等 80 毫秒以后才藏（那时第一次转屏请求很可能已经按「主窗口可见」被拒绝了）。
            hideMain(in: scene)
        } else {
            // 竖屏打开时主窗口要在下面露着
            restoreMain()
        }

        let player = PlayerWindow(windowScene: scene)
        player.allowedOrientations = landscape ? .landscape : .portrait
        player.overrideUserInterfaceStyle = .dark
        player.backgroundColor = .clear
        // 窗口层级必须比主窗口高，同时保持透明：竖屏关闭时淡出会露出下面的页面
        player.windowLevel = UIWindow.Level.normal + 1
        player.isOpaque = false

        let host = PlayerHostingController(rootView: root)
        host.view.backgroundColor = .clear
        host.onRotated = { [weak self] in self?.revealWhenReady() }
        player.rootViewController = host
        player.alpha = 0
        player.makeKeyAndVisible()

        self.window = player
        self.host = host
        self.token = requestedToken
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()

        if landscape {
            // 等窗口成为 key window、系统登记完它的支持方向，再请求转屏
            Task { @MainActor [weak self, weak player] in
                try? await Task.sleep(nanoseconds: 80_000_000)
                // 只对这一次弹出的窗口生效：期间关掉又打开了新的，就不再动它
                guard let self, let player, self.window === player, !self.closing else { return }
                self.requestOrientation(Self.preferredLandscape(), in: scene)
            }
        } else {
            reveal()
        }
        // 兜底：方向没变化（已经是横屏、模拟器不转、系统拒绝）时也要显示出来
        revealTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.reveal()   // 兜底：转屏一直没成功（被系统拒绝、主线程被占住）时，也不能一直黑着
        }
        startWatchdog()
        return requestedToken
    }

    /// 播放页里的「横屏 / 竖屏」按钮
    func setLandscape(_ landscape: Bool) {
        guard let window, !closing, let scene = window.windowScene else { return }
        // 竖屏打开的播放器要转横屏时，主窗口还可见；它只支持竖屏，会让系统拒绝横屏请求。
        if landscape { hideMain(in: scene) }
        window.allowedOrientations = landscape ? .landscape : .portrait
        requestOrientation(landscape ? Self.preferredLandscape() : .portrait, in: scene)
    }

    private func hideMain(in scene: UIWindowScene) {
        guard hiddenMain == nil, let main = mainWindow(in: scene) else { return }
        main.isHidden = true
        hiddenMain = main
        let presented = main.rootViewController?.presentedViewController
        debug("隐藏主窗 presented=\(presented.map { String(describing: type(of: $0)) } ?? "无") state=\(scene.activationState.rawValue)")
    }

    /// 把藏起来的主窗口放回来（只在场景是竖屏、或主窗口本来就该露着的时候调用）
    private func restoreMain() {
        guard let main = hiddenMain else { return }
        hiddenMain = nil
        main.isHidden = false
    }

    private static func isLandscape(_ window: UIWindow) -> Bool {
        (window.windowScene?.interfaceOrientation.isLandscape ?? false) || window.bounds.width > window.bounds.height
    }

    /// 播放页开始关闭时调用，返回 true 表示走了横屏的「切黑」关法（播放页不用再做淡出，直接关）：
    /// - 横屏：不能现在放回只支持竖屏的主窗口——它一可见，系统会先把整个首页按横屏重排一遍，再把场景强行转回竖屏，
    ///   主线程卡上一两秒，横屏画面被留在竖屏的上半截。也不在画面可见时转屏（会看到页面转一圈、四角露黑边）。
    ///   和参考 App 一样：画面立刻切成全黑，黑屏里瞬间转回竖屏，白字状态栏先在黑屏上淡出来，
    ///   切黑约 0.17 秒后页面用 0.25 秒从黑里淡出来（见 `dismiss`、`finishExit`）；
    /// - 竖屏：先把主窗口放回来，播放页整页淡出时露出的就是它。
    @discardableResult
    func willClose() -> Bool {
        guard let window, !closing else { return false }
        closing = true
        revealTask?.cancel()
        revealTask = nil
        orientationRound += 1
        resumeRevealWaiters()
        if hiddenMain != nil, Self.isLandscape(window) {
            window.backgroundColor = .black
            window.alpha = 1
            host?.view.isHidden = true
            blackCutAt = Date()
            startCloseLog("切黑")
            debug("关闭：横屏，切黑")
            return true
        }
        restoreMain()
        return false
    }

    /// 关闭这次弹出的窗口；标记对不上（窗口已经被新的播放顶替）就什么都不做。
    func dismiss(token: UUID) {
        guard self.token == token else { return }
        dismiss(replacing: false)
    }

    /// 关闭：卸下播放器窗口，放回主窗口，场景回到竖屏。
    /// 横屏、主窗口还藏着时不能直接放回（会和横屏场景冲突，见 `willClose`）：播放器窗口换成全黑的竖屏控制器，
    /// 黑屏里转回竖屏，转好以后放回主窗口，再让黑屏淡掉。
    /// `replacing`：被新的播放顶替，主窗口先不放回，交给新的那次弹出处理。
    private func dismiss(replacing: Bool = false) {
        guard let player = window else { return }
        let scene = player.windowScene
        let cutAt = blackCutAt
        blackCutAt = nil
        revealTask?.cancel()
        revealTask = nil
        resumeRevealWaiters()
        window = nil
        host = nil
        token = nil
        closing = false
        orientationRound += 1
        watchdog?.cancel()
        watchdog = nil
        onDismissed = nil
        debugLabel = nil
        debugLines = []
        pendingDebug = []
        UIDevice.current.endGeneratingDeviceOrientationNotifications()

        if replacing {
            removeWindow(player)
            return
        }
        if hiddenMain != nil, let scene, Self.isLandscape(player) {
            // 不是从播放页的关闭按钮来的（没走 willClose）：这一刻才切黑
            if cutAt == nil { startCloseLog("切黑（直接关闭）") }
            beginExit(player, in: scene, cutAt: cutAt ?? Date())
            return
        }
        removeWindow(player)
        restoreMain()
        let main = mainWindow(in: scene)
        main?.makeKey()
        main?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
    }

    private func removeWindow(_ player: PlayerWindow) {
        player.isHidden = true
        player.rootViewController = nil
    }

    /// 横屏关闭的收尾（主窗口还藏着）：窗口换成全黑的控制器，关掉动画后在黑屏里瞬间转回竖屏；
    /// 转屏回调来了才收尾（见 `finishExit`）。
    private func beginExit(_ player: PlayerWindow, in scene: UIWindowScene, cutAt: Date) {
        exitingWindow = player
        exitStartedAt = cutAt
        exitGeneration += 1
        player.isUserInteractionEnabled = false
        player.backgroundColor = .black
        player.alpha = 1
        let exit = PlayerExitController()
        exit.pageStatusBarStyle = appColorScheme == .light ? .darkContent : .lightContent
        exit.onWillRotate = { [weak self] duration in
            self?.closeNote(String(format: "系统开始转屏，时长 %.2f 秒", duration))
        }
        // 回调是在系统转屏的流程里调的：放到下一轮再收尾，不在系统转屏的中途放回主窗口
        exit.onRotated = { [weak self] in
            Task { @MainActor in self?.finishExit(by: "转屏回调") }
        }
        // 换上时仍按场景当前的方向（一般是横屏），窗口保持原样
        exit.orientations = scene.interfaceOrientation.isLandscape ? .landscape : .portrait
        UIView.performWithoutAnimation {
            player.rootViewController = exit
            player.layoutIfNeeded()
        }
        // 先关掉 UIView 动画，再改成只支持竖屏：系统这次转屏的时长变成 0，在全黑里一下子转完，
        // 不用再干等 0.3～0.4 秒的转屏动画，黑屏就能和参考 App 一样短。
        // 动画一直关到转屏回调来了、主窗口在黑屏下面放回来以后才恢复（a497e64 场景一报竖屏就恢复，系统还没真正转屏，页面跟着转了进来）。
        pauseAnimationsForExit()
        player.allowedOrientations = .portrait
        exit.orientations = .portrait
        exit.setNeedsUpdateOfSupportedInterfaceOrientations()
        closeNote("关动画，请求竖屏")
        debug("关闭：黑屏里转回竖屏")
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { [weak self] error in
            // 只记一笔：转没转过去由转屏回调和下面的兜底决定
            Task { @MainActor in self?.closeNote("竖屏请求被拒绝 \(error.localizedDescription)") }
        }
        exitWatch = Task { @MainActor [weak self, weak player, weak scene] in
            var portraitSince: Date?
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000)
                guard !Task.isCancelled, let self, let player, self.exitingWindow === player else { return }
                let now = Date()
                if portraitSince == nil, let scene, !scene.interfaceOrientation.isLandscape {
                    portraitSince = now
                    self.closeNote("场景报竖屏")
                }
                // 正常都会等到转屏回调；万一没有：场景报竖屏后再等一整段转屏时长（0.5 秒），总共最多等 1.1 秒
                let rotated = portraitSince.map { now.timeIntervalSince($0) >= 0.5 } ?? false
                if rotated || now.timeIntervalSince(self.exitStartedAt) >= 1.1 {
                    self.debug("关闭：没等到转屏回调，兜底收尾")
                    self.finishExit(by: "兜底")
                    return
                }
            }
        }
    }

    /// 转屏已经结束：趁动画还关着、在黑屏下面放回主窗口（它藏着的时候一直是竖屏，不用重排，也不会转）。
    /// 之后照参考 App 的节奏（见 `exitBlackHold`）：
    /// 1. 恢复动画，白字状态栏在黑屏上淡出来；
    /// 2. 从切黑算 0.17 秒（回调来得晚也至少等放回页面后 0.05 秒，让页面先画好），页面和底部横条在状态栏下面
    ///    先慢后快再慢地用 0.25 秒从黑里淡出来；
    /// 3. 淡完后状态栏换成页面自己的样式（浅色外观白字换黑字，交叉淡入），再撤掉黑窗口。
    private func finishExit(by reason: String) {
        guard let player = exitingWindow else { return }
        exitingWindow = nil
        exitWatch?.cancel()
        exitWatch = nil
        let scene = player.windowScene
        UIView.performWithoutAnimation {
            restoreMain()
            let main = mainWindow(in: scene)
            main?.makeKey()
            main?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            main?.layoutIfNeeded()
        }
        if let scene, scene.interfaceOrientation.isLandscape {
            // 系统没转过去（被拒绝）：补发一次竖屏请求
            closeNote("场景仍是横屏，补发竖屏请求")
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        }
        let exit = player.rootViewController as? PlayerExitController
        let fadeAt = max(Date().addingTimeInterval(0.05), exitStartedAt.addingTimeInterval(Self.exitBlackHold))
        let generation = exitGeneration
        closeNote(String(format: "转好（%@），放回页面", reason))
        Task { @MainActor [weak self] in
            // 再等一帧才恢复动画：放回主窗口这一轮的布局和系统转屏的收尾都在没有动画的状态下做完
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard let self else { return }
            // 期间又开始了新的一次横屏关闭：动画由那一次负责恢复
            if self.exitGeneration == generation { self.resumeAnimationsAfterExit() }
            self.closeNote("状态栏出现")
            exit?.statusBarVisible = true
            UIView.animate(withDuration: Self.exitStatusBarFade) {
                exit?.setNeedsStatusBarAppearanceUpdate()
            }
            let wait = fadeAt.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            self.closeNote("开始淡出")
            exit?.homeIndicatorVisible = true
            UIView.animate(withDuration: Self.exitFadeDuration, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                player.alpha = 0
                exit?.setNeedsUpdateOfHomeIndicatorAutoHidden()
            } completion: { _ in
                self.closeNote("淡完")
                // 深色外观页面本来就是白字状态栏，直接撤掉黑窗口
                guard let exit, exit.statusBarStyle != exit.pageStatusBarStyle else {
                    self.removeWindow(player)
                    return
                }
                exit.statusBarStyle = exit.pageStatusBarStyle
                UIView.animate(withDuration: 0.15) {
                    exit.setNeedsStatusBarAppearanceUpdate()
                } completion: { _ in
                    self.removeWindow(player)
                }
            }
        }
    }

    /// 新的播放要弹出时，上一次横屏关闭如果还在收尾，直接撤掉那个黑窗口；主窗口仍藏着，留给新的这次
    private func abandonExit() {
        // 关掉的动画先恢复：上一次收尾可能还在「转好了、等一帧再恢复动画」那一段
        resumeAnimationsAfterExit()
        guard let player = exitingWindow else { return }
        exitingWindow = nil
        exitWatch?.cancel()
        exitWatch = nil
        removeWindow(player)
    }

    private func pauseAnimationsForExit() {
        // 别处已经关着就不管：只恢复自己关掉的
        guard !animationsPausedForExit, UIView.areAnimationsEnabled else { return }
        UIView.setAnimationsEnabled(false)
        animationsPausedForExit = true
    }

    private func resumeAnimationsAfterExit() {
        guard animationsPausedForExit else { return }
        animationsPausedForExit = false
        UIView.setAnimationsEnabled(true)
    }

    private var closeLogStart = Date()

    private func startCloseLog(_ text: String) {
        closeLogStart = Date()
        closeLog = []
        closeNote(text)
    }

    private func closeNote(_ text: String) {
        closeLog.append(String(format: "%4.2fs ", Date().timeIntervalSince(closeLogStart)) + text)
        if closeLog.count > 20 { closeLog.removeFirst(closeLog.count - 20) }
    }

    // MARK: 内部

    /// 窗口已经是要的方向才显示；否则等转屏完成后再来
    private func revealWhenReady() {
        guard let window else { return }
        let isLandscape = window.bounds.width > window.bounds.height
        if !wantsLandscape || isLandscape { reveal() }
    }

    /// 播放页等转屏结束再开始加载视频：转屏期间主线程不被解码、建连接占住，转得更干净。
    /// 最多等到兜底时间；没有播放器窗口时立即返回。
    func waitUntilRevealed() async {
        guard window != nil, !revealed else { return }
        await withCheckedContinuation { revealWaiters.append($0) }
    }

    private func resumeRevealWaiters() {
        let waiters = revealWaiters
        revealWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func reveal() {
        guard !revealed, !closing, let window else { return }
        revealed = true
        revealTask?.cancel()
        resumeRevealWaiters()
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
            window.alpha = 1
        } completion: { [weak window] _ in
            // 窗口淡入完成、真正可见以后再登记音量控件，系统才不会弹自带的音量条
            window?.installVolumeHUDGuard()
        }
    }

    /// 请求系统把界面转到指定方向，开始新的一轮（旧一轮的重试随之停下）。
    private func requestOrientation(_ mask: UIInterfaceOrientationMask, in scene: UIWindowScene) {
        orientationRound += 1
        attemptOrientation(mask, in: scene, round: orientationRound, attempt: 0)
    }

    /// 真机上刚打开的头一两秒，系统常常拒绝转屏，过一会儿再请求就能转过去（以前只试 3 次就放弃，
    /// 播放页停在竖屏，要手动点横屏按钮）。现在头 3 次没转成先按当前方向显示出来，
    /// 但不放弃：接着每 0.8 秒再请求一次，直到系统接受，最多大约 6 秒。
    private static let maxOrientationAttempts = 9

    private func attemptOrientation(_ mask: UIInterfaceOrientationMask, in scene: UIWindowScene, round: Int, attempt: Int) {
        guard let target = window, round == orientationRound else { return }
        let wantLandscape = !mask.contains(.portrait)
        host?.setNeedsUpdateOfSupportedInterfaceOrientations()
        target.makeKey()
        if attempt == 0 {
            debug("windows=\(scene.windows.map { "\(type(of: $0))\($0.isHidden ? "H" : "")\(Int($0.windowLevel.rawValue))\($0.isKeyWindow ? "K" : "")" }.joined(separator: ","))")
        }
        debug("请求\(Self.name(mask)) #\(attempt) 窗口=\(Self.name(target.allowedOrientations))")
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] error in
            Task { @MainActor in self?.debug("系统拒绝 #\(attempt)：\(error.localizedDescription)") }
        }
        let delay: UInt64 = attempt < 2 ? 450_000_000 : 800_000_000
        Task { @MainActor [weak self, weak target] in
            try? await Task.sleep(nanoseconds: delay)
            // 期间窗口被关掉、换成了新的，或者又发起了新的一轮，就不再管这一轮
            guard let self, let target, self.window === target, round == self.orientationRound else { return }
            let landscape = scene.interfaceOrientation.isLandscape
            self.debug("结果 #\(attempt) scene=\(scene.interfaceOrientation.rawValue) 窗口=\(Int(target.bounds.width))×\(Int(target.bounds.height))")
            if landscape == wantLandscape { self.revealWhenReady(); return }
            if attempt == 2 {
                // 先按当前方向显示，不让用户一直对着黑屏；后面转过去时画面会跟着转
                self.debug("头 3 次没转成，先显示，继续重试")
                self.reveal()
            }
            if attempt + 1 < Self.maxOrientationAttempts {
                self.attemptOrientation(mask, in: scene, round: round, attempt: attempt + 1)
            } else {
                self.debug("转屏失败，保持当前方向")
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

    /// 验证通过，不再在播放页上显示调试文字；排查问题时改成 true
    private static let showsDebugLabel = false
    private var debugLabel: UILabel?
    private var debugLines: [String] = []
    private var pendingDebug: [String] = []

    /// 系统问「这个窗口支持哪些方向」时也记一笔（AppDelegate 调用），看系统到底传的是哪个窗口
    func logOrientationQuery(window: UIWindow?, answer: UIInterfaceOrientationMask) {
        let kind: String
        if window == nil { kind = "nil" } else if window is PlayerWindow { kind = "播放器窗" } else { kind = "主窗" }
        debug("询问 \(kind) → \(Self.name(answer))")
    }

    /// 附在「复制播放诊断信息」后面的播放器窗口记录
    var diagnostics: String {
        var parts: [String] = []
        if !log.isEmpty { parts.append("[播放器窗口]\n" + log.joined(separator: "\n")) }
        if !closeLog.isEmpty { parts.append("[上次横屏关闭]\n" + closeLog.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    /// 打开后 15 秒内每 0.1 秒看一眼主线程：被占住超过 0.25 秒就记一笔，排查「打开就卡住」用
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task.detached(priority: .utility) { [weak self] in
            let end = Date().addingTimeInterval(15)
            while !Task.isCancelled, Date() < end {
                try? await Task.sleep(nanoseconds: 100_000_000)
                let sent = Date()
                await MainActor.run { }
                let blocked = Date().timeIntervalSince(sent)
                if blocked > 0.25 {
                    await self?.debug("主线程卡了 \(Int(blocked * 1000)) 毫秒")
                }
            }
        }
    }

    /// 播放页把加载进度（拿到播放地址等）记进同一份诊断，方便和转屏时间对照
    func note(_ text: String) {
        guard window != nil else { return }
        debug(text)
    }

    private func debug(_ text: String) {
        let line = String(format: "%5.2fs ", Date().timeIntervalSince(presentedAt)) + text
        // 系统反复询问支持方向时同一句会连着出现很多次，只记一次
        if log.last.map({ $0.dropFirst(7) == line.dropFirst(7) }) != true {
            log.append(line)
            if log.count > 60 { log.removeFirst(log.count - 60) }
        }
        pendingDebug.append(text)
        if pendingDebug.count > 8 { pendingDebug.removeFirst() }
        guard Self.showsDebugLabel, let window else { return }
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
    /// nil = 按全局默认（直接横屏）
    var landscape: Bool? = nil
    let root: () -> Root
    /// 这个入口弹出的窗口的标记；关闭时只关自己弹出的那个
    @State private var token: UUID?

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { show in
                if show {
                    present()
                } else if let token {
                    PlayerWindowController.shared.dismiss(token: token)
                    self.token = nil
                }
            }
            .onAppear { if isPresented { present() } }
    }

    private func present() {
        // 页面重新出现时自己的窗口还开着，不要重新弹一个（会把正在播的视频从头再开）
        if let token, PlayerWindowController.shared.isShowing(token) { return }
        let binding = $isPresented
        let presentationToken = UUID()
        let view = root()
            // 播放窗口是独立窗口：全局 HUD 提示在播放时落到画面顶部（深色）
            .hudHost(.player)
            .environmentObject(appState)
            .environment(\.dismissPlayerWindow, {
                // 先复位绑定状态再直接关闭独立窗口：不依赖宿主页面（主窗口藏着、在横向分页的屏外）及时收到 onChange，
                // 主窗口放回来时 onAppear 也不会再把播放器弹出来。
                binding.wrappedValue = false
                PlayerWindowController.shared.dismiss(token: presentationToken)
            })
        token = PlayerWindowController.shared.present(
            AnyView(view),
            token: presentationToken,
            landscape: landscape ?? PlayerWindowController.startsInLandscape,
            onDismissed: { binding.wrappedValue = false }
        )
    }
}

extension View {
    /// 代替 `fullScreenCover(isPresented:)`：把播放器放进独立窗口里横屏播放
    func playerWindow<Root: View>(isPresented: Binding<Bool>, landscape: Bool? = nil,
                                  @ViewBuilder content: @escaping () -> Root) -> some View {
        modifier(PlayerWindowModifier(isPresented: isPresented, landscape: landscape, root: content))
    }

    /// 代替 `fullScreenCover(item:)`
    func playerWindow<Item: Identifiable, Root: View>(item: Binding<Item?>, landscape: Bool? = nil,
                                                      @ViewBuilder content: @escaping (Item) -> Root) -> some View {
        playerWindow(
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            ),
            landscape: landscape,
            content: {
                if let value = item.wrappedValue { content(value) }
            }
        )
    }
}
