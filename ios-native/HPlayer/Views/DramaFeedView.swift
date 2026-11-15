import AVFoundation
import SwiftUI

/// 从详情页打开竖屏播放器时带的参数
struct DramaFeedStart: Identifiable {
    let id = UUID()
    let detail: DramaDetail
    let index: Int
}

// MARK: - 竖屏短剧播放器（上滑下一集）

/// 类似抖音 / Instagram Reels 的竖屏连播：上滑下一集、下滑上一集，单击暂停，长按 2 倍速。
/// 竖屏视频等比铺满；横屏视频居中完整显示，下面有「全屏观看」，在同一个播放器里转成横屏，不重新加载。
struct DramaFeedView: View {
    @StateObject private var model: DramaFeedModel
    @Environment(\.dismissPlayerWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var scrubbing = false
    /// 长按 2 倍速中（长按由滚动视图上的系统长按识别：按住期间不会翻页，松手一定能收到）
    @State private var boosting = false
    @State private var showEpisodes = false
    @State private var edgeHint: String?

    static let speeds: [Float] = [1, 1.25, 1.5, 2]

    init(detail: DramaDetail, startIndex: Int) {
        _model = StateObject(wrappedValue: DramaFeedModel(detail: detail, startIndex: startIndex))
    }

    var body: some View {
        GeometryReader { outer in
            let insets = outer.safeAreaInsets
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    Color.black
                    if size.width > size.height, let player = model.current {
                        DramaLandscapeView(player: player, title: title(model.index),
                                           onExit: { setFullscreen(false) })
                    } else {
                        pager(size: size, insets: insets)
                        chrome(insets: insets)
                    }
                }
            }
            .ignoresSafeArea()
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: scenePhase) { phase in
            if phase == .background { model.pauseCurrent() }
        }
        .sheet(isPresented: $showEpisodes) {
            DramaFeedEpisodeSheet(model: model) { position in
                showEpisodes = false
                model.show(position)
            }
        }
    }

    private func title(_ position: Int) -> String {
        "\(model.detail.title) 第\(model.episode(at: position)?.number ?? position + 1)集"
    }

    // MARK: 翻页

    /// 原生分页滚动（UIScrollView），和抖音一样：跟手、按甩动速度翻页、翻页途中能接住再甩、首尾系统回弹。
    /// 整页（画面、选集 / 倍速、剧名、进度条）一起移动；只建当前集和前后各一集。
    private func pager(size: CGSize, insets: EdgeInsets) -> some View {
        DramaFeedPager(
            count: model.count,
            index: model.index,
            scrollEnabled: !scrubbing,
            page: { position, fade in
                guard let player = model.player(at: position), let episode = model.episode(at: position) else { return nil }
                return AnyView(
                    DramaFeedPage(
                        player: player,
                        detail: model.detail,
                        episode: episode,
                        total: model.count,
                        size: size,
                        insets: insets,
                        isActive: position == model.index,
                        fade: fade,
                        speedLabel: speedLabel,
                        boosting: boosting && position == model.index,
                        scrubbing: $scrubbing,
                        onEpisodes: {
                            model.pauseCurrent()
                            showEpisodes = true
                        },
                        onSpeed: cycleSpeed,
                        onFullscreen: { setFullscreen(true) }
                    )
                    .accessibilityHidden(position != model.index)
                    .accessibilityAction(named: "下一集") { go(to: model.index + 1) }
                    .accessibilityAction(named: "上一集") { go(to: model.index - 1) }
                    .ignoresSafeArea()
                )
            },
            onLand: { position in
                guard position != model.index else { return }
                model.show(position)
            },
            onEdge: { atEnd in hint(atEnd ? "已经是最后一集了" : "已经是第一集了") },
            onHold: setBoost
        )
        .frame(width: size.width, height: size.height)
    }

    /// 长按 2 倍速，松手回到之前选的倍速（选了 1.5× 就回 1.5×）
    private func setBoost(_ on: Bool) {
        guard let player = model.current else { return }
        if on {
            guard !boosting, player.isPlaying else { return }
            Haptics.tap()
            withAnimation(.easeOut(duration: 0.15)) { boosting = true }
            player.setRate(2)
        } else {
            guard boosting else { return }
            withAnimation(.easeOut(duration: 0.15)) { boosting = false }
            player.setRate(model.speed)
        }
    }

    /// 页上文字和按钮的透明度：在屏幕正中是 1，移开半屏左右淡到 0.25
    static func chromeOpacity(offset: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return 1 }
        let distance = min(abs(offset) / height, 1)
        return Double(1 - min(distance * 1.5, 0.75))
    }

    /// 代码触发的翻页（播完自动下一集、读屏的上一集 / 下一集）：改当前集，滚动视图自己滑过去。
    /// 翻页不震动：连续刷的时候每页一震会很吵。
    private func go(to target: Int) {
        if target >= model.count { hint("已经是最后一集了"); return }
        if target < 0 { hint("已经是第一集了"); return }
        if target != model.index { model.show(target) }
    }

    private func hint(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { edgeHint = text }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.easeOut(duration: 0.25)) { if edgeHint == text { edgeHint = nil } }
        }
    }

    // MARK: 固定在屏幕上的部分（不随翻页移动）：返回、剧名、到头提示
    // 选集和倍速属于每一集的页面，在 DramaFeedPage 里，跟着翻页一起走。

    private func chrome(insets: EdgeInsets) -> some View {
        ZStack(alignment: .top) {
            HStack(spacing: 10) {
                Button { close() } label: {
                    Image(icon: .back)
                        .font(.scaled(18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("返回")
                .accessibilityIdentifier("drama.feed.close")
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.detail.title)
                        .font(.scaled(15, weight: .semibold))
                        .lineLimit(1)
                    Text("第 \(model.episode(at: model.index)?.number ?? model.index + 1) 集 · 共 \(model.count) 集")
                        .font(.scaled(11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textSecondaryOnArtwork)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(Theme.Opacity.medium), radius: 4)
                Spacer(minLength: 0)
            }
            .padding(.top, insets.top + 2)
            .padding(.horizontal, 6)

            if let edgeHint {
                Text(edgeHint)
                    .font(.scaled(13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(.black.opacity(Theme.Opacity.strong), in: Capsule())
                    .frame(maxHeight: .infinity)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        // 撑满整屏、内容靠上：返回键和剧名固定在顶部
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var speedLabel: String {
        model.speed == 1 ? "倍速" : "\(Self.format(model.speed))×"
    }

    static func format(_ speed: Float) -> String {
        speed == speed.rounded() ? String(format: "%.0f", speed) : String(format: "%g", speed)
    }

    private func cycleSpeed() {
        Haptics.select()
        let index = Self.speeds.firstIndex(of: model.speed) ?? 0
        model.setSpeed(Self.speeds[(index + 1) % Self.speeds.count])
    }

    // MARK: 生命周期

    private func start() {
        PlayerAudioSession.activate()
        UIApplication.shared.isIdleTimerDisabled = true
        model.onAdvance = { next in go(to: next) }
        model.show(model.index)
    }

    private func stop() {
        model.tearDownAll()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func close() {
        model.pauseCurrent()
        dismissWindow?()
    }

    private func setFullscreen(_ on: Bool) {
        Haptics.tap()
        PlayerWindowController.shared.setLandscape(on)
    }
}

// MARK: - 一页（一集）

private struct DramaFeedPage: View {
    @ObservedObject var player: DramaEpisodePlayer
    let detail: DramaDetail
    let episode: DramaEpisode
    let total: Int
    let size: CGSize
    let insets: EdgeInsets
    let isActive: Bool
    /// 翻页途中页上文字和按钮的透明度（画面本身不变淡），由滚动视图逐帧更新。
    /// 页面本身不观察它，只有 DramaFadeLayer 观察，滚动时只重画那一层。
    let fade: DramaPageFade
    let speedLabel: String
    /// 这一页正在长按 2 倍速（状态在 DramaFeedView）
    let boosting: Bool
    @Binding var scrubbing: Bool
    let onEpisodes: () -> Void
    let onSpeed: () -> Void
    let onFullscreen: () -> Void

    @State private var scrubValue: Double?
    @State private var expanded = false

    /// 横屏视频在竖屏里完整显示时画面的高度
    private var videoHeight: CGFloat {
        guard player.videoSize.width > 0 else { return size.width * 9 / 16 }
        return min(size.height, size.width * player.videoSize.height / player.videoSize.width)
    }

    var body: some View {
        ZStack {
            // 封面垫底：地址还没取到、画面还没出来时不是一片黑
            DramaCover(urlString: detail.cover, title: detail.title)
                .frame(width: size.width, height: size.height)
                .blur(radius: 24)
                .overlay(Color.black.opacity(Theme.Opacity.medium))
                .clipped()
                .opacity(player.state == .ready && player.videoSize != .zero ? 0 : 1)

            DramaVideoSurface(player: player.player, fill: player.isPortraitVideo)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)

            // 上下压暗，白字在亮画面上也看得清
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(Theme.Opacity.medium), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: insets.top + 90)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(Theme.Opacity.strong)], startPoint: .top, endPoint: .bottom)
                    .frame(height: insets.bottom + 220)
            }
            .allowsHitTesting(false)

            statusLayer

            DramaFadeLayer(fade: fade) {
                if !player.isPortraitVideo, player.state == .ready {
                    fullscreenButton
                }
                info
                rail
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isActive else { return }
            Haptics.tap()
            player.togglePlay()
        }
        // 长按 2 倍速的识别在 DramaPagerController（系统长按手势，和翻页互斥）
        .overlay(alignment: .top) {
            if boosting {
                HStack(spacing: 6) {
                    Image(systemName: AppIcon.speed.name)
                    Text("2× 快进中")
                }
                .font(.scaled(13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(.black.opacity(Theme.Opacity.strong), in: Capsule())
                .padding(.top, insets.top + 56)
                .transition(.opacity)
            }
        }
    }

    // MARK: 状态（加载、失败、暂停）

    @ViewBuilder private var statusLayer: some View {
        switch player.state {
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: AppIcon.alert.name)
                    .font(.scaled(28, weight: .semibold))
                    .foregroundStyle(Theme.rating)
                Text(message)
                    .font(.scaled(14))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Button("重新加载") { player.retry() }
                    .font(.scaled(14, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22)
                    .frame(height: 40)
                    .background(.white, in: Capsule())
            }
            .padding(.horizontal, 40)
        case .idle, .loading:
            ProgressView().tint(.white).controlSize(.large)
        case .ready:
            if player.isBuffering && isActive {
                ProgressView().tint(.white).controlSize(.large)
            } else if !player.isPlaying && isActive && !scrubbing && !boosting {
                Image(systemName: AppIcon.play.name)
                    .font(.scaled(54, weight: .semibold))
                    .foregroundStyle(.white.opacity(Theme.Opacity.solid))
                    .shadow(color: .black.opacity(Theme.Opacity.medium), radius: 10)
                    .allowsHitTesting(false)
                    .transition(.scale(scale: 1.3).combined(with: .opacity))
            }
        }
    }

    /// 横屏视频画面下方：「全屏观看」
    private var fullscreenButton: some View {
        Button(action: onFullscreen) {
            HStack(spacing: 6) {
                Image(systemName: AppIcon.fullscreen.name)
                Text("全屏观看")
            }
            .font(.scaled(13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(.white.opacity(Theme.Opacity.faint), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(Theme.Opacity.soft), lineWidth: 0.5))
        }
        .buttonStyle(.pressable(scale: 0.94))
        .offset(y: videoHeight / 2 + 34)
        .accessibilityIdentifier("drama.feed.fullscreen")
    }

    // MARK: 右侧：选集、倍速（属于这一页，翻页时一起移动）

    private var rail: some View {
        VStack(spacing: 22) {
            Spacer()
            railButton(icon: .playlist, title: "选集",
                       identifier: "drama.feed.episodes", action: onEpisodes)
            railButton(icon: .speed, title: speedLabel,
                       identifier: "drama.feed.speed", action: onSpeed)
        }
        .padding(.trailing, 10)
        .padding(.bottom, insets.bottom + 150)
        .frame(width: size.width, height: size.height, alignment: .bottomTrailing)
    }

    private func railButton(icon: AppIcon, title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon.name)
                    .font(.scaled(24, weight: .semibold))
                Text(title)
                    .font(.scaled(11, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(Theme.Opacity.medium), radius: 4)
            .frame(width: 56, height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.88))
        // 只有正中这一页的按钮能点，翻页途中露出来的半页不响应。
        // 不用 .disabled：按压样式会把不可用按钮压暗，翻到位时按钮会突然变亮。
        .allowsHitTesting(isActive)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    // MARK: 底部：剧名、简介、进度

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer()
            Text(detail.title)
                .font(.scaled(16, weight: .bold))
            Text("第 \(episode.number) 集 · 共 \(total) 集" + (detail.isFinished ? " · 已完结" : ""))
                .font(.scaled(13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textSecondaryOnArtwork)
            if !detail.summary.isEmpty {
                Text(detail.summary)
                    .font(.scaled(13))
                    .foregroundStyle(Theme.textSecondaryOnArtwork)
                    .lineLimit(expanded ? 6 : 2)
                    .onTapGesture { withAnimation(Motion.smooth) { expanded.toggle() } }
            }
            progressBar
                .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(Theme.Opacity.medium), radius: 3)
        .padding(.leading, 16)
        .padding(.trailing, 84)
        .padding(.bottom, max(insets.bottom, 12) + 6)
        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
    }

    private var progressBar: some View {
        let shown = scrubValue ?? player.currentTime
        let fraction = player.duration > 0 ? min(max(shown / player.duration, 0), 1) : 0
        let active = scrubValue != nil
        return VStack(alignment: .leading, spacing: 6) {
            if active {
                Text("\(Self.time(shown)) / \(Self.time(player.duration))")
                    .font(.scaled(15, weight: .bold).monospacedDigit())
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(Theme.Opacity.soft))
                    Capsule().fill(.white).frame(width: proxy.size.width * fraction)
                }
                .frame(height: active ? 6 : 2.5)
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard player.duration > 0 else { return }
                            if scrubValue == nil { scrubbing = true; Haptics.select() }
                            let x = min(max(value.location.x / max(proxy.size.width, 1), 0), 1)
                            withAnimation(.easeOut(duration: 0.12)) { scrubValue = x * player.duration }
                        }
                        .onEnded { _ in
                            if let target = scrubValue { player.seek(to: target) }
                            withAnimation(.easeOut(duration: 0.2)) { scrubValue = nil }
                            scrubbing = false
                        }
                )
            }
            .frame(height: 24)
        }
        .padding(.trailing, -68)
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(Self.time(player.currentTime))，共 \(Self.time(player.duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.seek(to: player.currentTime + 10)
            case .decrement: player.seek(to: player.currentTime - 10)
            @unknown default: break
            }
        }
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - 原生分页滚动

/// 一页上文字和按钮的透明度。滚动时逐帧改它，只有套了 `.opacity(fade.opacity)` 的那一层重画，
/// 视频画面和封面不跟着重算。
@MainActor
final class DramaPageFade: ObservableObject {
    @Published var opacity: Double = 1
}

/// 只负责按 DramaPageFade 调透明度；里面的内容由外层页面建好传进来，透明度变化时不重算
private struct DramaFadeLayer<Content: View>: View {
    @ObservedObject var fade: DramaPageFade
    let content: Content

    init(fade: DramaPageFade, @ViewBuilder content: () -> Content) {
        self.fade = fade
        self.content = content()
    }

    var body: some View {
        ZStack { content }.opacity(fade.opacity)
    }
}

/// 竖屏短剧的翻页容器：系统 UIScrollView 分页。
/// - 只给当前集和前后各一集建页面（每页一个 UIHostingController，放在它那一集的绝对位置上）。
/// - 松手时按系统预测的落点决定翻到哪一集，马上通知 `onLand`，下一集在减速收尾时就开始播放。
/// - 首尾用系统回弹；拉过头一点时 `onEdge` 提示「已经是第一 / 最后一集」。
/// - 当前集被外部改了（自动下一集、选集面板、读屏）时，相邻的集滑过去，跳得远就直接定位。
struct DramaFeedPager: UIViewControllerRepresentable {
    let count: Int
    let index: Int
    let scrollEnabled: Bool
    let page: @MainActor (Int, DramaPageFade) -> AnyView?
    let onLand: @MainActor (Int) -> Void
    let onEdge: @MainActor (Bool) -> Void
    /// 长按开始（true）/ 松手或被取消（false）
    var onHold: @MainActor (Bool) -> Void = { _ in }

    func makeUIViewController(context: Context) -> DramaPagerController {
        let controller = DramaPagerController()
        controller.currentIndex = index
        return controller
    }

    func updateUIViewController(_ controller: DramaPagerController, context: Context) {
        controller.makePage = page
        controller.onLand = onLand
        controller.onEdge = onEdge
        controller.onHold = onHold
        controller.scrollView.isScrollEnabled = scrollEnabled
        controller.apply(count: count, index: index)
    }
}

@MainActor
final class DramaPagerController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let scrollView = UIScrollView()
    var currentIndex = 0
    var makePage: @MainActor (Int, DramaPageFade) -> AnyView? = { _, _ in nil }
    var onLand: @MainActor (Int) -> Void = { _ in }
    var onEdge: @MainActor (Bool) -> Void = { _ in }
    var onHold: @MainActor (Bool) -> Void = { _ in }

    private var count = 0
    private var hosts: [Int: UIHostingController<AnyView>] = [:]
    private var fades: [Int: DramaPageFade] = [:]
    private var laidOutSize: CGSize = .zero
    /// 这次拖动已经提示过到头了，同一次拖动不重复提示
    private var edgeHinted = false

    private var pageHeight: CGFloat { scrollView.bounds.height }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        scrollView.isPagingEnabled = true
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.scrollsToTop = false
        // 手指一放上去，页面里的点按、长按、进度条就能立刻收到；开始滑动时系统再把它们取消
        scrollView.delaysContentTouches = false
        scrollView.backgroundColor = .black
        scrollView.delegate = self
        view.addSubview(scrollView)

        // 长按 2 倍速：系统长按手势和滚动的拖动互斥——按住期间不会翻页，松手（或被打断）一定会回调
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        hold.minimumPressDuration = 0.4
        hold.allowableMovement = 12
        hold.delegate = self
        scrollView.addGestureRecognizer(hold)
    }

    @objc private func handleHold(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began: onHold(true)
        case .ended, .cancelled, .failed: onHold(false)
        default: break
        }
    }

    /// 拖进度条时、正在滑动或减速收尾时不触发长按
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UILongPressGestureRecognizer else { return true }
        return scrollView.isScrollEnabled && !scrollView.isDragging && !scrollView.isDecelerating
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.size != laidOutSize, view.bounds.height > 0 else { return }
        laidOutSize = view.bounds.size
        scrollView.frame = view.bounds
        scrollView.contentSize = CGSize(width: view.bounds.width, height: view.bounds.height * CGFloat(count))
        scrollView.contentOffset = CGPoint(x: 0, y: CGFloat(currentIndex) * pageHeight)
        layoutPages()
        updateFades()
    }

    /// SwiftUI 每次刷新都会调：同步集数、当前集，并重建 / 更新前后三页
    func apply(count: Int, index: Int) {
        self.count = count
        if pageHeight > 0 {
            scrollView.contentSize = CGSize(width: scrollView.bounds.width, height: pageHeight * CGFloat(count))
        }
        if index != currentIndex {
            let distance = abs(index - currentIndex)
            currentIndex = index
            // 用户正在拖或者正在减速：落点就是这一集（onLand 已经通知过），别打断系统的滚动
            if pageHeight > 0, !scrollView.isDragging, !scrollView.isDecelerating {
                let target = CGPoint(x: 0, y: CGFloat(index) * pageHeight)
                let animated = distance == 1 && !UIAccessibility.isReduceMotionEnabled && view.window != nil
                scrollView.setContentOffset(target, animated: animated)
            }
        }
        syncPages()
        updateFades()
    }

    // MARK: 页面

    private var window: ClosedRange<Int> {
        max(0, currentIndex - 1)...max(0, min(count - 1, currentIndex + 1))
    }

    private func syncPages() {
        let wanted = count > 0 ? Set(window) : []
        for (position, host) in hosts where !wanted.contains(position) {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            hosts[position] = nil
            fades[position] = nil
        }
        for position in wanted.sorted() {
            let fade = fades[position] ?? DramaPageFade()
            fades[position] = fade
            guard let content = makePage(position, fade) else { continue }
            if let host = hosts[position] {
                host.rootView = content
            } else {
                let host = UIHostingController(rootView: content)
                host.view.backgroundColor = .clear
                if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
                addChild(host)
                scrollView.addSubview(host.view)
                host.didMove(toParent: self)
                hosts[position] = host
            }
        }
        layoutPages()
    }

    private func layoutPages() {
        let size = scrollView.bounds.size
        guard size.height > 0 else { return }
        for (position, host) in hosts {
            host.view.frame = CGRect(x: 0, y: CGFloat(position) * size.height, width: size.width, height: size.height)
        }
    }

    /// 离开屏幕中间越远，页上的文字和按钮越淡；只在变化明显时才发布，减少重画
    private func updateFades() {
        let height = pageHeight
        guard height > 0 else { return }
        let top = scrollView.contentOffset.y
        for (position, fade) in fades {
            let value = DramaFeedView.chromeOpacity(offset: CGFloat(position) * height - top, height: height)
            if abs(fade.opacity - value) > 0.01 || (value == 1 && fade.opacity != 1) { fade.opacity = value }
        }
    }

    // MARK: 滚动

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateFades()
        guard scrollView.isDragging, !edgeHinted, pageHeight > 0 else { return }
        let overscroll = pageHeight * 0.06
        let maxOffset = max(0, scrollView.contentSize.height - pageHeight)
        if scrollView.contentOffset.y < -overscroll {
            edgeHinted = true
            onEdge(false)
        } else if scrollView.contentOffset.y > maxOffset + overscroll {
            edgeHinted = true
            onEdge(true)
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        edgeHinted = false
    }

    /// 松手：系统已经按甩动速度算好落在哪一页，立刻切过去，下一集在收尾的这一小段里就开始播
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard pageHeight > 0 else { return }
        land(on: Int((targetContentOffset.pointee.y / pageHeight).rounded()))
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settle() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle() }
    }

    /// 停稳后按实际位置再对一次（读屏的三指滚动不经过拖动回调）
    private func settle() {
        guard pageHeight > 0 else { return }
        land(on: Int((scrollView.contentOffset.y / pageHeight).rounded()))
        updateFades()
    }

    private func land(on position: Int) {
        let clamped = min(max(0, position), max(0, count - 1))
        guard clamped != currentIndex else { return }
        currentIndex = clamped
        onLand(clamped)
    }
}

// MARK: - 横屏全屏

private struct DramaLandscapeView: View {
    @ObservedObject var player: DramaEpisodePlayer
    let title: String
    let onExit: () -> Void
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            DramaVideoSurface(player: player.player, fill: false)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if player.isBuffering || player.state == .loading {
                ProgressView().tint(.white).controlSize(.large)
            }

            if controlsVisible {
                controls
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible.toggle() }
            scheduleHide()
        }
        .onAppear(perform: scheduleHide)
        .statusBarHidden(true)
    }

    private var controls: some View {
        VStack {
            HStack(spacing: 10) {
                Button(action: onExit) {
                    Image(icon: .back)
                        .font(.scaled(18, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("退出全屏")
                Text(title)
                    .font(.scaled(16, weight: .semibold))
                    .lineLimit(1)
                Spacer()
            }
            Spacer()
            HStack(spacing: 14) {
                Button { player.togglePlay(); scheduleHide() } label: {
                    Image(systemName: player.isPlaying ? AppIcon.pause.name : AppIcon.play.name)
                        .font(.scaled(22, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
                Text(DramaFeedPage.time(player.currentTime))
                    .font(.scaled(12, weight: .medium).monospacedDigit())
                Slider(value: Binding(
                    get: { player.duration > 0 ? player.currentTime / player.duration : 0 },
                    set: { player.seek(to: $0 * player.duration); scheduleHide() }
                ))
                .tint(.white)
                Text(DramaFeedPage.time(player.duration))
                    .font(.scaled(12, weight: .medium).monospacedDigit())
                Button(action: onExit) {
                    Image(systemName: AppIcon.exitFullscreen.name)
                        .font(.scaled(18, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("退出全屏")
                .accessibilityIdentifier("drama.feed.exitFullscreen")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background {
            VStack {
                LinearGradient(colors: [.black.opacity(Theme.Opacity.strong), .clear], startPoint: .top, endPoint: .bottom).frame(height: 90)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(Theme.Opacity.strong)], startPoint: .top, endPoint: .bottom).frame(height: 110)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, player.isPlaying else { return }
            withAnimation(.easeOut(duration: 0.3)) { controlsVisible = false }
        }
    }
}

// MARK: - 选集

private struct DramaFeedEpisodeSheet: View {
    @ObservedObject var model: DramaFeedModel
    @ObservedObject private var recents = RecentStore.shared
    let onSelect: (Int) -> Void

    private let columns = [GridItem(.adaptive(minimum: 56), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(model.detail.episodes.enumerated()), id: \.element.id) { position, episode in
                        let current = position == model.index
                        let ref = DramaEpisodeRef(videoId: model.detail.id, seriesName: model.detail.title, episode: episode.number)
                        let progress = recents.progress(for: .drama(ref))
                        Button { onSelect(position) } label: {
                            Text("\(episode.number)")
                                .font(.scaled(14, weight: current ? .bold : .medium).monospacedDigit())
                                .foregroundStyle(current ? Theme.onPrimary : Theme.textPrimary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(current ? Theme.primaryAction : Theme.surface,
                                            in: RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
                                .overlay(alignment: .bottom) {
                                    if let progress, progress > 0.02, !current {
                                        GlassProgressBar(value: progress)
                                            .padding(.horizontal, 8)
                                            .padding(.bottom, 4)
                                    }
                                }
                        }
                        .buttonStyle(.pressable(scale: 0.94))
                        .accessibilityLabel("第 \(episode.number) 集")
                    }
                }
                .padding(Theme.contentInset)
            }
            .background(Theme.pageBackground.ignoresSafeArea())
            .navigationTitle("选集 · 共 \(model.count) 集")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - 画面

/// AVPlayerLayer。竖屏视频等比铺满（裁掉一点边），横屏视频完整显示。
struct DramaVideoSurface: UIViewRepresentable {
    let player: AVPlayer
    let fill: Bool

    func makeUIView(context: Context) -> DramaPlayerLayerView {
        let view = DramaPlayerLayerView()
        view.backgroundColor = .clear
        view.playerLayer.player = player
        view.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        return view
    }

    func updateUIView(_ view: DramaPlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        let gravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
        guard view.playerLayer.videoGravity != gravity else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.playerLayer.videoGravity = gravity
        CATransaction.commit()
    }
}

final class DramaPlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    // swiftlint:disable:next force_cast
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
