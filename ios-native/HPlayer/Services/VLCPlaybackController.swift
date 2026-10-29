import AVFoundation
import Foundation
import MobileVLCKit
import SwiftUI
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
    @Published private(set) var bufferProgress: Double = 0
    @Published private(set) var muted = false
    @Published private(set) var error = ""
    @Published var rate: Float = 1
    /// 长按快进的倍速
    static let boostRate: Float = 3
    private var resumeTime: Int32?
    private var shouldPauseAfterOpening = false
    private var boosted = false
    private var openTimeoutTask: Task<Void, Never>?
    private var pendingSeek: Double?
    private var pendingSeekStarted = Date.distantPast
    private var pauseAfterSeek = false

    override init() {
        super.init()
        player.delegate = self
    }

    func open(
        _ url: URL,
        direct115: Bool = false,
        directCookie: String = "",
        preservingPosition: Bool = false
    ) {
        openTimeoutTask?.cancel()
        pendingSeek = nil
        pauseAfterSeek = false
        boosted = false
        let oldTime = preservingPosition ? currentTime : 0
        let oldPlaying = preservingPosition ? playing : true
        player.stop()
        error = ""; currentTime = 0; duration = 0; buffering = true; seekable = false; bufferProgress = 0
        resumeTime = oldTime > 0 ? Int32(clamping: Int(oldTime * 1000)) : nil
        shouldPauseAfterOpening = !oldPlaying
        let media = VLCMedia(url: url)
        // VLC 会把音频提前解码进输出缓冲，提前量约等于这里的缓存时长（最多 2 秒）。
        // 缓存越长，变速（长按 3×）时排队的旧声音越多，松手后重新定位也要多缓冲一会儿。
        // 1.5 秒对 115 CDN 和本机磁力流都够用，起播和拖动进度也更快。
        media.addOption(":network-caching=1500")
        media.addOption(":file-caching=800")
        if direct115 {
            media.addOption(":http-user-agent=\(Direct115Client.userAgent)")
            media.addOption(":http-referrer=https://115.com/")
            media.addOption(":http-forward-cookies=1")
            if let cookieOptions = Self.cookieOptions(directCookie) {
                media.addOption(":http-cookies=\(cookieOptions)")
                Self.storeCookies(directCookie, on: media, for: url)
            }
        }
        player.media = media
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        openTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, !Task.isCancelled, !self.playing, self.currentTime < 0.1, self.error.isEmpty else { return }
            self.buffering = false
            self.player.stop()
            self.error = "视频加载超时，请重新打开或切换画质。"
        }
    }

    func toggle() {
        pauseAfterSeek = false
        if player.isPlaying { player.pause() } else { player.play() }
    }
    func seek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0, player.isSeekable else { return }
        let target = duration > 0 ? min(seconds, duration) : seconds
        pendingSeek = target
        pendingSeekStarted = Date()
        pauseAfterSeek = !player.isPlaying
        player.time = VLCTime(int: Int32(clamping: Int(target * 1000)))
        currentTime = target
        // HLS needs a decoded frame at the requested time before it can pause again.
        if pauseAfterSeek { player.play() }
    }
    func skip(_ seconds: Double) { seek(to: max(0, currentTime + seconds)) }
    func setRate(_ value: Float) { rate = value; if !boosted { player.rate = value } }

    /// 长按快进。松手时原地重新定位一次，让声音立刻和画面对齐。
    func setBoost(_ enabled: Bool) {
        guard boosted != enabled else { return }
        boosted = enabled
        player.rate = enabled ? Self.boostRate : rate
        if !enabled { resynchronizeAudio() }
    }

    /// VLC 在变速前已经把后面一两秒的声音按旧速度解码进了音频缓冲。
    /// 从 3× 回到 1× 时，这段声音会先错位播放，接着补一段静音才追上画面，听起来就是「声音慢了一两秒」。
    /// 在当前位置精确定位一次会清空解码器和音频缓冲，从画面所在的位置重新出声。
    private func resynchronizeAudio() {
        guard player.isSeekable, player.numberOfAudioTracks > 0 else { return }
        let position = Double(player.time.intValue) / 1000
        guard position > 0.5 else { return }
        seek(to: position)
    }

    /// 播放器自己的静音开关；音量大小统一交给系统音量。
    func toggleMute() { setMuted(!muted) }

    func setMuted(_ value: Bool) {
        guard let audio = player.audio else {
            muted = value
            return
        }
        audio.isMuted = value
        muted = audio.isMuted
    }

    /// 拿不到系统音量控制时（例如模拟器）才使用播放器自己的软件音量。
    func setSoftwareVolume(_ normalized: Double) {
        guard let audio = player.audio else { return }
        audio.volume = Int32((min(max(normalized, 0), 1) * 100).rounded())
    }
    func stop(detach: Bool = true) {
        openTimeoutTask?.cancel()
        pendingSeek = nil
        pauseAfterSeek = false
        boosted = false
        player.stop()
        if detach { player.drawable = nil }
        playing = false; buffering = false; bufferProgress = 0; resumeTime = nil; shouldPauseAfterOpening = false
    }

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in self?.refresh() }
    }
    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in self?.refresh() }
    }
    nonisolated func mediaPlayerBufferingChanged(_ progress: Float) {
        let value = Double(max(0, min(progress, 1)))
        Task { @MainActor [weak self] in self?.bufferProgress = value }
    }

    private func refresh() {
        let state = player.state
        playing = player.isPlaying
        if playing { openTimeoutTask?.cancel() }
        buffering = !player.isPlaying && (state == .opening || state == .buffering)
        seekable = player.isSeekable
        let decodedTime = max(0, Double(player.time.intValue) / 1000)
        if let pendingSeek {
            currentTime = pendingSeek
            // 在线 HLS 的关键帧间隔可能有好几秒，定位后实际落点和目标会差出一截。
            // 只等「落点到位」会让进度一直卡在目标时间上，所以不在缓冲时最多等 5 秒就以真实时间为准。
            let landed = abs(decodedTime - pendingSeek) < 1
            let gaveUp = !buffering && Date().timeIntervalSince(pendingSeekStarted) > 5
            if landed || gaveUp {
                self.pendingSeek = nil
                currentTime = decodedTime
                if pauseAfterSeek { pauseAfterSeek = false; player.pause() }
            }
        } else { currentTime = decodedTime }
        let length = Double(player.media?.length.intValue ?? 0) / 1000
        duration = length.isFinite && length > 0 ? length : 0
        if let resumeTime, state == .playing, player.isSeekable {
            player.time = VLCTime(int: resumeTime)
            self.resumeTime = nil
        }
        if state == .playing {
            let targetRate: Float = boosted ? Self.boostRate : rate
            if abs(player.rate - targetRate) > 0.01 { player.rate = targetRate }
            if shouldPauseAfterOpening { shouldPauseAfterOpening = false; player.pause() }
        }
        if state == .error {
            openTimeoutTask?.cancel()
            buffering = false
            error = "播放失败，请尝试其他画质或检查网络。"
        }
    }

    private static func cookieOptions(_ header: String) -> String? {
        let cookies = cookiePairs(header).map { "\($0); Path=/" }
        return cookies.isEmpty ? nil : cookies.joined(separator: "\n")
    }

    private static func storeCookies(_ header: String, on media: VLCMedia, for url: URL) {
        guard let host = url.host, !host.isEmpty else { return }
        for pair in cookiePairs(header) {
            _ = media.storeCookie("\(pair); Path=/; HttpOnly", forHost: host, path: "/")
        }
    }

    private static func cookiePairs(_ header: String) -> [String] {
        header.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { pair in
                guard let equals = pair.firstIndex(of: "=") else { return false }
                let name = String(pair[..<equals])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                return !name.isEmpty && !["path", "domain", "expires", "max-age", "samesite"].contains(name)
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
