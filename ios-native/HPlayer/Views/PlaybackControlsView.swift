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

/// 右侧设置面板的分页
private enum SettingsPage: Equatable { case playback, tracks }

/// 横屏右侧面板的分页：选集、倍速、清晰度、字幕音轨
private enum SideTab: CaseIterable {
    case episodes, speed, quality, tracks

    var title: String {
        switch self {
        case .episodes: return "选集"
        case .speed: return "倍速"
        case .quality: return "清晰度"
        case .tracks: return "字幕音轨"
        }
    }
}

/// 横屏底栏上弹出气泡的三个按钮
private enum PlayerBubble: Equatable {
    case quality, speed, tracks

    /// 低于 iOS 16.4 弹不了气泡，退回到右侧面板的对应分页
    var sideTab: SideTab {
        switch self {
        case .quality: return .quality
        case .speed: return .speed
        case .tracks: return .tracks
        }
    }
}

private extension View {
    /// 在按钮旁边弹出的小气泡。iPhone 上默认会变成整页抽屉，这里要求保持气泡样式。
    @ViewBuilder
    func playerBubble<Bubble: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Bubble) -> some View {
        if #available(iOS 16.4, *) {
            popover(isPresented: isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                content()
                    .presentationCompactAdaptation(.popover)
                    .preferredColorScheme(.dark)
            }
        } else {
            self
        }
    }
}

/// 定时关闭
private enum SleepTimer: Equatable, Identifiable {
    case off, episodeEnd, minutes(Int)
    var id: String {
        switch self {
        case .off: return "off"
        case .episodeEnd: return "end"
        case .minutes(let value): return "\(value)"
        }
    }
    var title: String {
        switch self {
        case .off: return "关闭"
        case .episodeEnd: return "本集结束"
        case .minutes(let value): return "\(value) 分钟"
        }
    }
    static let options: [SleepTimer] = [.off, .episodeEnd, .minutes(15), .minutes(30), .minutes(60)]
}

/// 横竖屏共享的播放器控制层，视频画面由 mpv 绘制。
struct PlaybackControlsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var playback: PlaybackController
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
    var onSelect: (String) -> Void = { _ in }
    var onQuality: (String) -> Void = { _ in }
    var onRetry: () -> Void = { }
    var onClose: () -> Void

    @StateObject private var systemVolume = SystemVolumeController()
    @State private var controlsVisible = true
    @State private var locked = false
    @State private var showList = false
    @State private var settingsPage: SettingsPage?
    @State private var showAspect = false
    @State private var boosting = false
    @State private var dragging = false
    @State private var dragTime = 0.0
    /// 拖进度条开始时的播放位置，用来算「+ 00:20」
    @State private var scrubStart = 0.0
    /// 当前的 dragging 是不是由画面上的横滑快进带起来的（不是手指按在进度条上）
    @State private var panScrubbing = false
    /// 底栏上正在弹出的气泡（画质、倍速、字幕音轨）
    @State private var bubble: PlayerBubble?
    @State private var hideTask: Task<Void, Never>?
    @State private var lastSeekTick = 0
    /// 正在转回竖屏准备关闭，期间不再响应关闭和手势
    @State private var closing = false
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
    @State private var sleepTimer: SleepTimer = .off
    @State private var sleepTask: Task<Void, Never>?
    /// 缓冲超过一小会儿才显示转圈，打开视频和小卡顿时画面上不闪「正在缓冲」
    @State private var showBusy = false
    @State private var busyTask: Task<Void, Never>?
    @State private var copiedDiagnostics = false
    @State private var sideTab: SideTab = .episodes
    /// 播放器窗口当前是不是横屏（给状态栏和系统手势用，它们在 GeometryReader 外面）
    @State private var isLandscapeWindow = PlayerWindowController.startsInLandscape
    /// 正在柔和关闭：整个播放页淡出并轻轻缩小
    @State private var closeFade = false
    @Namespace private var sideNamespace
    @AppStorage("player.autoPlayNext") private var autoPlayNext = true

    /// 竖屏时顶部小窗播放器的高度（不含状态栏）
    private static let inlineVideoHeight: CGFloat = 220
    private static var isUITest: Bool { ProcessInfo.processInfo.environment["HPLAYER_UI_TEST_URL"] != nil }
    private static var testAutoNext: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["HPLAYER_UI_TEST_AUTO_NEXT"] == "1"
        #else
        return false
        #endif
    }

    /// 横屏时的安全区：沿用系统给的左右刘海避让，上沿贴边，下沿至少留 20 给进度条
    private static func layoutInsets(landscape: Bool, system: EdgeInsets) -> EdgeInsets {
        guard landscape else { return system }
        return EdgeInsets(top: 0, leading: system.leading, bottom: max(system.bottom, 20), trailing: system.trailing)
    }

    private static let speedOptions: [Float] = [0.75, 1, 1.25, 1.5, 2, 3]

    var body: some View {
        // 外层读系统安全区；里层铺满整块屏幕（含安全区）拿到真实的屏幕大小。
        // 播放器在独立窗口里，横竖屏就是窗口的真实方向：宽大于高就是横屏。
        GeometryReader { geometry in
            let systemInsets = geometry.safeAreaInsets
            GeometryReader { full in
                let landscape = full.size.width > full.size.height
                let layoutSize = full.size
                let insets = Self.layoutInsets(landscape: landscape, system: systemInsets)
                ZStack(alignment: .top) {
                    if landscape {
                        Theme.playerBackground
                    } else {
                        Theme.pageBackground
                    }

                    // 竖屏：上面是 16:9 的小窗播放器，下面是影片信息、选集和文件信息；横屏：画面铺满
                    VStack(spacing: 0) {
                        if !landscape { Color.black.frame(height: insets.top) }
                        videoLayer(landscape: landscape, insets: insets, width: layoutSize.width)
                        if !landscape { infoPage(bottomInset: insets.bottom) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    if showAspect && !locked {
                        aspectPanel(insets: insets)
                            .zIndex(7)
                    }

                    if let settingsPage, !locked {
                        settingsPanel(page: settingsPage, landscape: landscape, insets: insets)
                            .zIndex(8)
                    }

                    if showList && !locked {
                        if landscape {
                            sidePanel(insets: insets)
                                .zIndex(9)
                        } else {
                            playlistPanel(landscape: false, insets: insets)
                                .zIndex(9)
                        }
                    }
                }
                .foregroundColor(.white)
                .frame(width: layoutSize.width, height: layoutSize.height)
                .opacity(closeFade ? 0 : 1)
                .scaleEffect(closeFade ? 0.96 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: boosting)
                // onChange 不管初始值：窗口没能转成横屏（系统拒绝）时，状态栏和系统手势也要按真实方向来
                .onAppear { isLandscapeWindow = landscape }
                .onChange(of: landscape) { isLandscapeWindow = $0; bubble = nil }
            }
            .ignoresSafeArea()
        }
        .background(SystemVolumeHost(controller: systemVolume).frame(width: 1, height: 1).allowsHitTesting(false))
        .designScreen("player")
        .environment(\.colorScheme, .dark)
        .tint(.white)
        .statusBarHidden(isLandscapeWindow)
        .defersSystemGestures(on: isLandscapeWindow ? .all : [])
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
        .onAppear {
            updateBusy(loading || playback.buffering)
            originalBrightness = ScreenBrightness.screen.brightness
            brightnessLevel = Double(ScreenBrightness.screen.brightness)
            systemVolume.start()
            #if DEBUG
            switch InterfacePreview.screen {
            case "playback": settingsPage = .playback
            case "tracks": settingsPage = .tracks
            case "episodes": showList = true
            case "aspect": showAspect = true
            default: break
            }
            #endif
            revealControls()
        }
        .onDisappear {
            hideTask?.cancel()
            adjustmentHideTask?.cancel()
            sleepTask?.cancel()
            playback.setBoost(false)
            systemVolume.stop()
            if brightnessAdjusted, let originalBrightness { ScreenBrightness.screen.brightness = originalBrightness }
        }
        .onChange(of: systemVolume.externalChangeCount) { _ in
            showSystemVolumeChange()
        }
        .onChange(of: loading || playback.buffering) { busy in
            updateBusy(busy)
        }
        .onChange(of: playback.notice) { text in
            guard !text.isEmpty else { return }
            showNotice(text)
            playback.notice = ""
        }
        .onChange(of: playback.ended) { ended in
            // 自动连播：播完这一集接着播下一集（界面测试里关闭，免得切走正在检查的那一集）
            guard ended, autoPlayNext || Self.testAutoNext, !Self.isUITest || Self.testAutoNext, let id = nextID else { return }
            onSelect(id)
        }
        .onChange(of: playback.currentTime) { time in
            // 定时关闭「本集结束」：快到结尾时暂停，不再自动播下一集
            guard sleepTimer == .episodeEnd, playback.duration > 0, time >= playback.duration - 1.5, playback.playing else { return }
            playback.toggle()
            sleepTimer = .off
            showNotice("定时关闭：本集已结束")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            // 离开 App 时把亮度还给系统，回来后再恢复播放页的亮度
            if brightnessAdjusted, let originalBrightness { ScreenBrightness.screen.brightness = originalBrightness }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if brightnessAdjusted { ScreenBrightness.screen.brightness = CGFloat(brightnessLevel) }
        }
    }

    private func edgeControlInset(safe: CGFloat, width: CGFloat) -> CGFloat {
        max(safe + 12, width * 0.11 - 20)
    }

    // MARK: 顶部

    /// 左边关闭和片名，右边画面比例、字幕音轨、更多设置；按钮都是液态玻璃
    private func topBar(landscape: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            GlassIconButton(systemImage: AppIcon.close.name, label: "关闭播放", action: closePlayer)
                .accessibilityIdentifier("playback.close")

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                statusBadges
            }

            Spacer(minLength: 8)

            GlassButtonGroup {
                if landscape {
                GlassIconButton(systemImage: AppIcon.aspect.name, label: "画面比例", action: openAspect)
                    .accessibilityIdentifier("playback.aspect")
                GlassIconButton(systemImage: AppIcon.subtitle.name, label: "字幕和音轨") { openSettings(.tracks) }
                    .accessibilityIdentifier("playback.tracks")
                }
                GlassIconButton(systemImage: AppIcon.more.name, label: "更多设置") { openSettings(.playback) }
                    .accessibilityIdentifier("playback.more")
            }
        }
    }

    /// 片名下面的小标签：画质、分辨率、HDR，再跟一行灰字说明解码和倍速
    private var statusBadges: some View {
        HStack(spacing: 6) {
            ForEach(badges, id: \.self) { badge in
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            if !statusLine.isEmpty {
                Text(statusLine)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
        }
    }

    private var badges: [String] {
        var result: [String] = []
        let resolution = playback.videoBadges.first { $0.hasSuffix("K") || $0.hasSuffix("P") }
        if !selectedQuality.isEmpty {
            result.append([selectedQuality, selectedQuality == "原画" ? resolution : nil].compactMap { $0 }.joined(separator: " "))
        } else if let resolution {
            result.append(resolution)
        }
        if playback.videoBadges.contains("HDR") { result.append("HDR") }
        return result
    }

    private var statusLine: String {
        var parts: [String] = []
        if abs(playback.rate - 1) > 0.01 { parts.append("\(String(format: "%g", playback.rate))×") }
        if sleepTimer != .off { parts.append("定时 \(sleepTimer.title)") }
        if !networkStatus.isEmpty { parts.append(networkStatus) }
        return parts.joined(separator: " · ")
    }

    // MARK: 底部

    /// 横屏底栏。上一行：已播放时间、进度条、总时长排成一行；
    /// 下一行：画质和倍速在左，上一集、暂停、下一集在正中，字幕、选集和横竖屏在右。
    private func bottomBar(landscape: Bool) -> some View {
        VStack(spacing: landscape ? 0 : 10) {
            HStack(spacing: 12) {
                Text(timeText(dragging ? dragTime : playback.currentTime))
                    .font(.caption.weight(.medium).monospacedDigit())
                    .frame(width: timeLabelWidth, alignment: .leading)
                    .accessibilityIdentifier("playback.elapsed")
                scrubber
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                Text(playback.duration > 0 ? timeText(playback.duration) : "00:00")
                    .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                    .frame(width: timeLabelWidth, alignment: .trailing)
                    .accessibilityLabel("总时长")
            }

            sideControls(landscape: landscape)
        }
    }

    /// 时间文字的宽度固定，播放到一小时以上时进度条也不会跟着抖
    private var timeLabelWidth: CGFloat { playback.duration >= 3600 ? 58 : 42 }

    /// 画质、倍速、字幕音轨三个按钮点开后在按钮旁边弹出气泡；选集仍然打开右侧面板。按钮都是不带底色的图标。
    private func sideControls(landscape: Bool) -> some View {
        ZStack {
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    Button { openBubble(.quality) } label: { qualityIcon }
                        .buttonStyle(.plain)
                        .accessibilityLabel("播放画质")
                        .accessibilityIdentifier("playback.quality")
                        .playerBubble(isPresented: bubbleBinding(.quality)) { qualityBubble }
                    Button { openBubble(.speed) } label: {
                        controlIcon(AppIcon.speed.name, label: "播放速度", size: 20)
                            .foregroundStyle(abs(playback.rate - 1) > 0.01 ? Theme.gold : Color.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue("\(String(format: "%g", playback.rate))×")
                    .accessibilityIdentifier("playback.speed")
                    .playerBubble(isPresented: bubbleBinding(.speed)) { speedBubble }
                }
                // 图标四周有留白，往外挪一点，让图标本身和左边的时间文字对齐
                .padding(.leading, -10)
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    Button { openBubble(.tracks) } label: {
                        controlIcon(AppIcon.subtitle.name, label: "字幕和音轨", size: 20)
                            .foregroundStyle(playback.selectedSubtitle == nil ? Color.white : Theme.gold)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("playback.tracks")
                    .playerBubble(isPresented: bubbleBinding(.tracks)) { tracksBubble }
                    Button { openList() } label: {
                        controlIcon(AppIcon.playlist.name, label: "选集", size: 20)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("playback.playlist")
                    Button { toggleOrientation(landscape: landscape) } label: {
                        controlIcon(landscape ? AppIcon.exitFullscreen.name : AppIcon.fullscreen.name,
                                    label: landscape ? "竖屏" : "横屏", size: 18)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("playback.orientation")
                }
                .padding(.trailing, -10)
            }
            transportControls(spacing: 10, compact: true)
        }
        .frame(minHeight: 56)
    }

    /// 画质图标：圆角框里写 HD
    private var qualityIcon: some View {
        Text("HD")
            .font(.system(size: 11, weight: .heavy))
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .overlay { RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(lineWidth: 1.6) }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private func bubbleBinding(_ kind: PlayerBubble) -> Binding<Bool> {
        Binding(
            get: { bubble == kind },
            set: { presented in
                if presented { bubble = kind } else if bubble == kind { closeBubble() }
            }
        )
    }

    private func openBubble(_ kind: PlayerBubble) {
        hideTask?.cancel()
        if #available(iOS 16.4, *) {
            bubble = kind
        } else {
            openSidePanel(kind.sideTab)
        }
    }

    /// 关掉气泡后重新开始计时，控制栏过几秒再自动隐藏
    private func closeBubble() {
        bubble = nil
        revealControls()
    }

    private var speedBubble: some View {
        VStack(spacing: 2) {
            ForEach(Self.speedOptions, id: \.self) { rate in
                trackRow(title: "\(String(format: "%g", rate))×", detail: "", selected: abs(playback.rate - rate) < 0.001) {
                    playback.setRate(rate)
                    closeBubble()
                }
            }
        }
        .padding(8)
        .frame(width: 150)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var qualityBubble: some View {
        if qualities.isEmpty {
            Text("这个视频只有原画，没有别的清晰度可选。")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .padding(14)
                .frame(width: 200, alignment: .leading)
        } else {
            VStack(spacing: 2) {
                ForEach(qualities) { quality in
                    trackRow(title: quality.title, detail: "", selected: quality.title == selectedQuality) {
                        onQuality(quality.id)
                        closeBubble()
                    }
                }
            }
            .padding(8)
            .frame(width: 170)
            .foregroundStyle(.white)
        }
    }

    private var tracksBubble: some View {
        // 字幕和音轨可能很多，限制高度后在气泡里滚动；条目少时按条目数收紧，避免留一大块空白
        let rows = 2 + playback.subtitleTracks.count + playback.audioTracks.count
        let height = min(300, CGFloat(rows) * 46 + 70)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                subtitleSettings
                Divider().overlay(.white.opacity(0.12))
                audioSettings
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .frame(width: 280, height: height)
        .foregroundStyle(.white)
    }

    private func transportControls(spacing: CGFloat, compact: Bool = false) -> some View {
        HStack(spacing: spacing) {
            Button { move(-1) } label: {
                controlIcon(AppIcon.previous.name, label: "上一个", size: 18).background(.black.opacity(0.3), in: Circle()).glassCircle()
            }
                .accessibilityIdentifier("playback.previous")
                .disabled(previousID == nil)
                .opacity(previousID == nil ? 0.35 : 1)
            Button { playback.toggle(); revealControls() } label: {
                playPauseIcon(compact: compact)
                    .frame(height: compact ? 56 : 64).background(.black.opacity(0.3), in: Circle()).glassCircle()
            }
            .accessibilityIdentifier("playback.playPause")
            .accessibilityValue(playback.playing ? "playing" : "paused")
            Button { move(1) } label: {
                controlIcon(AppIcon.next.name, label: "下一个", size: 18).background(.black.opacity(0.3), in: Circle()).glassCircle()
            }
                .accessibilityIdentifier("playback.next")
                .disabled(nextID == nil)
                .opacity(nextID == nil ? 0.35 : 1)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func playPauseIcon(compact: Bool) -> some View {
        let name = playback.playing ? AppIcon.pause.name : AppIcon.play.name
        let label = playback.playing ? "暂停" : "播放"
        if #available(iOS 17.0, *), !reduceMotion {
            controlIcon(name, label: label, size: compact ? 25 : 29, frame: compact ? 56 : 64)
                .contentTransition(.symbolEffect(.replace))
                .animation(Motion.snappy, value: playback.playing)
        } else {
            controlIcon(name, label: label, size: compact ? 25 : 29, frame: compact ? 56 : 64)
        }
    }

    /// 拖进度条时，画面中间显示和左右滑动一样的跳转提示
    private func scrubbed(_ value: Double) {
        dragTime = value
        guard dragging, playback.duration > 0 else { return }
        adjustment = seekAdjustment(target: value, from: scrubStart)
    }

    private var scrubber: some View {
        PlayerScrubber(
            // 还不知道总时长时圆点停在最左边，不按当前时间乱放
            value: dragging ? dragTime : (playback.duration > 0 ? min(playback.currentTime, playback.duration) : 0),
            buffered: playback.duration > 0 ? min(max(playback.bufferedUntil, 0), playback.duration) : 0,
            upperBound: max(playback.duration, 1),
            enabled: playback.seekable && playback.duration > 0,
            onScrub: scrubbed,
            onEditingChanged: { editing in
                if editing {
                    dragging = true
                    scrubStart = playback.currentTime
                    hideTask?.cancel()
                    adjustmentHideTask?.cancel()
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
    }

    // MARK: 视频层（竖屏小窗 / 横屏全屏）

    @ViewBuilder
    private func videoLayer(landscape: Bool, insets: EdgeInsets, width: CGFloat) -> some View {
        let hudInsets = landscape ? insets : EdgeInsets()
        ZStack {
            Theme.playerBackground
            PlayerVideoSurface(playback: playback)
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
                if landscape {
                    landscapeControls(insets: insets, width: width)
                } else {
                    inlineControls
                }
            } else if controlsVisible && locked {
                HStack {
                    GlassIconButton(systemImage: AppIcon.lock.name, label: "解锁", diameter: 40, action: unlock)
                        .accessibilityIdentifier("playback.unlock")
                    Spacer()
                }
                .padding(.leading, landscape ? edgeControlInset(safe: insets.leading, width: width) : 16)
                .transition(.opacity)
                .zIndex(3)
            }

            centerStatus
                .scaleEffect(landscape ? 1 : 0.8)
                .zIndex(4)

            if boosting {
                boostPill
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, hudInsets.top + (controlsVisible && !locked ? (landscape ? 70 : 48) : 18))
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .zIndex(5)
            }

            hudLayer(insets: hudInsets)
                .zIndex(6)
        }
        .frame(maxWidth: .infinity, maxHeight: landscape ? .infinity : Self.inlineVideoHeight)
        .clipped()
    }

    private func landscapeControls(insets: EdgeInsets, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            topBar(landscape: true)
            Spacer(minLength: 0)
            bottomBar(landscape: true)
        }
        .padding(.leading, max(insets.leading, 28))
        .padding(.trailing, max(insets.trailing, 28))
        .padding(.top, max(insets.top, 12))
        .padding(.bottom, max(insets.bottom, 8))
        .background(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: insets.top + 120)
                .allowsHitTesting(false)
        }
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .frame(height: insets.bottom + 150)
                .allowsHitTesting(false)
        }
        .overlay {
            HStack {
                GlassIconButton(systemImage: AppIcon.unlock.name, label: "锁定", diameter: 40, action: lock)
                    .accessibilityIdentifier("playback.lock")
                Spacer()
                GlassIconButton(systemImage: AppIcon.screenshot.name, label: "截图", diameter: 40) { takeScreenshot() }
                    .accessibilityIdentifier("playback.screenshot")
            }
            .padding(.leading, edgeControlInset(safe: insets.leading, width: width))
            .padding(.trailing, edgeControlInset(safe: insets.trailing, width: width))
        }
        .transition(.opacity)
        .zIndex(2)
    }

    /// 竖屏小窗上的控制：左上返回，右上截图和更多；底部一行是播放、时间、进度条、全屏。
    private var inlineControls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: closePlayer) { controlIcon(AppIcon.back.name, label: "关闭播放", size: 20) }
                    .accessibilityIdentifier("playback.close")
                Spacer(minLength: 0)
                Button { takeScreenshot() } label: { controlIcon(AppIcon.screenshot.name, label: "截图", size: 19) }
                    .accessibilityIdentifier("playback.screenshot")
                Button { openSettings(.playback) } label: { controlIcon(AppIcon.more.name, label: "更多设置", size: 19) }
                    .accessibilityIdentifier("playback.more")
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                Button { playback.toggle(); revealControls() } label: {
                    controlIcon(playback.playing ? AppIcon.pause.name : AppIcon.play.name,
                                label: playback.playing ? "暂停" : "播放", size: 18, frame: 40)
                }
                .accessibilityIdentifier("playback.playPause")
                .accessibilityValue(playback.playing ? "playing" : "paused")
                Text(timeText(dragging ? dragTime : playback.currentTime))
                    .font(.system(size: 11).monospacedDigit())
                    .accessibilityIdentifier("playback.elapsed")
                scrubber
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .padding(.horizontal, 6)
                Text(playback.duration > 0 ? timeText(playback.duration) : "00:00")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                Button { toggleOrientation(landscape: false) } label: {
                    controlIcon(AppIcon.fullscreen.name, label: "横屏", size: 18)
                }
                .accessibilityIdentifier("playback.orientation")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .background(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 70)
                .allowsHitTesting(false)
        }
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .frame(height: 70)
                .allowsHitTesting(false)
        }
        .transition(.opacity)
        .zIndex(2)
    }

    // MARK: 竖屏信息页

    private var metaText: String {
        (badges + (statusLine.isEmpty ? [] : [statusLine])).joined(separator: " · ")
    }

    private func infoPage(bottomInset: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    if !metaText.isEmpty {
                        Text(metaText)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                quickRow
                episodesSection
                nextCard
                fileInfoSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, bottomInset + 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    private var quickRow: some View {
        HStack(spacing: 8) {
            quickCell(selectedQuality.isEmpty ? "原画" : selectedQuality, "清晰度", id: "playback.quality") { openSettings(.playback) }
            quickCell("\(String(format: "%g", playback.rate))×", "倍速", id: "playback.speed") { openSettings(.playback) }
            quickCell(playback.selectedSubtitle == nil ? "关闭" : "已开启", "字幕", id: "playback.tracks") { openSettings(.tracks) }
            quickCell(playback.aspect.title, "画面", id: "playback.aspect") { openAspect() }
            quickCell(playback.decoding.title, "解码", id: "playback.decoding") { openSettings(.playback) }
        }
        .padding(.top, 14)
    }

    private func quickCell(_ value: String, _ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(value)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("选集")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button { openList() } label: {
                    Text("\(autoPlayNext ? "自动连播 · " : "")共 \(max(items.count, 1)) 集 ›")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("playback.playlist")
            }
            if !items.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                stripCell(item, index: index)
                                    .id(item.id)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onAppear { proxy.scrollTo(selectedID, anchor: .center) }
                    .onChange(of: selectedID) { id in
                        withAnimation(reduceMotion ? nil : Motion.smooth) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .padding(.top, 14)
    }

    private func stripCell(_ item: PlaybackListItem, index: Int) -> some View {
        let currentIndex = items.firstIndex { $0.id == selectedID } ?? 0
        let current = index == currentIndex
        return Button {
            onSelect(item.id)
            revealControls()
        } label: {
            Text("\(index + 1)")
                .font(.system(size: 16, weight: current ? .bold : .medium).monospacedDigit())
                .foregroundStyle(current ? Theme.gold : (index < currentIndex ? Theme.textTertiary : Theme.textPrimary))
                .frame(width: 52, height: 52)
                .background(current ? Theme.gold.opacity(0.12) : Theme.surface,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    if current {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.gold, lineWidth: 1.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityIdentifier("playback.episode.\(item.id)")
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    @ViewBuilder
    private var nextCard: some View {
        if let id = nextID, let next = items.first(where: { $0.id == id }) {
            Button {
                onSelect(id)
                revealControls()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: AppIcon.play.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.gold)
                        .frame(width: 104, height: 58)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("接下来")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.gold)
                        Text(next.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if autoPlayNext {
                            Text("本集结束后自动播放")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            .accessibilityIdentifier("playback.nextCard")
        }
    }

    private var fileRows: [(String, String)] {
        var rows: [(String, String)] = [("文件", title)]
        if playback.duration > 0 { rows.append(("时长", timeText(playback.duration))) }
        if playback.bufferedUntil > 1 { rows.append(("已缓存", "到 " + timeText(playback.bufferedUntil))) }
        return rows
    }

    private var fileInfoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("文件信息")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            VStack(spacing: 0) {
                ForEach(Array(fileRows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 12) {
                        Text(row.0)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 8)
                        Text(row.1)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 13))
                    .frame(minHeight: 40)
                    .overlay(alignment: .bottom) {
                        if index < fileRows.count - 1 { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(.top, 22)
    }

    // MARK: 横屏右侧面板

    private func sidePanel(insets: EdgeInsets) -> some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture { closeList() }

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .bottom, spacing: 22) {
                    ForEach(SideTab.allCases, id: \.self) { tab in
                        sideTabButton(tab)
                    }
                }
                ScrollView {
                    sideContent
                        .padding(.top, 16)
                        .padding(.bottom, 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.top, max(insets.top, 18))
            .padding(.leading, 22)
            .padding(.trailing, max(insets.trailing, 0) + 26)
            .frame(width: 372 + insets.trailing, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .playerPanelBackground(cornerRadius: 0)
            .designScreen("episodes")
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private func sideTabButton(_ tab: SideTab) -> some View {
        let selected = sideTab == tab
        return Button {
            Haptics.select()
            withAnimation(reduceMotion ? nil : Motion.snappy) { sideTab = tab }
        } label: {
            Text(tab.title)
                .font(.system(size: selected ? 16 : 15, weight: selected ? .bold : .regular))
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.62))
                .padding(.bottom, 8)
                .overlay(alignment: .bottom) {
                    if selected {
                        Capsule()
                            .fill(Theme.gold)
                            .frame(width: 14, height: 3)
                            .matchedGeometryEffect(id: "side.tab", in: sideNamespace)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var sideContent: some View {
        switch sideTab {
        case .episodes:
            episodesGrid
        case .speed:
            settingGroup("播放速度") {
                chipGrid(Self.speedOptions.map { (String(format: "%g", $0), String(format: "%g", $0)) },
                         selected: String(format: "%g", playback.rate), columns: 3) { value in
                    if let rate = Float(value) { playback.setRate(rate) }
                }
            }
        case .quality:
            if qualities.isEmpty {
                Text("这个视频只有原画，没有别的清晰度可选。")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                VStack(spacing: 2) {
                    ForEach(qualities) { quality in
                        trackRow(title: quality.title, detail: "", selected: quality.title == selectedQuality) {
                            onQuality(quality.id)
                        }
                    }
                }
            }
        case .tracks:
            VStack(alignment: .leading, spacing: 18) {
                subtitleSettings
                Divider().overlay(.white.opacity(0.12))
                audioSettings
            }
        }
    }

    private var episodesGrid: some View {
        let currentIndex = items.firstIndex { $0.id == selectedID } ?? 0
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("共 \(items.count) 集")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.78))
                Spacer()
                Text("自动连播")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.78))
                Toggle("自动连播", isOn: $autoPlayNext)
                    .labelsHidden()
                    .tint(Theme.gold)
                    .accessibilityIdentifier("playback.autoNext")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    episodeButton(item, index: index, currentIndex: currentIndex)
                }
            }
            Text("已看完的集数显示为灰色，进度会自动同步到「继续观看」。")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func episodeButton(_ item: PlaybackListItem, index: Int, currentIndex: Int) -> some View {
        let current = index == currentIndex
        return Button {
            closeList()
            onSelect(item.id)
            revealControls()
        } label: {
            Text("\(index + 1)")
                .font(.system(size: 15, weight: current ? .bold : .medium).monospacedDigit())
                .foregroundStyle(current ? Theme.gold : (index < currentIndex ? Color(white: 0.56) : Color.white))
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(current ? Theme.gold.opacity(0.12) : Color.white.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    if current {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.gold, lineWidth: 1.5)
                    }
                }
                .overlay(alignment: .bottom) {
                    if current {
                        Capsule().fill(Theme.gold).frame(height: 2).padding(.horizontal, 12).padding(.bottom, 6)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityIdentifier("playback.item.\(item.id)")
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    // MARK: 画面比例

    private func aspectPanel(insets: EdgeInsets) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.25)
                .contentShape(Rectangle())
                .onTapGesture { closeAspect() }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("画面比例")
                        .font(.title2.bold())
                    Spacer()
                    GlassIconButton(systemImage: AppIcon.close.name, label: "关闭画面比例", diameter: 32) { closeAspect() }
                }
                Text("只影响当前视频")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(VideoAspect.allCases) { option in
                        aspectOption(option)
                    }
                }
                HStack(spacing: 12) {
                    Text("缩放")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    Slider(value: Binding(get: { playback.zoom }, set: { playback.setZoom($0) }), in: 1...2)
                        .accessibilityLabel("画面缩放")
                    Text("\(Int((playback.zoom * 100).rounded()))%")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                    GlassTextButton(title: "还原", label: "还原画面") {
                        playback.setAspect(.fit)
                        playback.setZoom(1)
                    }
                }
            }
            .padding(18)
            .padding(.bottom, insets.bottom)
            .frame(maxWidth: 620)
            .playerPanelBackground(cornerRadius: 26)
            .designScreen("aspect")
            .padding(.horizontal, 0)
            .padding(.bottom, 0)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func aspectOption(_ option: VideoAspect) -> some View {
        let selected = playback.aspect == option
        return Button {
            playback.setAspect(option)
        } label: {
            VStack(spacing: 6) {
                aspectIcon(option)
                    .frame(height: 22)
                Text(option.subtitle.map { "\(option.title)\n\($0)" } ?? option.title)
                    .font(.caption2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 74)
            .background(selected ? Theme.accent.opacity(0.28) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Color.white.opacity(0.12), lineWidth: selected ? 1.5 : 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func aspectIcon(_ option: VideoAspect) -> some View {
        switch option {
        case .fit:
            Image(systemName: AppIcon.aspectFit.name)
        case .fill:
            Image(systemName: AppIcon.aspectFill.name)
        case .stretch:
            Image(systemName: AppIcon.aspectStretch.name)
        default:
            Text(option.title)
                .font(.system(size: 15, weight: .bold))
        }
    }

    // MARK: 设置面板

    private func settingsPanel(page: SettingsPage, landscape: Bool, insets: EdgeInsets) -> some View {
        ZStack(alignment: landscape ? .trailing : .bottom) {
            Color.black.opacity(0.4)
                .contentShape(Rectangle())
                .onTapGesture { closeSettings() }
            VStack(alignment: .leading, spacing: 18) {
                if !landscape {
                    Capsule().fill(.white.opacity(0.25)).frame(width: 34, height: 4)
                        .frame(maxWidth: .infinity).accessibilityHidden(true)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(page == .playback ? "播放设置" : "字幕与音轨").font(.title2.weight(.bold))
                        Text(page == .playback ? "设置会应用于当前播放" : "选择适合你的观看语言")
                            .font(.caption).foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    GlassIconButton(systemImage: AppIcon.close.name, label: "关闭设置", diameter: 32) { closeSettings() }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch page {
                        case .playback: playbackSettings
                        case .tracks:
                            subtitleSettings
                            Divider().overlay(.white.opacity(0.12))
                            audioSettings
                        }
                    }
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.top, landscape ? max(insets.top, 18) : 12)
            .padding(.horizontal, 22)
            .padding(.bottom, max(insets.bottom, 18))
            .frame(width: landscape ? 360 + insets.trailing : nil)
            .frame(maxWidth: landscape ? 420 : .infinity)
            .frame(maxHeight: landscape ? .infinity : 590)
            .playerPanelBackground(cornerRadius: landscape ? 0 : 26)
            .designScreen(page == .playback ? "playback" : "tracks")
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private var playbackSettings: some View {
        if !qualities.isEmpty {
            settingGroup("画质") {
                chipRow(qualities.map { ($0.id, $0.title) }, selected: qualities.first { $0.title == selectedQuality }?.id) { id in
                    onQuality(id)
                }
            }
        }
        settingGroup("倍速") {
            chipGrid(Self.speedOptions.map { (String(format: "%g", $0), String(format: "%g", $0)) },
                     selected: String(format: "%g", playback.rate), columns: 6) { value in
                if let rate = Float(value) { playback.setRate(rate) }
            }
        }
        settingGroup("解码") {
            chipRow(VideoDecoding.allCases.map { ($0.rawValue, $0.title) }, selected: playback.decoding.rawValue) { value in
                if let option = VideoDecoding(rawValue: value) { playback.setDecoding(option) }
            }
        }
        settingGroup("提前缓存", footer: "开播不用等，边播边往后存；存在手机里，最多 2GB，退出播放后自动清掉。用流量时最多存 1 分钟。") {
            chipRow(ReadaheadLevel.allCases.map { (String($0.rawValue), $0.title) }, selected: String(playback.readahead.rawValue)) { value in
                if let seconds = Int(value), let option = ReadaheadLevel(rawValue: seconds) { playback.setReadahead(option) }
            }
        }
        settingGroup("定时关闭") {
            chipGrid(SleepTimer.options.map { ($0.id, $0.title) }, selected: sleepTimer.id, columns: 3) { id in
                if let option = SleepTimer.options.first(where: { $0.id == id }) { setSleepTimer(option) }
            }
        }
        settingGroup("遇到问题", footer: "播放不正常时点一下，把复制的内容发给开发者，里面有最近的跳转、重连记录和播放内核的报错，不含 Cookie。") {
            chip(copiedDiagnostics ? "已复制" : "复制播放诊断信息", selected: false) {
                UIPasteboard.general.string = diagnosticsText
                copiedDiagnostics = true
            }
            .accessibilityIdentifier("playback.copyDiagnosticsSetting")
        }
    }

    @ViewBuilder
    private var subtitleSettings: some View {
        settingGroup("字幕") {
            VStack(spacing: 2) {
                trackRow(title: "关闭字幕", detail: "", selected: playback.selectedSubtitle == nil) {
                    playback.selectSubtitle(nil)
                }
                ForEach(playback.subtitleTracks) { track in
                    trackRow(title: track.title, detail: track.detail, selected: playback.selectedSubtitle == track.id) {
                        playback.selectSubtitle(track.id)
                    }
                }
            }
        }
        if playback.subtitleTracks.isEmpty {
            Text("这个视频没有内嵌字幕。同一文件夹里同名的字幕文件会自动加载。")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    @ViewBuilder
    private var audioSettings: some View {
        settingGroup("音轨") {
            VStack(spacing: 2) {
                ForEach(playback.audioTracks) { track in
                    trackRow(title: track.title, detail: track.detail, selected: playback.selectedAudio == track.id) {
                        playback.selectAudio(track.id)
                    }
                }
            }
        }
        if playback.audioTracks.isEmpty {
            Text("视频加载后会在这里列出所有音轨。")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func settingGroup<Content: View>(_ title: String, footer: String = "", @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
            content()
            if !footer.isEmpty {
                Text(footer)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chipRow(_ options: [(String, String)], selected: String?, onPick: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(options, id: \.0) { option in
                    chip(option.1, selected: option.0 == selected) { onPick(option.0) }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func chipGrid(_ options: [(String, String)], selected: String?, columns: Int, onPick: @escaping (String) -> Void) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            ForEach(options, id: \.0) { option in
                chip(option.1, selected: option.0 == selected, fill: true) { onPick(option.0) }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, fill: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: { action(); revealControls() }) {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, fill ? 4 : 12)
                .frame(maxWidth: fill ? .infinity : nil, minHeight: 32)
                .background(selected ? Theme.accent.opacity(0.3) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Theme.accent : Color.white.opacity(0.12), lineWidth: selected ? 1.5 : 0.5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func trackRow(title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: AppIcon.check.name)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .opacity(selected ? 1 : 0)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(selected ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 播放列表

    private func playlistPanel(landscape: Bool, insets: EdgeInsets) -> some View {
        ZStack(alignment: landscape ? .trailing : .bottom) {
            Color.black.opacity(0.3)
                .contentShape(Rectangle())
                .onTapGesture { closeList() }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("选集")
                        .font(.title2.bold())
                    Text("\(items.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    GlassIconButton(systemImage: AppIcon.close.name, label: "关闭选集", diameter: 32) { closeList() }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 10)

                Text(title).font(.caption).foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 18).padding(.bottom, 12)
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            playlistRow(item, index: index)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 18)
                }
            }
            .padding(.top, landscape ? insets.top : 6)
            .padding(.trailing, landscape ? insets.trailing : 0)
            .padding(.bottom, insets.bottom)
            .frame(width: landscape ? 340 + insets.trailing : nil)
            .frame(maxWidth: landscape ? 420 : .infinity)
            .frame(maxHeight: landscape ? .infinity : 560)
            .playerPanelBackground(cornerRadius: landscape ? 0 : 26)
            .designScreen("episodes")
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
                        Image(systemName: AppIcon.audio.name)
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
        } else if showBusy && (loading || playback.buffering) && adjustment == nil {
            bufferingPill
                .transition(.opacity)
        }
    }

    private func errorCard(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: AppIcon.alert.name)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color(uiColor: .systemYellow))
            Text(text)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            if error.isEmpty && !playback.errorDetail.isEmpty {
                // 内核给出的具体原因，截图发过来就能看出是哪一步出的错
                Text(playback.errorDetail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            Button {
                // 播放中途断掉的，从原位置重新连接；还没拿到地址的（例如 115 接口出错），重新加载
                if error.isEmpty && playback.canRetryInPlace {
                    playback.retry()
                } else {
                    onRetry()
                }
                revealControls()
            } label: {
                Text("重试")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 2)
            }
            .tint(.white)
            .glassProminentButton()
            if error.isEmpty {
                // 真机上打不开时，把内核日志复制下来发给开发者
                Button {
                    UIPasteboard.general.string = diagnosticsText
                    copiedDiagnostics = true
                } label: {
                    Text(copiedDiagnostics ? "已复制" : "复制诊断信息")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("playback.copyDiagnostics")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: 320)
        .playerPanelBackground(cornerRadius: 20)
    }

    /// 开播前 1.5 秒、播放中 0.8 秒内缓冲好了就什么都不显示；超过了才出转圈
    private func updateBusy(_ busy: Bool) {
        busyTask?.cancel()
        guard busy else {
            showBusy = false
            copiedDiagnostics = false
            return
        }
        let delay: UInt64 = playback.currentTime > 0.5 && !loading ? 800_000_000 : 1_500_000_000
        busyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showBusy = true }
        }
    }

    /// 缓冲时画面中间一个转圈，下面是当前网速和已经缓存了多少秒
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
        .frame(maxWidth: 280)
        .shadow(color: .black.opacity(0.55), radius: 6, y: 1)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("playback.cacheStatus")
    }

    private var boostPill: some View {
        HStack(spacing: 6) {
            Image(systemName: AppIcon.skip.name)
                .font(.system(size: 11, weight: .bold))
            Text("\(String(format: "%g", PlaybackController.boostRate))× 快进中")
                .font(.footnote.weight(.semibold))
            if !speedLabel.isEmpty {
                Text(speedLabel)
                    .font(.footnote.weight(.medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .glassCapsule()
        .accessibilityElement(children: .combine)
    }

    /// 亮度、音量提示在画面上方，只有小图标和百分比；拖动进度提示在正中间。
    @ViewBuilder
    private func hudLayer(insets: EdgeInsets) -> some View {
        ZStack {
            if let adjustment {
                switch adjustment.kind {
                case .seek:
                    SeekHUD(adjustment: adjustment)
                        .transition(.opacity)
                case .brightness, .volume:
                    LevelHUD(adjustment: adjustment)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, insets.top + (controlsVisible && !locked ? 70 : 18))
                        .transition(.opacity)
                case .notice:
                    NoticeHUD(text: adjustment.valueText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, insets.top + (controlsVisible && !locked ? 70 : 18))
                        .transition(.opacity)
                }
            }
        }
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: adjustment?.kind)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("playback.adjustmentHUD")
    }

    private var bufferingText: String {
        guard playback.buffering else { return loadingText }
        var parts: [String] = []
        if !speedLabel.isEmpty { parts.append(speedLabel) }
        if playback.cachedSeconds >= 1 { parts.append("已缓冲 \(Int(playback.cachedSeconds)) 秒") }
        let detail = parts.isEmpty ? "正在缓冲" : parts.joined(separator: " · ")
        // 自动重连时说明在做什么，免得以为卡死了
        guard !playback.statusNote.isEmpty else { return detail }
        return parts.isEmpty ? playback.statusNote : "\(playback.statusNote)\n\(detail)"
    }

    /// 磁力边下边播用它自己的节点和速度，其他视频用内核报告的下载速度
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

    // MARK: 小部件

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
        settingsPage = nil
        showAspect = false
        revealControls()
    }
    private func unlock() {
        locked = false
        revealControls()
    }
    private func openList() { openSidePanel(.episodes) }
    private func openSidePanel(_ tab: SideTab) {
        hideTask?.cancel()
        settingsPage = nil
        showAspect = false
        sideTab = tab
        withAnimation(reduceMotion ? nil : Motion.smooth) { showList = true }
    }
    private func closeList() {
        withAnimation(reduceMotion ? nil : Motion.smooth) { showList = false }
        revealControls()
    }
    private func openSettings(_ page: SettingsPage) {
        hideTask?.cancel()
        showAspect = false
        showList = false
        withAnimation(reduceMotion ? nil : Motion.smooth) { settingsPage = page }
    }
    private func closeSettings() {
        withAnimation(reduceMotion ? nil : Motion.smooth) { settingsPage = nil }
        revealControls()
    }
    private func openAspect() {
        hideTask?.cancel()
        settingsPage = nil
        showList = false
        withAnimation(reduceMotion ? nil : Motion.smooth) { showAspect = true }
    }
    private func closeAspect() {
        withAnimation(reduceMotion ? nil : Motion.smooth) { showAspect = false }
        revealControls()
    }
    private func setSleepTimer(_ option: SleepTimer) {
        sleepTimer = option
        sleepTask?.cancel()
        guard case .minutes(let minutes) = option else { return }
        sleepTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            if playback.playing { playback.toggle() }
            sleepTimer = .off
            showNotice("定时关闭：已暂停播放")
        }
    }
    private func takeScreenshot() {
        revealControls()
        Task { @MainActor in
            let saved = await playback.screenshot()
            showNotice(saved ? "截图已保存到相册" : "截图未保存，请检查相册权限或稍后重试")
        }
    }
    private func applyVolume(_ value: Double) {
        systemVolume.set(value)
        if !systemVolume.controlsSystemVolume { playback.setSoftwareVolume(value) }
        if value > 0 && playback.muted { playback.setMuted(false) }
    }
    private func timeText(_ value: Double) -> String {
        guard value.isFinite && value >= 0 else { return "00:00" }
        return PlaybackController.clock(value)
    }
    private func revealControls() {
        if InterfacePreview.active { controlsVisible = true; return }
        if !controlsVisible {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { controlsVisible = true }
        }
        hideTask?.cancel()
#if DEBUG
        if ProcessInfo.processInfo.environment["HPLAYER_UI_TEST_KEEP_CONTROLS_VISIBLE"] == "1" {
            return
        }
#endif
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled && !showList && settingsPage == nil && !showAspect && bubble == nil && !dragging && !boosting && adjustment == nil && !playback.buffering {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { controlsVisible = false }
            }
        }
    }
    private var gestureStatus: String {
        "\(lastAdjustment); brightness=\(String(format: "%.3f", brightnessLevel)); volume=\(String(format: "%.3f", systemVolume.level)); time=\(String(format: "%.3f", playback.engineTime)); rate=\(String(format: "%g", boosting ? PlaybackController.boostRate : playback.rate)); buffering=\(playback.buffering ? 1 : 0); note=\(playback.statusNote); error=\(playback.error)"
    }

    private func toggleControls() {
        if settingsPage != nil { closeSettings(); return }
        if showAspect { closeAspect(); return }
        if controlsVisible {
            hideTask?.cancel()
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { controlsVisible = false }
        } else {
            revealControls()
        }
    }

    private func setBoost(_ enabled: Bool) {
        if enabled {
            guard !locked, !showList, settingsPage == nil, panKind == nil, playback.playing else { return }
            boosting = true
            lastAdjustment = "长按 \(String(format: "%g", PlaybackController.boostRate))×"
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
    private static let panLockDistance: CGFloat = 14

    private func handlePan(_ state: UIGestureRecognizer.State, origin: CGPoint, translation: CGPoint, size: CGSize) {
        if state == .cancelled || state == .failed {
            endPanScrub()
            panActive = false
            panKind = nil
            adjustment = nil
            revealControls()
            return
        }
        guard !locked, !showList, settingsPage == nil, !showAspect, !closing, size.width > 0, size.height > 0 else {
            // 横滑到一半被别的面板打断：进度条别停在半路
            if state == .ended { endPanScrub() }
            return
        }
        if state == .began {
            setBoost(false)
            adjustmentHideTask?.cancel()
            hideTask?.cancel()
            adjustmentStartTime = playback.currentTime
            // 每次从屏幕和系统的真实值开始调：自动亮度、音量键、控制中心都可能在两次滑动之间改过它们
            adjustmentStartBrightness = Double(ScreenBrightness.screen.brightness)
            adjustmentStartVolume = systemVolume.currentLevel()
            panKind = nil
            panBase = .zero
            panActive = true
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
            // 以 45° 为界：更偏横就快进快退，更偏竖就调亮度（左半边）或音量（右半边）
            if dx > dy {
                guard playback.seekable, playback.duration > 0 else {
                    panActive = false
                    showNotice(playback.duration > 0 ? "视频还在加载，暂时不能拖动进度" : "这个视频不支持拖动进度")
                    return
                }
                panKind = .seek
                beginPanScrub(at: adjustmentStartTime)
                lastSeekTick = Int(adjustmentStartTime / Self.seekTickSeconds)
                Self.seekTicker.prepare()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
            // 滑满一屏宽能跳的时长：最多 9 分钟
            let range = min(540, max(90, playback.duration * 0.6))
            // 滑过头也只停在结尾前 5 秒，不会一下跳到最后、直接播完停住
            let ceiling = max(adjustmentStartTime, playback.duration - 5)
            let target = min(max(adjustmentStartTime + Double(moveX / size.width) * range, 0), max(0, ceiling))
            seekHaptic(target: target)
            adjustment = seekAdjustment(target: target, from: adjustmentStartTime)
            // 进度条和左右两端的时间跟着手指实时走；松手才真正跳转
            dragTime = target
        case .brightness:
            let value = min(max(adjustmentStartBrightness - Double(moveY / size.height) * 1.2, 0.02), 1)
            ScreenBrightness.screen.brightness = CGFloat(value)
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
            if let target = adjustment?.targetTime {
                playback.seek(to: target)
            }
            endPanScrub()
            self.panKind = nil
            panActive = false
            hideAdjustmentSoon()
        }
    }

    /// 开始横滑快进：把控制栏亮出来，进度条改由手指位置驱动（和手指按在进度条上拖是同一套显示）。
    private func beginPanScrub(at time: Double) {
        panScrubbing = true
        dragTime = time
        dragging = true
        hideTask?.cancel()
        if !controlsVisible {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { controlsVisible = true }
        }
    }

    /// 横滑结束（松手、取消或被打断）：进度条回到跟着播放位置走。
    /// 跳转已经在松手时发出，playback.currentTime 当场就是目标位置，所以不会先弹回旧位置。
    private func endPanScrub() {
        guard panScrubbing else { return }
        panScrubbing = false
        dragging = false
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

    /// 拖动快进快退时，每跨过 10 秒轻震一下；到头时重一点
    private static let seekTickSeconds = 10.0
    private static let seekTicker = UISelectionFeedbackGenerator()

    private func seekHaptic(target: Double) {
        let tick = Int(target / Self.seekTickSeconds)
        guard tick != lastSeekTick else { return }
        lastSeekTick = tick
        if target <= 0 || target >= playback.duration - 0.5 {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } else {
            Self.seekTicker.selectionChanged()
            Self.seekTicker.prepare()
        }
    }

    /// 横滑用不了时给一句提示，不要什么反应都没有。
    private func showNotice(_ text: String) {
        adjustmentHideTask?.cancel()
        adjustment = PlaybackAdjustment(kind: .notice, title: "提示", valueText: text, progress: 0)
        lastAdjustment = "提示 \(text)"
        hideAdjustmentSoon(delay: 1.6)
    }

    /// 按音量键或在控制中心调节时，同样用小提示显示当前音量。
    private func showSystemVolumeChange() {
        guard panKind == nil else { return }
        let value = systemVolume.level
        if value > 0 && playback.muted { playback.setMuted(false) }
        adjustmentHideTask?.cancel()
        adjustment = PlaybackAdjustment(kind: .volume, title: "音量", valueText: "\(Int((value * 100).rounded()))%", progress: value)
        lastAdjustment = "音量 \(Int((value * 100).rounded()))%"
        hideAdjustmentSoon(revealing: false)
    }

    private func hideAdjustmentSoon(revealing: Bool = true, delay: Double = 0.9) {
        adjustmentHideTask?.cancel()
        adjustmentHideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            adjustment = nil
            if revealing { revealControls() }
        }
    }
    /// 柔和关闭：控制栏和整个播放页一起淡出、轻轻缩小，淡出结束后直接关掉。
    /// 主窗口一直是竖屏、没有转过，所以不需要翻转，也不需要遮罩。
    private func closePlayer() {
        guard !closing else { return }
        closing = true
        hideTask?.cancel()
        playback.setBoost(false)
        playback.pauseForClose()
        PlayerWindowController.shared.willClose()
        showList = false
        settingsPage = nil
        showAspect = false
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            controlsVisible = false
            closeFade = true
        }
        Task { @MainActor in
            if !reduceMotion { try? await Task.sleep(nanoseconds: 310_000_000) }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { onClose() }
        }
    }

    /// 播放内核的诊断信息，后面附上播放器窗口的转屏过程和主线程卡顿记录
    private var diagnosticsText: String {
        [playback.diagnostics, PlayerWindowController.shared.diagnostics].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// 横竖屏按钮：让播放器窗口真的转过去（系统的控制中心、录屏方向也跟着变）
    private func toggleOrientation(landscape: Bool) {
        PlayerWindowController.shared.setLandscape(!landscape)
        revealControls()
    }
}

// MARK: - 液态玻璃按钮

/// 播放页的玻璃圆钮：iOS 26 用系统的液态玻璃按钮样式（按下会有弹性和高光），低版本降级成毛玻璃圆钮
private struct GlassIconButton: View {
    let systemImage: String
    let label: String
    var diameter: CGFloat = 42
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: diameter * 0.36, weight: .semibold))
                    .frame(width: diameter - 14, height: diameter - 14)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(label)
        } else {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: diameter * 0.36, weight: .semibold))
                    .frame(width: diameter, height: diameter)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5) }
                    .frame(width: max(diameter, 44), height: max(diameter, 44))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
        }
    }
}

/// 玻璃胶囊文字按钮：倍速「1.0×」、「选集」、「还原」
private struct GlassTextButton: View {
    let title: String
    let label: String
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(action: action) {
                Text(title)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .accessibilityLabel(label)
        } else {
            Button(action: action) {
                Text(title)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay { Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5) }
                    .frame(minHeight: 44)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
        }
    }
}

/// 几个相邻的玻璃按钮放进同一个容器：iOS 26 上它们会像一组液态玻璃一样互相融合
private struct GlassButtonGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) { content() }
            }
        } else {
            HStack(spacing: 10) { content() }
        }
    }
}

private extension View {
    /// Opaque surfaces keep settings readable over bright HDR footage.
    func playerPanelBackground(cornerRadius: CGFloat) -> some View {
        self.background(Theme.playerSurface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - 屏幕亮度

/// 播放页所在屏幕：iOS 26 起不再推荐 UIScreen.main，优先用前台窗口场景的屏幕
@MainActor
private enum ScreenBrightness {
    static var screen: UIScreen {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let active = scenes.first(where: { $0.activationState == .foregroundActive }) { return active.screen }
        if let scene = scenes.first { return scene.screen }
        return UIScreen.main
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
            return value < 0.35 ? AppIcon.brightnessLow.name : AppIcon.brightnessHigh.name
        case .volume:
            if value <= 0.001 { return AppIcon.volumeMute.name }
            if value < 0.34 { return AppIcon.volumeLow.name }
            if value < 0.67 { return AppIcon.volumeMedium.name }
            return AppIcon.volumeHigh.name
        case .seek:
            return AppIcon.seek.name
        case .notice:
            return AppIcon.alert.name
        }
    }
}

/// 一句话提示：例如视频暂时不能拖动进度
private struct NoticeHUD: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: AppIcon.alert.name)
                .font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .glassCapsule()
    }
}

/// 拖动进度：目标时间 / 总时长、一条小进度、跳转了多少
private struct SeekHUD: View {
    let adjustment: PlaybackAdjustment

    var body: some View {
        VStack(spacing: 8) {
            Text(adjustment.detail)
                .font(.system(size: 22, weight: .bold).monospacedDigit())
            LevelBar(value: adjustment.progress)
                .frame(width: 150, height: 3)
            Text(adjustment.valueText)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.55), radius: 6, y: 1)
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

/// 圆头粗轨道：白色是已播放，浅白是已经缓存好的，最淡的是还没下载的；按住时轨道变粗、圆点放大，方便拖动。
private struct PlayerScrubber: UIViewRepresentable {
    var value: Double
    var buffered: Double
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
        slider.bufferedFraction = CGFloat(min(max(buffered / Double(maximum), 0), 1))
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
    /// 已缓存到的位置，画在轨道下面的一段浅白色
    private let bufferedView = UIView()
    var bufferedFraction: CGFloat = 0 {
        didSet { if abs(oldValue - bufferedFraction) > 0.001 { setNeedsLayout() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUpBufferedView()
        applyTrackImages()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpBufferedView()
        applyTrackImages()
    }

    private func setUpBufferedView() {
        bufferedView.isUserInteractionEnabled = false
        bufferedView.backgroundColor = UIColor.white.withAlphaComponent(0.35)
        insertSubview(bufferedView, at: 0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let track = trackRect(forBounds: bounds)
        bufferedView.frame = CGRect(x: track.minX, y: track.minY, width: track.width * bufferedFraction, height: track.height)
        bufferedView.layer.cornerRadius = track.height / 2
        sendSubviewToBack(bufferedView)
    }

    override func trackRect(forBounds bounds: CGRect) -> CGRect {
        let base = super.trackRect(forBounds: bounds)
        return CGRect(x: base.minX, y: bounds.midY - trackHeight / 2, width: base.width, height: trackHeight)
    }

    /// 圆点图片四周留了透明边，系统默认让图片边缘贴着轨道两头，圆点中心就离开了起点，
    /// 0 秒时左边会多出一截白色。这里让圆点中心正好落在轨道的起点和终点之间。
    override func thumbRect(forBounds bounds: CGRect, trackRect rect: CGRect, value: Float) -> CGRect {
        let base = super.thumbRect(forBounds: bounds, trackRect: rect, value: value)
        let range = maximumValue - minimumValue
        let fraction = range > 0 ? CGFloat((value - minimumValue) / range) : 0
        let centerX = rect.minX + rect.width * min(max(fraction, 0), 1)
        return CGRect(x: centerX - base.width / 2, y: base.minY, width: base.width, height: base.height)
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
        setMinimumTrackImage(Self.capsule(UIColor(red: 0.914, green: 0.690, blue: 0.380, alpha: 1), height: trackHeight), for: .normal)
        setMaximumTrackImage(Self.capsule(UIColor.white.withAlphaComponent(0.22), height: trackHeight), for: .normal)
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
