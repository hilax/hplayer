import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// 将系统 `AVRoutePickerView` 封装为可由自定义按钮触发的隐藏宿主视图。
struct AirPlayRoutePickerTrigger: UIViewRepresentable {
    var onTriggerReady: (@escaping () -> Void) -> Void

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        picker.prioritizesVideoDevices = true
        picker.tintColor = .clear
        picker.activeTintColor = .clear
        picker.alpha = 0.01
        picker.isAccessibilityElement = false
        picker.accessibilityElementsHidden = true
        bindTrigger(for: picker)
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        bindTrigger(for: uiView)
    }

    private func bindTrigger(for picker: AVRoutePickerView) {
        DispatchQueue.main.async { [weak picker] in
            onTriggerReady { [weak picker] in
                guard let picker else { return }
                Self.findButton(in: picker)?.sendActions(for: .touchUpInside)
            }
        }
    }

    private static func findButton(in view: UIView) -> UIButton? {
        for subview in view.subviews {
            if let button = subview as? UIButton { return button }
            if let nested = findButton(in: subview) { return nested }
        }
        return nil
    }
}

/// AirPlay（隔空播放）会话控制器：
/// 由于主播放器使用 mpv 自绘渲染，隔空播放期间由轻量的 `AVPlayer` 接管局域网中转地址，
/// 与设备建立隔空连接后再暂停本地 mpv，断开时把最新播放位置交还给 mpv。
@MainActor
final class AirPlayCastController: ObservableObject {
    @Published private(set) var isExternalPlaybackActive = false
    @Published private(set) var deviceName = "AirPlay 设备"
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var ended = false
    @Published private(set) var errorMessage = ""

    var onExternalPlaybackStarted: ((String) -> Void)?
    var onExternalPlaybackEnded: (() -> Void)?
    var onPositionChanged: ((Double, Double) -> Void)?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var externalObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var pendingSeekTime: Double?
    private var shouldPlayWhenConnected = true
    private var wasExternalActive = false

    private static let unsupportedExtensions: Set<String> = [
        "mkv", "avi", "flv", "wmv", "rmvb", "webm", "ogv"
    ]

    /// AVPlayer 原生不支持 MKV/AVI 等封装格式，需提示走 DLNA 或由调用方自动切至 115 转码 HLS。
    static func isAirPlayNativelySupported(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return true }
        return !unsupportedExtensions.contains(ext)
    }

    func prepareAndLoad(url: URL, startTime: Double, autoPlayOnExternal: Bool = true) {
        teardownObservations(keepPlayer: false)
        errorMessage = ""
        ended = false
        currentTime = max(0, startTime)
        pendingSeekTime = startTime > 1 ? startTime : nil
        shouldPlayWhenConnected = autoPlayOnExternal

        PlayerAudioSession.activate()

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        player.actionAtItemEnd = .pause
        self.player = player

        observePlayer(player, item: item)

        let activeNow = player.isExternalPlaybackActive
        isExternalPlaybackActive = activeNow
        deviceName = Self.currentAirPlayRouteName() ?? "AirPlay 设备"
        if activeNow {
            wasExternalActive = true
            if autoPlayOnExternal {
                player.play()
            }
            onExternalPlaybackStarted?(deviceName)
        } else {
            // 未真正连上隔空设备前保持暂停，避免本地与 mpv 重音；连上后再自动开始。
            player.pause()
        }
    }

    func togglePlayPause() {
        guard let player else { return }
        if ended {
            ended = false
            seek(to: 0)
            player.play()
            return
        }
        if player.timeControlStatus == .playing || player.rate > 0.01 {
            shouldPlayWhenConnected = false
            player.pause()
        } else {
            shouldPlayWhenConnected = true
            player.play()
        }
    }

    func seek(to seconds: Double) {
        guard let player, seconds.isFinite, seconds >= 0 else { return }
        ended = false
        currentTime = seconds
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        teardownObservations(keepPlayer: false)
        isExternalPlaybackActive = false
        wasExternalActive = false
        isPlaying = false
        isBuffering = false
        currentTime = 0
        duration = 0
        ended = false
        errorMessage = ""
        pendingSeekTime = nil
    }

    private func observePlayer(_ player: AVPlayer, item: AVPlayerItem) {
        externalObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                self?.handleExternalStateChange(active: player.isExternalPlaybackActive)
            }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch player.timeControlStatus {
                case .playing:
                    self.isPlaying = true
                    self.isBuffering = false
                case .waitingToPlayAtSpecifiedRate:
                    self.isPlaying = false
                    self.isBuffering = self.isExternalPlaybackActive
                case .paused:
                    self.isPlaying = false
                    self.isBuffering = false
                @unknown default:
                    break
                }
            }
        }

        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    let total = item.duration.seconds
                    if total.isFinite && total > 0 { self.duration = total }
                    if let target = self.pendingSeekTime {
                        self.pendingSeekTime = nil
                        self.seek(to: target)
                    }
                    if self.isExternalPlaybackActive && self.shouldPlayWhenConnected {
                        self.player?.play()
                    }
                case .failed:
                    self.errorMessage = item.error?.userMessage ?? "隔空播放加载失败"
                    self.isBuffering = false
                default:
                    break
                }
            }
        }

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                let sec = time.seconds
                if sec.isFinite, sec >= 0 { self.currentTime = sec }
                if let total = player.currentItem?.duration.seconds, total.isFinite, total > 0 {
                    self.duration = total
                }
                if self.isExternalPlaybackActive {
                    self.onPositionChanged?(self.currentTime, self.duration)
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = false
                self.ended = true
            }
        }

        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self?.errorMessage = err?.userMessage ?? "隔空播放中断"
                self?.isBuffering = false
            }
        }

        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshRouteState()
            }
        }
    }

    private func handleExternalStateChange(active: Bool) {
        let routeName = Self.currentAirPlayRouteName()
        if let routeName { deviceName = routeName }
        let effectivelyActive = active
        isExternalPlaybackActive = effectivelyActive

        if effectivelyActive && !wasExternalActive {
            wasExternalActive = true
            if shouldPlayWhenConnected {
                player?.play()
            }
            onExternalPlaybackStarted?(deviceName)
        } else if !effectivelyActive && wasExternalActive {
            wasExternalActive = false
            player?.pause()
            onExternalPlaybackEnded?()
        }
    }

    private func refreshRouteState() {
        let routeName = Self.currentAirPlayRouteName()
        if let routeName {
            deviceName = routeName
        }
        let active = player?.isExternalPlaybackActive == true
        if active != isExternalPlaybackActive || active != wasExternalActive {
            handleExternalStateChange(active: active)
        }
    }

    private static func currentAirPlayRouteName() -> String? {
        AVAudioSession.sharedInstance().currentRoute.outputs
            .first(where: { $0.portType == .airPlay })?.portName
    }

    private func teardownObservations(keepPlayer: Bool) {
        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        externalObservation?.invalidate()
        externalObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        failObserver = nil
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        if !keepPlayer {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }
    }
}
