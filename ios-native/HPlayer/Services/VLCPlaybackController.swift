import AVFoundation
import Foundation
import MobileVLCKit
import UIKit

/// 统一使用 VideoLAN 的 VLC 播放内核；视频控制界面由 HPlayer 自己绘制。
@MainActor
final class VLCPlaybackController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()
    @Published private(set) var playing = false
    @Published private(set) var buffering = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var seekable = false
    @Published private(set) var muted = false
    @Published private(set) var error = ""
    @Published var rate: Float = 1
    private var resumeTime: Int32?
    private var shouldPauseAfterOpening = false
    private var boosted = false

    override init() {
        super.init()
        player.delegate = self
    }

    func open(_ url: URL, direct115: Bool = false, preservingPosition: Bool = false) {
        let oldTime = preservingPosition ? currentTime : 0
        let oldPlaying = preservingPosition ? playing : true
        player.stop()
        error = ""; currentTime = 0; duration = 0; buffering = true; seekable = false
        resumeTime = oldTime > 0 ? Int32(clamping: Int(oldTime * 1000)) : nil
        shouldPauseAfterOpening = !oldPlaying
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=1200")
        if direct115 {
            media.addOption(":http-user-agent=\(Direct115Client.userAgent)")
            media.addOption(":http-referrer=https://115.com/")
        }
        player.media = media
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }

    func toggle() {
        if player.isPlaying { player.pause() } else { player.play() }
    }
    func seek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0, player.isSeekable else { return }
        let target = duration > 0 ? min(seconds, duration) : seconds
        player.time = VLCTime(int: Int32(clamping: Int(target * 1000)))
        currentTime = target
    }
    func skip(_ seconds: Double) { seek(to: max(0, currentTime + seconds)) }
    func setRate(_ value: Float) { rate = value; if !boosted { player.rate = value } }
    func setBoost(_ enabled: Bool) { boosted = enabled; player.rate = enabled ? 2 : rate }
    func toggleMute() {
        guard let audio = player.audio else { return }
        audio.isMuted.toggle()
        muted = audio.isMuted
    }
    func stop(detach: Bool = true) {
        player.stop()
        if detach { player.drawable = nil }
        playing = false; buffering = false; resumeTime = nil; shouldPauseAfterOpening = false
    }

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in self?.refresh() }
    }
    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in self?.refresh() }
    }

    private func refresh() {
        let state = player.state
        playing = player.isPlaying
        buffering = state == .opening || state == .buffering
        seekable = player.isSeekable
        currentTime = max(0, Double(player.time.intValue) / 1000)
        let length = Double(player.media?.length.intValue ?? 0) / 1000
        duration = length.isFinite && length > 0 ? length : 0
        if let resumeTime, state == .playing, player.isSeekable {
            player.time = VLCTime(int: resumeTime)
            self.resumeTime = nil
        }
        if state == .playing {
            let targetRate: Float = boosted ? 2 : rate
            if abs(player.rate - targetRate) > 0.01 { player.rate = targetRate }
            if shouldPauseAfterOpening { shouldPauseAfterOpening = false; player.pause() }
        }
        if state == .error {
            buffering = false
            error = "播放失败，请尝试其他画质或检查网络。"
        }
    }
}

struct VLCVideoSurface: UIViewRepresentable {
    @ObservedObject var playback: VLCPlaybackController

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        playback.player.drawable = view
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        if playback.player.drawable as? UIView !== view { playback.player.drawable = view }
    }
    static func dismantleUIView(_ view: UIView, coordinator: ()) { }
}
