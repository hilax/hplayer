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

    @State private var drag: CGFloat = 0
    @State private var axis: Axis?
    @State private var scrubbing = false
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

    private func pager(size: CGSize, insets: EdgeInsets) -> some View {
        ZStack {
            ForEach(visiblePositions, id: \.self) { position in
                if let player = model.player(at: position), let episode = model.episode(at: position) {
                    DramaFeedPage(
                        player: player,
                        detail: model.detail,
                        episode: episode,
                        total: model.count,
                        size: size,
                        insets: insets,
                        isActive: position == model.index,
                        scrubbing: $scrubbing,
                        onFullscreen: { setFullscreen(true) }
                    )
                    .offset(y: CGFloat(position - model.index) * size.height + drag)
                    .transition(.identity)
                    .accessibilityHidden(position != model.index)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        // 和单击、长按、进度条拖动同时识别：只认竖直方向的拖动
        .simultaneousGesture(pagingGesture(height: size.height))
        .accessibilityAction(named: "下一集") { go(to: model.index + 1) }
        .accessibilityAction(named: "上一集") { go(to: model.index - 1) }
    }

    private var visiblePositions: [Int] {
        [model.index - 1, model.index, model.index + 1].filter { $0 >= 0 && $0 < model.count }
    }

    private func pagingGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !scrubbing else { return }
                if axis == nil {
                    axis = abs(value.translation.height) > abs(value.translation.width) ? .vertical : .horizontal
                }
                guard axis == .vertical else { return }
                var offset = value.translation.height
                // 第一集再往下拉、最后一集再往上推：只拉动一点（橡皮筋），提示到头了
                let atStart = model.index == 0 && offset > 0
                let atEnd = model.index == model.count - 1 && offset < 0
                if atStart || atEnd { offset *= 0.25 }
                drag = offset
            }
            .onEnded { value in
                defer { axis = nil }
                guard axis == .vertical, !scrubbing else {
                    withAnimation(pageAnimation) { drag = 0 }
                    return
                }
                let moved = value.translation.height
                let predicted = value.predictedEndTranslation.height
                let threshold = height * 0.16
                var target = model.index
                if moved < -threshold || predicted < -height * 0.45 {
                    target += 1
                } else if moved > threshold || predicted > height * 0.45 {
                    target -= 1
                }
                if target >= model.count { hint("已经是最后一集了") }
                if target < 0 { hint("已经是第一集了") }
                go(to: target)
            }
    }

    private var pageAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.36, dampingFraction: 0.9)
    }

    private func go(to target: Int) {
        let valid = min(max(0, target), model.count - 1)
        if valid != model.index { Haptics.select() }
        withAnimation(pageAnimation) {
            if valid != model.index { model.show(valid) }
            drag = 0
        }
    }

    private func hint(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { edgeHint = text }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.easeOut(duration: 0.25)) { if edgeHint == text { edgeHint = nil } }
        }
    }

    // MARK: 固定在屏幕上的按钮（不随翻页移动）

    private func chrome(insets: EdgeInsets) -> some View {
        ZStack(alignment: .top) {
            HStack(spacing: 10) {
                Button { close() } label: {
                    Image(icon: .back)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("返回")
                .accessibilityIdentifier("drama.feed.close")
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.detail.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text("第 \(model.episode(at: model.index)?.number ?? model.index + 1) 集 · 共 \(model.count) 集")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textSecondaryOnArtwork)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 4)
                Spacer(minLength: 0)
            }
            .padding(.top, insets.top + 2)
            .padding(.horizontal, 6)

            VStack(spacing: 22) {
                Spacer()
                railButton(icon: .playlist, title: "选集",
                           identifier: "drama.feed.episodes") {
                    model.pauseCurrent()
                    showEpisodes = true
                }
                railButton(icon: .speed, title: speedLabel,
                           identifier: "drama.feed.speed") { cycleSpeed() }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 10)
            .padding(.bottom, insets.bottom + 150)

            if let edgeHint {
                Text(edgeHint)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(.black.opacity(0.6), in: Capsule())
                    .frame(maxHeight: .infinity)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
    }

    private func railButton(icon: AppIcon, title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon.name)
                    .font(.system(size: 24, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.45), radius: 4)
            .frame(width: 56, height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.88))
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
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
    @Binding var scrubbing: Bool
    let onFullscreen: () -> Void

    @State private var boosting = false
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
                .overlay(Color.black.opacity(0.45))
                .clipped()
                .opacity(player.state == .ready && player.videoSize != .zero ? 0 : 1)

            DramaVideoSurface(player: player.player, fill: player.isPortraitVideo)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)

            // 上下压暗，白字在亮画面上也看得清
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: insets.top + 90)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .frame(height: insets.bottom + 220)
            }
            .allowsHitTesting(false)

            statusLayer

            if !player.isPortraitVideo, player.state == .ready {
                fullscreenButton
            }

            info
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isActive else { return }
            Haptics.tap()
            player.togglePlay()
        }
        // 长按 2 倍速，松手恢复（抖音同款）
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4, maximumDistance: 12)
                .onEnded { _ in startBoost() }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onEnded { _ in stopBoost() }
        )
        .overlay(alignment: .top) {
            if boosting {
                HStack(spacing: 6) {
                    Image(systemName: AppIcon.speed.name)
                    Text("2× 快进中")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(.black.opacity(0.55), in: Capsule())
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
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Theme.rating)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Button("重新加载") { player.retry() }
                    .font(.system(size: 14, weight: .semibold))
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
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.35), radius: 10)
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
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(.white.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
        }
        .buttonStyle(.pressable(scale: 0.94))
        .offset(y: videoHeight / 2 + 34)
        .accessibilityIdentifier("drama.feed.fullscreen")
    }

    // MARK: 底部：剧名、简介、进度

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer()
            Text(detail.title)
                .font(.system(size: 16, weight: .bold))
            Text("第 \(episode.number) 集 · 共 \(total) 集" + (detail.isFinished ? " · 已完结" : ""))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textSecondaryOnArtwork)
            if !detail.summary.isEmpty {
                Text(detail.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondaryOnArtwork)
                    .lineLimit(expanded ? 6 : 2)
                    .onTapGesture { withAnimation(Motion.smooth) { expanded.toggle() } }
            }
            progressBar
                .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 3)
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
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
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

    private func startBoost() {
        guard isActive, player.isPlaying else { return }
        Haptics.tap()
        withAnimation(.easeOut(duration: 0.15)) { boosting = true }
        player.setRate(2)
    }

    private func stopBoost() {
        guard boosting else { return }
        withAnimation(.easeOut(duration: 0.15)) { boosting = false }
        player.setRate(1)
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
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("退出全屏")
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Spacer()
            }
            Spacer()
            HStack(spacing: 14) {
                Button { player.togglePlay(); scheduleHide() } label: {
                    Image(systemName: player.isPlaying ? AppIcon.pause.name : AppIcon.play.name)
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
                Text(DramaFeedPage.time(player.currentTime))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                Slider(value: Binding(
                    get: { player.duration > 0 ? player.currentTime / player.duration : 0 },
                    set: { player.seek(to: $0 * player.duration); scheduleHide() }
                ))
                .tint(.white)
                Text(DramaFeedPage.time(player.duration))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                Button(action: onExit) {
                    Image(systemName: AppIcon.exitFullscreen.name)
                        .font(.system(size: 18, weight: .semibold))
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
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: 90)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom).frame(height: 110)
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
                                .font(.system(size: 14, weight: current ? .bold : .medium).monospacedDigit())
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
