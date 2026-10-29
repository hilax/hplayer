import SwiftUI
import UIKit

struct PlaybackListItem: Identifiable, Hashable {
    let id: String
    let title: String
    var subtitle: String = ""
}

struct PlaybackChoice: Identifiable, Hashable {
    let id: String
    let title: String
}

/// 手势调节时显示的提示内容
private struct PlaybackAdjustment {
    enum Kind: Equatable {
        case seek
        case brightness
        case volume
        case notice
    }

    let kind: Kind
    let title: String
    let valueText: String
    let progress: Double
    var detail = ""
    var targetTime: Double? = nil
}

/// 横竖屏共享的播放器控制层，视频画面由 VLC 绘制。
struct PlaybackControlsView: View {
    @ObservedObject var playback: VLCPlaybackController
    let title: String
    var loading = false
    var loadingText = "正在准备播放…"
    var error = ""
    var items: [PlaybackListItem] = []
    var selectedID = ""
    var qualities: [PlaybackChoice] = []
    var selectedQuality = ""
    /// 边下边播时的网络状态，例如「12 个节点 · 1.2 MB/s」
    var networkStatus = ""
    /// 拖动进度时取目标位置的画面做预览（需要能另开一路读取视频，磁力边下边播不开）
    var seekPreview = false
    var onSelect: (String) -> Void = { _ in }
    var onQuality: (String) -> Void = { _ in }
    var onRetry: () -> Void = { }
    var onClose: () -> Void

    @StateObject private var systemVolume = SystemVolumeController()
    @StateObject private var preview = SeekPreviewLoader()
    @State private var controlsVisible = true
    @State private var locked = false
    @State private var showList = false
    @State private var boosting = false
    @State private var dragging = false
    @State private var dragTime = 0.0
    /// 拖进度条开始时的播放位置，用来算「+ 00:20」
    @State private var scrubStart = 0.0
    @State private var hideTask: Task<Void, Never>?
    @State private var requestedLandscape = false
    @State private var initialLandscapeRequested = false
    @State private var rotateError = ""
    @State private var adjustment: PlaybackAdjustment?
    @State private var adjustmentStartTime = 0.0
    @State private var adjustmentStartBrightness = 0.0
    @State private var adjustmentStartVolume = 1.0
    @State private var adjustmentHideTask: Task<Void, Never>?
    @State private var panKind: PlaybackAdjustment.Kind?
    /// 一次拖动手势是否还在处理中；方向锁定之前 panKind 为空，不能靠它判断。
    @State private var panActive = false
    /// 方向锁定时手指已经走过的位移，后面的调节量从这里开始算，画面不会突然跳一下。
    @State private var panBase = CGPoint.zero
    @State private var lastAdjustment = ""
    @State private var originalBrightness: CGFloat?
    @State private var brightnessLevel: Double = 0.5
    @State private var brightnessAdjusted = false

    private static let speedOptions: [Float] = [0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            let insets = geometry.safeAreaInsets
            ZStack {
                Color.black
                VLCVideoSurface(playback: playback)
                    .allowsHitTesting(false)
                PlaybackGestureSurface(
                    status: gestureStatus,
                    onTap: toggleControls,
                    onDoubleTap: {
                        guard !locked else { revealControls(); return }
                        playback.toggle()
                        revealControls()
                    },
                    onBoost: setBoost,
                    onPan: handlePan
                )

                if controlsVisible && !locked {
                    VStack(spacing: 0) {
                        topBar(landscape: landscape)
                        Spacer(minLength: 0)
                        bottomBar(landscape: landscape)
                    }
                    .padding(.leading, max(insets.leading, landscape ? 28 : 16))
                    .padding(.trailing, max(insets.trailing, landscape ? 28 : 16))
                    .padding(.top, max(insets.top, 12))
                    .padding(.bottom, max(insets.bottom, landscape ? 10 : 14))
                    .background(alignment: .top) {
                        LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: insets.top + 110)
                            .allowsHitTesting(false)
                    }
                    .background(alignment: .bottom) {
                        LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                            .frame(height: insets.bottom + (landscape ? 150 : 190))
                            .allowsHitTesting(false)
                    }
                    .transition(.opacity)
                    .zIndex(2)
                } else if controlsVisible && locked {
                    HStack {
                        Button(action: unlock) {
                            roundIcon("lock.fill", diameter: 46)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("解锁")
                        .accessibilityIdentifier("playback.unlock")
                        Spacer()
                    }
                    .padding(.leading, max(insets.leading, 24))
                    .transition(.opacity)
                    .zIndex(3)
                }

                centerStatus
                    .zIndex(4)

                if boosting {
                    boostPill
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, insets.top + (controlsVisible && !locked ? 64 : 18))
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .zIndex(5)
                }

                hudLayer(insets: insets)
                    .zIndex(6)

                if showList && !locked {
                    playlistPanel(landscape: landscape, insets: insets)
                        .zIndex(7)
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .animation(.easeOut(duration: 0.18), value: boosting)
        }
        .background(SystemVolumeHost(controller: systemVolume).frame(width: 1, height: 1).allowsHitTesting(false))
        .background(DarkPresentationStyle().frame(width: 0, height: 0))
        .environment(\.colorScheme, .dark)
        .tint(.white)
        .statusBarHidden(true)
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
        .onAppear {
            originalBrightness = UIScreen.main.brightness
            brightnessLevel = UIScreen.main.brightness
            systemVolume.start()
            revealControls()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                enterLandscapeByDefault()
            }
        }
        .onDisappear {
            hideTask?.cancel()
            adjustmentHideTask?.cancel()
            playback.setBoost(false)
            systemVolume.stop()
            if let originalBrightness { UIScreen.main.brightness = originalBrightness }
            if requestedLandscape { OrientationSupport.restorePortrait() }
        }
        .onChange(of: systemVolume.externalChangeCount) { _ in
            showSystemVolumeChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            // 离开 App 时把亮度还给系统，回来后再恢复播放页的亮度
            if brightnessAdjusted, let originalBrightness { UIScreen.main.brightness = originalBrightness }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if brightnessAdjusted { UIScreen.main.brightness = CGFloat(brightnessLevel) }
        }
        .alert("无法切换屏幕方向", isPresented: Binding(get: { !rotateError.isEmpty }, set: { if !$0 { rotateError = "" } })) {
            Button("好", role: .cancel) { rotateError = "" }
        } message: { Text(rotateError) }
    }

    // MARK: 顶部

    private func topBar(landscape: Bool) -> some View {
        HStack(spacing: 12) {
            Button { onClose() } label: { roundIcon("xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭播放")

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                if !statusLine.isEmpty {
                    Text(statusLine)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button { toggleOrientation(landscape: landscape) } label: {
                roundIcon(landscape ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(landscape ? "竖屏" : "横屏")
            .accessibilityIdentifier("playback.orientation")

            Menu {
                if !qualities.isEmpty {
                    Section("画质") {
                        ForEach(qualities) { choice in
                            Button {
                                onQuality(choice.id); revealControls()
                            } label: {
                                if choice.title == selectedQuality {
                                    Label(choice.title, systemImage: "checkmark")
                                } else {
                                    Text(choice.title)
                                }
                            }
                        }
                    }
                }
                Section("播放速度") { speedButtons }
            } label: {
                roundIcon("ellipsis")
            }
            .accessibilityLabel("更多选项")
        }
    }

    private var statusLine: String {
        var parts: [String] = []
        if !selectedQuality.isEmpty { parts.append(selectedQuality) }
        if abs(playback.rate - 1) > 0.01 { parts.append("\(String(format: "%g", playback.rate))× 倍速") }
        if !networkStatus.isEmpty { parts.append(networkStatus) }
        return parts.joined(separator: "  ")
    }

    // MARK: 底部

    /// 进度条在上，两头是当前时间和总时长；下面一行：锁定在左，上一集、暂停、下一集在正中，播放列表在右。
    private func bottomBar(landscape: Bool) -> some View {
        VStack(spacing: landscape ? 2 : 10) {
            HStack(spacing: 12) {
                Text(timeText(dragging ? dragTime : playback.currentTime))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 44, alignment: .leading)
                    .accessibilityIdentifier("playback.elapsed")

                PlayerScrubber(
                    value: dragging ? dragTime : min(playback.currentTime, max(playback.duration, 1)),
                    upperBound: max(playback.duration, 1),
                    enabled: playback.seekable && playback.duration > 0,
                    onScrub: scrubbed,
                    onEditingChanged: { editing in
                        if editing {
                            dragging = true
                            scrubStart = playback.currentTime
                            hideTask?.cancel()
                            adjustmentHideTask?.cancel()
                            preview.reset()
                            scrubbed(dragTime)
                        } else if dragging {
                            dragging = false
                            playback.seek(to: dragTime)
                            hideAdjustmentSoon()
                        }
                    },
                    onCommit: { value in
                        playback.seek(to: value)
                        revealControls()
                    }
                )
                .frame(height: 32)

                Text(timeText(playback.duration))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(minWidth: 44, alignment: .trailing)
            }

            ZStack {
                HStack(spacing: 0) {
                    Button(action: lock) { controlIcon("lock.open", label: "锁定") }
                        .accessibilityIdentifier("playback.lock")
                    Spacer(minLength: 0)
                    Button { openList() } label: { controlIcon("list.bullet", label: "播放列表") }
                        .accessibilityIdentifier("playback.playlist")
                }

                // 快进快退靠左右拖动画面，这里只留上一集、暂停、下一集，暂停键固定在屏幕正中
                HStack(spacing: landscape ? 44 : 30) {
                    Button { move(-1) } label: { controlIcon("backward.end.fill", label: "上一个", size: 20) }
                        .disabled(previousID == nil)
                        .opacity(previousID == nil ? 0.35 : 1)
                    Button { playback.toggle(); revealControls() } label: {
                        controlIcon(playback.playing ? "pause.fill" : "play.fill", label: playback.playing ? "暂停" : "播放", size: 34, frame: 64)
                    }
                    .accessibilityIdentifier("playback.playPause")
                    .accessibilityValue(playback.playing ? "playing" : "paused")
                    Button { move(1) } label: { controlIcon("forward.end.fill", label: "下一个", size: 20) }
                        .disabled(nextID == nil)
                        .opacity(nextID == nil ? 0.35 : 1)
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// 拖进度条时，画面中间显示和左右滑动一样的跳转提示和预览
    private func scrubbed(_ value: Double) {
        dragTime = value
        guard dragging, playback.duration > 0 else { return }
        adjustment = seekAdjustment(target: value, from: scrubStart)
        requestPreview(value)
    }

    @ViewBuilder
    private var speedButtons: some View {
        ForEach(Self.speedOptions, id: \.self) { value in
            Button {
                playback.setRate(value); revealControls()
            } label: {
                if abs(playback.rate - value) < 0.01 {
                    Label("\(String(format: "%g", value))×", systemImage: "checkmark")
                } else {
                    Text("\(String(format: "%g", value))×")
                }
            }
        }
    }

    // MARK: 播放列表

    private func playlistPanel(landscape: Bool, insets: EdgeInsets) -> some View {
        HStack(spacing: 0) {
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture { closeList() }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("播放列表")
                        .font(.headline)
                    Text("\(items.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Button { closeList() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭播放列表")
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 10)

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            playlistRow(item, index: index)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 18)
                }
            }
            .padding(.top, insets.top)
            .padding(.trailing, insets.trailing)
            .padding(.bottom, insets.bottom)
            .frame(width: (landscape ? 340 : 290) + insets.trailing)
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial)
            .background(Color.black.opacity(0.45))
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private func playlistRow(_ item: PlaybackListItem, index: Int) -> some View {
        let current = item.id == selectedID
        return Button {
            closeList()
            onSelect(item.id)
            revealControls()
        } label: {
            HStack(spacing: 12) {
                Group {
                    if current {
                        Image(systemName: "waveform")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.accent)
                    } else {
                        Text("\(index + 1)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .frame(width: 26)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.subheadline.weight(current ? .semibold : .regular))
                        .foregroundStyle(current ? Theme.accent : Color.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 11)
            .background(current ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("playback.item.\(item.id)")
    }

    // MARK: 状态与提示

    /// 加载、缓冲和出错提示放在画面中间，控制栏隐藏时也能看到。
    @ViewBuilder
    private var centerStatus: some View {
        let message = !error.isEmpty ? error : playback.error
        if !message.isEmpty {
            errorCard(message)
                .transition(.opacity)
        } else if (loading || playback.buffering) && adjustment == nil {
            bufferingPill
                .transition(.opacity)
        }
    }

    private func errorCard(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color(uiColor: .systemYellow))
            Text(text)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button {
                onRetry(); revealControls()
            } label: {
                Text("重试")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: 320)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        }
    }

    /// 缓冲时画面中间一个转圈，下面是当前网速
    private var bufferingPill: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text(bufferingText)
                .font(.footnote.weight(.semibold).monospacedDigit())
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: 260)
        .shadow(color: .black.opacity(0.55), radius: 6, y: 1)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("playback.cacheStatus")
    }

    private var boostPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "forward.fill")
                .font(.system(size: 11, weight: .bold))
            Text("\(String(format: "%g", VLCPlaybackController.boostRate))× 快进中")
                .font(.footnote.weight(.semibold))
            if !speedLabel.isEmpty {
                Text(speedLabel)
                    .font(.footnote.weight(.medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(.black.opacity(0.55), in: Capsule())
        .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
        .accessibilityElement(children: .combine)
    }

    /// 亮度、音量提示在画面上方，只有小图标和百分比；拖动进度提示和预览画面在正中间。
    @ViewBuilder
    private func hudLayer(insets: EdgeInsets) -> some View {
        ZStack {
            if let adjustment {
                switch adjustment.kind {
                case .seek:
                    SeekHUD(
                        adjustment: adjustment,
                        showsPreview: seekPreview,
                        image: preview.image,
                        loading: preview.loading
                    )
                    .transition(.opacity)
                case .brightness, .volume:
                    LevelHUD(adjustment: adjustment)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, insets.top + (controlsVisible && !locked ? 64 : 18))
                        .transition(.opacity)
                case .notice:
                    NoticeHUD(text: adjustment.valueText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, insets.top + (controlsVisible && !locked ? 64 : 18))
                        .transition(.opacity)
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.16), value: adjustment?.kind)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("playback.adjustmentHUD")
    }

    private var bufferingText: String {
        guard playback.buffering else { return loadingText }
        return speedLabel.isEmpty ? cacheText : speedLabel
    }

    /// 磁力边下边播用它自己的节点和速度，其他视频用 VLC 每秒读到的字节数
    private var speedLabel: String {
        if !networkStatus.isEmpty { return networkStatus }
        guard playback.downloadSpeed > 0 else { return "" }
        return Self.speedText(playback.downloadSpeed)
    }

    private static func speedText(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576)
        }
        return String(format: "%.0f KB/s", max(bytesPerSecond / 1024, 1))
    }

    private var cacheText: String {
        playback.bufferProgress > 0
            ? "缓冲 \(Int((playback.bufferProgress * 100).rounded()))%"
            : "正在缓冲"
    }

    // MARK: 小部件

    private func roundIcon(_ name: String, diameter: CGFloat = 38) -> some View {
        Image(systemName: name)
            .font(.system(size: diameter * 0.38, weight: .semibold))
            .frame(width: diameter, height: diameter)
            .background(.ultraThinMaterial, in: Circle())
            .overlay { Circle().strokeBorder(.white.opacity(0.1), lineWidth: 0.5) }
            .frame(width: max(diameter, 44), height: max(diameter, 44))
            .contentShape(Circle())
    }

    private func controlIcon(_ name: String, label: String, size: CGFloat = 20, frame: CGFloat = 44) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .semibold))
            .frame(width: frame, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(label)
    }

    // MARK: 状态

    private var previousID: String? { adjacent(-1) }
    private var nextID: String? { adjacent(1) }
    private func adjacent(_ offset: Int) -> String? {
        guard let i = items.firstIndex(where: { $0.id == selectedID }), items.indices.contains(i + offset) else { return nil }
        return items[i + offset].id
    }
    private func move(_ offset: Int) { if let id = adjacent(offset) { onSelect(id); revealControls() } }
    private func lock() {
        locked = true
        showList = false
        revealControls()
    }
    private func unlock() {
        locked = false
        revealControls()
    }
    private func openList() {
        hideTask?.cancel()
        withAnimation(.easeOut(duration: 0.25)) { showList = true }
    }
    private func closeList() {
        withAnimation(.easeOut(duration: 0.22)) { showList = false }
        revealControls()
    }
    private func applyVolume(_ value: Double) {
        systemVolume.set(value)
        if !systemVolume.controlsSystemVolume { playback.setSoftwareVolume(value) }
        if value > 0 && playback.muted { playback.setMuted(false) }
    }
    private func timeText(_ value: Double) -> String {
        guard value.isFinite && value >= 0 else { return "00:00" }
        let seconds = Int(value)
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60) : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    private func revealControls() {
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }
        }
        hideTask?.cancel()
#if DEBUG
        if ProcessInfo.processInfo.environment["HPLAYER_UI_TEST_KEEP_CONTROLS_VISIBLE"] == "1" {
            return
        }
#endif
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled && !showList && !dragging && !boosting && adjustment == nil && !playback.buffering {
                withAnimation(.easeOut(duration: 0.25)) { controlsVisible = false }
            }
        }
    }
    private var gestureStatus: String {
        "\(lastAdjustment); brightness=\(String(format: "%.3f", brightnessLevel)); volume=\(String(format: "%.3f", systemVolume.level)); time=\(Double(playback.player.time.intValue) / 1000); rate=\(String(format: "%g", boosting ? VLCPlaybackController.boostRate : playback.rate))"
    }

    private func toggleControls() {
        if controlsVisible {
            hideTask?.cancel()
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false }
        } else {
            revealControls()
        }
    }

    private func setBoost(_ enabled: Bool) {
        if enabled {
            guard !locked, !showList, panKind == nil, playback.playing else { return }
            boosting = true
            lastAdjustment = "长按 \(String(format: "%g", VLCPlaybackController.boostRate))×"
            playback.setBoost(true)
            hideTask?.cancel()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else if boosting {
            boosting = false
            playback.setBoost(false)
            revealControls()
        }
    }

    // MARK: 手势

    /// 手指走出这么远（点）才锁定是横滑还是竖滑。
    /// 手势刚识别出来时只走了十个点左右，真人拇指横滑起手常带一点斜向，
    /// 此时就定方向很容易把横滑误判成竖滑，变成调亮度或音量而不是快进快退。
    private static let panLockDistance: CGFloat = 18

    private func handlePan(_ state: UIGestureRecognizer.State, origin: CGPoint, translation: CGPoint, size: CGSize) {
        if state == .cancelled || state == .failed {
            panActive = false
            panKind = nil
            adjustment = nil
            preview.reset()
            revealControls()
            return
        }
        guard !locked, !showList, size.width > 0, size.height > 0 else { return }
        if state == .began {
            setBoost(false)
            adjustmentHideTask?.cancel()
            hideTask?.cancel()
            adjustmentStartTime = playback.currentTime
            adjustmentStartBrightness = brightnessLevel
            adjustmentStartVolume = systemVolume.level
            panKind = nil
            panBase = .zero
            panActive = true
            preview.reset()
        }
        guard panActive else { return }

        if panKind == nil {
            let dx = abs(translation.x)
            let dy = abs(translation.y)
            guard max(dx, dy) >= Self.panLockDistance else {
                // 还没走够，先不定方向；这次拖动很短就结束了，什么也不做
                if state == .ended {
                    panActive = false
                    revealControls()
                }
                return
            }
            panBase = translation
            // 横向略占优势就算横滑：竖滑要调亮度和音量，起手更不容易带横向分量
            if dx > dy * 0.8 {
                guard playback.seekable, playback.duration > 0 else {
                    panActive = false
                    showNotice(playback.duration > 0 ? "视频还在加载，暂时不能拖动进度" : "这个视频不支持拖动进度")
                    return
                }
                panKind = .seek
            } else {
                panKind = origin.x < size.width / 2 ? .brightness : .volume
            }
        }
        guard let panKind else { return }
        adjustmentHideTask?.cancel()
        let moveX = translation.x - panBase.x
        let moveY = translation.y - panBase.y
        switch panKind {
        case .notice:
            break
        case .seek:
            let range = min(180, max(30, playback.duration / 5))
            let target = min(max(adjustmentStartTime + Double(moveX / size.width) * range, 0), max(0, playback.duration - 0.25))
            adjustment = seekAdjustment(target: target, from: adjustmentStartTime)
            requestPreview(target)
        case .brightness:
            let value = min(max(adjustmentStartBrightness - Double(moveY / size.height) * 1.2, 0.02), 1)
            UIScreen.main.brightness = CGFloat(value)
            brightnessLevel = value
            brightnessAdjusted = true
            adjustment = PlaybackAdjustment(kind: .brightness, title: "亮度", valueText: "\(Int((value * 100).rounded()))%", progress: value)
        case .volume:
            let value = min(max(adjustmentStartVolume - Double(moveY / size.height) * 1.2, 0), 1)
            applyVolume(value)
            adjustment = PlaybackAdjustment(kind: .volume, title: "音量", valueText: "\(Int((value * 100).rounded()))%", progress: value)
        }
        if let adjustment { lastAdjustment = "\(adjustment.title) \(adjustment.valueText)" }
        if state == .ended {
            if let target = adjustment?.targetTime { playback.seek(to: target) }
            self.panKind = nil
            panActive = false
            hideAdjustmentSoon()
        }
    }

    private func seekAdjustment(target: Double, from start: Double) -> PlaybackAdjustment {
        let delta = (target - start).rounded()
        return PlaybackAdjustment(
            kind: .seek,
            title: delta >= 0 ? "快进" : "快退",
            valueText: "\(delta >= 0 ? "+" : "-") \(timeText(abs(delta)))",
            progress: playback.duration > 0 ? target / playback.duration : 0,
            detail: "\(timeText(target)) / \(timeText(playback.duration))",
            targetTime: target
        )
    }

    private func requestPreview(_ target: Double) {
        guard seekPreview, playback.duration > 0 else { return }
        preview.request(fraction: target / playback.duration, from: playback)
    }

    /// 横滑用不了时给一句提示，不要什么反应都没有。
    private func showNotice(_ text: String) {
        adjustmentHideTask?.cancel()
        adjustment = PlaybackAdjustment(kind: .notice, title: "提示", valueText: text, progress: 0)
        lastAdjustment = "提示 \(text)"
        hideAdjustmentSoon()
    }

    /// 按音量键或在控制中心调节时，同样用小胶囊提示当前音量。
    private func showSystemVolumeChange() {
        guard panKind == nil else { return }
        let value = systemVolume.level
        if value > 0 && playback.muted { playback.setMuted(false) }
        adjustmentHideTask?.cancel()
        adjustment = PlaybackAdjustment(kind: .volume, title: "音量", valueText: "\(Int((value * 100).rounded()))%", progress: value)
        lastAdjustment = "音量 \(Int((value * 100).rounded()))%"
        hideAdjustmentSoon(revealing: false)
    }

    private func hideAdjustmentSoon(revealing: Bool = true) {
        adjustmentHideTask?.cancel()
        adjustmentHideTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            adjustment = nil
            preview.reset()
            if revealing { revealControls() }
        }
    }
    private func toggleOrientation(landscape: Bool) {
        requestedLandscape = !landscape
        requestOrientation(landscape ? .portrait : .landscape)
        revealControls()
    }
    private func enterLandscapeByDefault() {
        guard !initialLandscapeRequested else { return }
        initialLandscapeRequested = true
        requestedLandscape = true
        requestOrientation(.landscape)
    }
    private func requestOrientation(_ orientation: UIInterfaceOrientationMask) {
        OrientationSupport.request(orientation) { error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                rotateError = "当前页面暂时无法切换横竖屏，请退出播放器后重试。"
            }
        }
    }
}

// MARK: - 提示视图

/// 亮度、音量：只有一个小图标和百分比，不加底板，靠阴影在亮画面上也看得清
private struct LevelHUD: View {
    let adjustment: PlaybackAdjustment

    private var value: Double { min(max(adjustment.progress, 0), 1) }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text("\(Int((value * 100).rounded()))%")
                .font(.footnote.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
    }

    private var icon: String {
        switch adjustment.kind {
        case .brightness:
            return value < 0.35 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if value <= 0.001 { return "speaker.slash.fill" }
            if value < 0.34 { return "speaker.wave.1.fill" }
            if value < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .seek:
            return "goforward"
        case .notice:
            return "exclamationmark.circle"
        }
    }
}

/// 一句话提示：例如视频暂时不能拖动进度
private struct NoticeHUD: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(.black.opacity(0.6), in: Capsule())
        .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
    }
}

/// 拖动进度：目标时间 / 总时长、一条小进度、跳转了多少，下面是目标位置的画面
private struct SeekHUD: View {
    let adjustment: PlaybackAdjustment
    var showsPreview = false
    var image: UIImage?
    var loading = false

    var body: some View {
        VStack(spacing: 8) {
            Text(adjustment.detail)
                .font(.system(size: 22, weight: .bold).monospacedDigit())
            LevelBar(value: adjustment.progress)
                .frame(width: 150, height: 3)
            Text(adjustment.valueText)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
            if showsPreview {
                previewBox
                    .padding(.top, 6)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.55), radius: 6, y: 1)
    }

    private var previewBox: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ZStack {
            Color.black.opacity(0.55)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
            if image == nil || loading {
                ProgressView()
                    .tint(.white)
                    .opacity(image == nil ? 1 : 0.8)
            }
        }
        .frame(width: 224, height: 126)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white.opacity(0.9), lineWidth: 1.5) }
        .animation(.easeOut(duration: 0.12), value: image)
    }
}

private struct LevelBar: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule()
                    .fill(.white)
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
    }
}

// MARK: - 进度条

/// 圆头粗轨道：白色是已播放，半透明是剩下的；按住时轨道变粗、圆点放大，方便拖动。
private struct PlayerScrubber: UIViewRepresentable {
    var value: Double
    var upperBound: Double
    var enabled: Bool
    var onScrub: (Double) -> Void
    var onEditingChanged: (Bool) -> Void
    var onCommit: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ScrubberSlider {
        let slider = ScrubberSlider()
        slider.minimumValue = 0
        slider.maximumValue = Float(max(upperBound, 1))
        slider.value = Float(value)
        slider.isContinuous = true
        slider.setThumbImage(Self.thumbImage(diameter: 12), for: .normal)
        slider.setThumbImage(Self.thumbImage(diameter: 20), for: .highlighted)
        slider.accessibilityLabel = "播放进度"
        slider.accessibilityIdentifier = "playback.scrubber"
        slider.addTarget(context.coordinator, action: #selector(Coordinator.touchDown(_:)), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.touchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }

    func updateUIView(_ slider: ScrubberSlider, context: Context) {
        context.coordinator.parent = self
        let maximum = Float(max(upperBound, 1))
        if slider.maximumValue != maximum { slider.maximumValue = maximum }
        if !context.coordinator.touching { slider.value = Float(min(max(value, 0), Double(maximum))) }
        if slider.isEnabled != enabled { slider.isEnabled = enabled }
    }

    private static func thumbImage(diameter: CGFloat) -> UIImage {
        let canvas: CGFloat = 30
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvas, height: canvas))
        return renderer.image { context in
            let rect = CGRect(x: (canvas - diameter) / 2, y: (canvas - diameter) / 2, width: diameter, height: diameter)
            context.cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: UIColor.black.withAlphaComponent(0.4).cgColor)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: rect).fill()
        }
    }

    final class Coordinator: NSObject {
        var parent: PlayerScrubber
        var touching = false

        init(_ parent: PlayerScrubber) { self.parent = parent }

        @objc func touchDown(_ slider: UISlider) {
            touching = true
            (slider as? ScrubberSlider)?.setExpanded(true)
            parent.onScrub(Double(slider.value))
            parent.onEditingChanged(true)
        }

        @objc func valueChanged(_ slider: UISlider) {
            if touching {
                parent.onScrub(Double(slider.value))
            } else {
                // VoiceOver 上下滑动调节时没有触摸过程，直接跳转
                parent.onCommit(Double(slider.value))
            }
        }

        @objc func touchUp(_ slider: UISlider) {
            guard touching else { return }
            touching = false
            (slider as? ScrubberSlider)?.setExpanded(false)
            parent.onScrub(Double(slider.value))
            parent.onEditingChanged(false)
        }
    }
}

private final class ScrubberSlider: UISlider {
    private static let normalHeight: CGFloat = 5
    private static let expandedHeight: CGFloat = 9
    private var trackHeight = ScrubberSlider.normalHeight

    override init(frame: CGRect) {
        super.init(frame: frame)
        applyTrackImages()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        applyTrackImages()
    }

    override func trackRect(forBounds bounds: CGRect) -> CGRect {
        let base = super.trackRect(forBounds: bounds)
        return CGRect(x: base.minX, y: bounds.midY - trackHeight / 2, width: base.width, height: trackHeight)
    }

    func setExpanded(_ expanded: Bool) {
        let height = expanded ? Self.expandedHeight : Self.normalHeight
        guard height != trackHeight else { return }
        trackHeight = height
        applyTrackImages()
        setNeedsLayout()
        UIView.animate(withDuration: 0.16) { self.layoutIfNeeded() }
    }

    /// 轨道图片和轨道一样高，两头是半圆，拉伸时只拉中间
    private func applyTrackImages() {
        setMinimumTrackImage(Self.capsule(.white, height: trackHeight), for: .normal)
        setMaximumTrackImage(Self.capsule(UIColor.white.withAlphaComponent(0.3), height: trackHeight), for: .normal)
    }

    private static func capsule(_ color: UIColor, height: CGFloat) -> UIImage {
        let radius = height / 2
        let size = CGSize(width: height + 2, height: height)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius).fill()
        }
        return image.resizableImage(withCapInsets: UIEdgeInsets(top: 0, left: radius, bottom: 0, right: radius), resizingMode: .stretch)
    }
}

// MARK: - 深色弹出层

/// 播放页固定使用深色：把所在的全屏弹出层设为深色，菜单也跟着变深，不影响 App 其他页面。
private struct DarkPresentationStyle: UIViewRepresentable {
    func makeUIView(context: Context) -> DarkStyleAnchorView { DarkStyleAnchorView() }
    func updateUIView(_ view: DarkStyleAnchorView, context: Context) {}
}

private final class DarkStyleAnchorView: UIView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        isUserInteractionEnabled = false
        guard window != nil else { return }
        var responder: UIResponder? = next
        while let current = responder {
            if let controller = current as? UIViewController, controller.presentingViewController != nil {
                controller.overrideUserInterfaceStyle = .dark
                return
            }
            responder = current.next
        }
    }
}
