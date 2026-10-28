import SwiftUI
import UIKit

struct PlaybackListItem: Identifiable, Hashable {
    let id: String
    let title: String
    var subtitle: String = ""
}

private struct PlaybackAdjustmentHUD: View {
    let adjustment: PlaybackAdjustment

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(adjustment.title)
                        .font(.subheadline.weight(.semibold))
                    Text(adjustment.valueText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            ProgressView(value: min(max(adjustment.progress, 0), 1))
                .progressViewStyle(.linear)
                .tint(.white)
                .frame(width: 210)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("playback.adjustmentHUD")
        .accessibilityLabel("\(adjustment.title) \(adjustment.valueText)")
    }

    private var icon: String {
        switch adjustment.kind {
        case .seek:
            return adjustment.valueText.hasPrefix("-") ? "gobackward" : "goforward"
        case .brightness:
            return "sun.max.fill"
        case .volume:
            return adjustment.progress == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill"
        }
    }
}

struct PlaybackChoice: Identifiable, Hashable {
    let id: String
    let title: String
}

/// 横竖屏共享的播放器控制层，视频画面由 VLC 绘制。
private struct PlaybackAdjustment {
    enum Kind: Equatable {
        case seek
        case brightness
        case volume
    }

    let kind: Kind
    let title: String
    let valueText: String
    let progress: Double
    let targetTime: Double?
}

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
    var onSelect: (String) -> Void = { _ in }
    var onQuality: (String) -> Void = { _ in }
    var onRetry: () -> Void = { }
    var onClose: () -> Void

    @State private var controlsVisible = true
    @State private var locked = false
    @State private var showList = false
    @State private var boosting = false
    @State private var dragging = false
    @State private var dragTime = 0.0
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
    @State private var lastAdjustment = ""
    @State private var originalBrightness: CGFloat?
    @State private var brightnessLevel: Double = 0.5

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
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
                        topBar
                        Spacer()
                        if !error.isEmpty || !playback.error.isEmpty {
                            errorBanner(!error.isEmpty ? error : playback.error)
                        } else if loading || playback.buffering {
                            bufferingStatus
                        }
                        Spacer()
                        bottomBar(landscape: landscape)
                    }
                    .padding(.horizontal, landscape ? 36 : 18)
                    .padding(.top, max(geometry.safeAreaInsets.top, 12))
                    .padding(.bottom, max(geometry.safeAreaInsets.bottom, 14))
                    .background(alignment: .top) { LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom).frame(height: 125).allowsHitTesting(false) }
                    .background(alignment: .bottom) { LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom).frame(height: landscape ? 190 : 210).allowsHitTesting(false) }
                    .zIndex(2)
                } else if controlsVisible && locked {
                    HStack {
                        Button(action: unlock) { controlIcon("lock.fill", label: "解锁") }
                            .accessibilityIdentifier("playback.unlock")
                        Spacer()
                    }.padding(.horizontal, 28)
                        .zIndex(3)
                }

                if boosting {
                    Label("3× 快进", systemImage: "forward.fill")
                        .font(.subheadline.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 9)
                        .background(.black.opacity(0.65), in: Capsule())
                        .frame(maxHeight: .infinity, alignment: .top).padding(.top, max(geometry.safeAreaInsets.top, 20) + 12)
                        .allowsHitTesting(false)
                }
                if let adjustment {
                    PlaybackAdjustmentHUD(adjustment: adjustment)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .zIndex(4)
                }
                if showList && !locked { playlistPanel(landscape: landscape) }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
        .statusBarHidden(true)
        .onAppear {
            originalBrightness = UIScreen.main.brightness
            brightnessLevel = UIScreen.main.brightness
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
            if let originalBrightness { UIScreen.main.brightness = originalBrightness }
            if requestedLandscape { OrientationSupport.restorePortrait() }
        }
        .alert("无法切换屏幕方向", isPresented: Binding(get: { !rotateError.isEmpty }, set: { if !$0 { rotateError = "" } })) {
            Button("好", role: .cancel) { rotateError = "" }
        } message: { Text(rotateError) }
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            Button { onClose() } label: { Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: 40, height: 40) }
                .accessibilityLabel("关闭播放")
            Text(title).font(.headline).lineLimit(1)
            Spacer(minLength: 4)
            Menu {
                if !qualities.isEmpty {
                    Section("画质") { ForEach(qualities) { choice in Button(choice.title) { onQuality(choice.id); revealControls() } } }
                }
                Section("播放速度") { ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { value in Button("\(String(format: "%g", value))×") { playback.setRate(value); revealControls() } } }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 40, height: 40) }
            Button { playback.toggleMute(); revealControls() } label: { Image(systemName: playback.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 40, height: 40) }
                .accessibilityLabel(playback.muted ? "取消静音" : "静音")
        }
    }

    private func bottomBar(landscape: Bool) -> some View {
        VStack(spacing: landscape ? 10 : 16) {
            if playback.buffering {
                HStack(spacing: 8) {
                    if playback.bufferProgress > 0 {
                        ProgressView(value: playback.bufferProgress)
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .frame(width: landscape ? 150 : 110)
                    } else {
                        ProgressView().controlSize(.mini).tint(.white)
                    }
                    Text(cacheText)
                    Spacer()
                }
                .font(.caption2)
                .foregroundColor(.white.opacity(0.78))
                .accessibilityIdentifier("playback.cacheStatus")
            }
            HStack(spacing: 12) {
                Text(timeText(dragging ? dragTime : playback.currentTime)).monospacedDigit().font(.caption).accessibilityIdentifier("playback.elapsed")
                Slider(value: Binding(get: { dragging ? dragTime : min(playback.currentTime, max(playback.duration, 1)) }, set: { dragTime = $0 }), in: 0...max(playback.duration, 1), onEditingChanged: { editing in
                    dragging = editing
                    if !editing { playback.seek(to: dragTime); revealControls() }
                })
                .tint(.white).disabled(!playback.seekable || playback.duration <= 0)
                Text(timeText(playback.duration)).monospacedDigit().font(.caption)
            }
            HStack(spacing: 0) {
                Button(action: lock) { controlIcon("lock", label: "锁定") }
                    .accessibilityIdentifier("playback.lock")
                Spacer(minLength: 4)
                if landscape { Button { move(-1) } label: { controlIcon("backward.end.fill", label: "上一个") }.disabled(previousID == nil) }
                Button { playback.skip(-10); revealControls() } label: { controlIcon("gobackward.10", label: "后退 10 秒") }
                Button { playback.toggle(); revealControls() } label: { controlIcon(playback.playing ? "pause.fill" : "play.fill", label: playback.playing ? "暂停" : "播放", size: 27) }
                    .accessibilityIdentifier("playback.playPause")
                    .accessibilityValue(playback.playing ? "playing" : "paused")
                Button { playback.skip(10); revealControls() } label: { controlIcon("goforward.10", label: "前进 10 秒") }
                if landscape { Button { move(1) } label: { controlIcon("forward.end.fill", label: "下一个") }.disabled(nextID == nil) }
                Spacer(minLength: 4)
                if landscape { Menu {
                    ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { rate in
                        Button("\(String(format: "%g", rate))×") { playback.setRate(rate); revealControls() }
                    }
                } label: { Text("\(String(format: "%g", playback.rate))×").font(.subheadline.weight(.semibold)).frame(width: 45, height: 44) } }
                if landscape && !qualities.isEmpty {
                    Menu {
                        ForEach(qualities) { choice in
                            Button(choice.title) { onQuality(choice.id); revealControls() }
                        }
                    } label: { Text(selectedQuality.isEmpty ? "画质" : selectedQuality).font(.caption.weight(.semibold)).lineLimit(1).frame(minWidth: 42, minHeight: 44) }
                }
                Button { toggleOrientation(landscape: landscape) } label: { controlIcon(landscape ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", label: landscape ? "竖屏" : "横屏") }
                    .accessibilityIdentifier("playback.orientation")
                Button { showList = true; hideTask?.cancel() } label: { controlIcon("list.bullet", label: "播放列表") }
                    .accessibilityIdentifier("playback.playlist")
            }
            .buttonStyle(.plain)
        }
    }

    private func playlistPanel(landscape: Bool) -> some View {
        HStack(spacing: 0) {
            Color.black.opacity(0.3).onTapGesture { showList = false; revealControls() }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("播放列表").font(.headline)
                    Spacer()
                    Button { showList = false; revealControls() } label: { Image(systemName: "xmark").padding(8) }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            Button {
                                showList = false; onSelect(item.id); revealControls()
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: item.id == selectedID ? "speaker.wave.2.fill" : "play.fill")
                                        .foregroundColor(item.id == selectedID ? Theme.accent : .secondary).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.title).lineLimit(2).foregroundColor(item.id == selectedID ? Theme.accent : .white)
                                        if !item.subtitle.isEmpty { Text(item.subtitle).font(.caption).foregroundColor(.secondary) }
                                    }
                                    Spacer()
                                }.padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("playback.item.\(item.id)")
                        }
                    }
                }
            }
            .padding(20).frame(width: landscape ? 340 : 280).frame(maxHeight: .infinity)
            .background(Color(white: 0.10).opacity(0.97))
        }.transition(.move(edge: .trailing))
    }

    private func errorBanner(_ text: String) -> some View {
        VStack(spacing: 10) {
            Text(text).multilineTextAlignment(.center)
            Button("重试") { onRetry(); revealControls() }.font(.subheadline.weight(.semibold))
        }.padding(16).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
    }
    private var bufferingStatus: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().tint(.white)
                Text(playback.buffering ? cacheText : loadingText)
            }
            if playback.buffering && playback.bufferProgress > 0 {
                ProgressView(value: playback.bufferProgress)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(width: 180)
            }
        }
        .font(.subheadline)
        .padding(12)
        .background(.black.opacity(0.6), in: Capsule())
        .allowsHitTesting(false)
    }
    private var cacheText: String {
        playback.bufferProgress > 0
            ? "缓存 \(Int((playback.bufferProgress * 100).rounded()))%"
            : "正在缓存"
    }
    private func controlIcon(_ name: String, label: String, size: CGFloat = 20) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .semibold))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(label)
    }
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
    private func timeText(_ value: Double) -> String {
        guard value.isFinite && value >= 0 else { return "00:00" }
        let seconds = Int(value)
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60) : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    private func revealControls() {
        controlsVisible = true
        hideTask?.cancel()
#if DEBUG
        if ProcessInfo.processInfo.environment["HPLAYER_UI_TEST_KEEP_CONTROLS_VISIBLE"] == "1" {
            return
        }
#endif
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled && !showList && !dragging && !boosting && adjustment == nil && !playback.buffering {
                controlsVisible = false
            }
        }
    }
    private var gestureStatus: String {
        "\(lastAdjustment); brightness=\(String(format: "%.3f", brightnessLevel)); volume=\(String(format: "%.3f", playback.volume)); time=\(Double(playback.player.time.intValue) / 1000); rate=\(String(format: "%g", boosting ? 3 : playback.rate))"
    }

    private func toggleControls() {
        if controlsVisible { controlsVisible = false; hideTask?.cancel() }
        else { revealControls() }
    }

    private func setBoost(_ enabled: Bool) {
        if enabled {
            guard !locked, !showList, panKind == nil, playback.playing else { return }
            boosting = true
            lastAdjustment = "长按 3×"
            playback.setBoost(true)
            hideTask?.cancel()
        } else if boosting {
            boosting = false
            playback.setBoost(false)
            revealControls()
        }
    }

    private func handlePan(_ state: UIGestureRecognizer.State, origin: CGPoint, translation: CGPoint, size: CGSize) {
        if state == .cancelled || state == .failed {
            panKind = nil
            adjustment = nil
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
            adjustmentStartVolume = playback.volume
            if abs(translation.x) > abs(translation.y) {
                guard playback.seekable, playback.duration > 0 else { panKind = nil; return }
                panKind = .seek
            } else {
                panKind = origin.x < size.width / 2 ? .brightness : .volume
            }
        }
        guard let panKind else { return }
        adjustmentHideTask?.cancel()
        switch panKind {
        case .seek:
            let range = min(180, max(30, playback.duration / 5))
            let target = min(max(adjustmentStartTime + Double(translation.x / size.width) * range, 0), max(0, playback.duration - 0.25))
            let delta = Int((target - adjustmentStartTime).rounded())
            adjustment = PlaybackAdjustment(
                kind: .seek, title: delta >= 0 ? "快进" : "快退",
                valueText: "\(delta >= 0 ? "+" : "")\(delta) 秒 · \(timeText(target))",
                progress: target / playback.duration, targetTime: target
            )
        case .brightness:
            let value = min(max(adjustmentStartBrightness - Double(translation.y / size.height) * 1.2, 0.05), 1)
            UIScreen.main.brightness = value
            brightnessLevel = value
            adjustment = PlaybackAdjustment(kind: .brightness, title: "亮度", valueText: "\(Int((value * 100).rounded()))%", progress: value, targetTime: nil)
        case .volume:
            let value = min(max(adjustmentStartVolume - Double(translation.y / size.height) * 1.2, 0), 1)
            playback.setVolume(value)
            adjustment = PlaybackAdjustment(kind: .volume, title: "音量", valueText: "\(Int((value * 100).rounded()))%", progress: value, targetTime: nil)
        }
        if let adjustment { lastAdjustment = "\(adjustment.title) \(adjustment.valueText)" }
        if state == .ended {
            if let target = adjustment?.targetTime { playback.seek(to: target) }
            self.panKind = nil
            hideAdjustmentSoon()
        }
    }
    private func hideAdjustmentSoon() {
        adjustmentHideTask?.cancel()
        adjustmentHideTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            adjustment = nil
            revealControls()
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
