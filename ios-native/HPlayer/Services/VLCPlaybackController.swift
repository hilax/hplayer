import AVFoundation
import Foundation
import MobileVLCKit
import SwiftUI
import UIKit

/// 视频解码方式：硬解码交给 iPhone 的 VideoToolbox 硬件，软解码用 CPU（FFmpeg）。
enum VideoDecoding: String, CaseIterable, Identifiable {
    case hardware
    case software

    var id: String { rawValue }
    var title: String { self == .hardware ? "硬解码" : "软解码" }

    private static let key = "player.videoDecoding"

    /// 用户上次选的解码方式，默认硬解码
    static var saved: VideoDecoding {
        get { VideoDecoding(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .hardware }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// 播放前和播放中提前缓存多长时间的视频。越长越不怕网速起伏，但起播和拖动进度后要多等一会儿。
enum PrebufferLevel: Int, CaseIterable, Identifiable {
    case standard = 3
    case long = 8
    case maximum = 20

    var id: Int { rawValue }
    var milliseconds: Int { rawValue * 1000 }
    var title: String {
        switch self {
        case .standard: return "标准 · 3 秒"
        case .long: return "较长 · 8 秒"
        case .maximum: return "最长 · 20 秒"
        }
    }

    private static let key = "player.prebufferSeconds"

    static var saved: PrebufferLevel {
        get { PrebufferLevel(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

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
    /// 播放到了结尾（用于自动播放下一集）
    @Published private(set) var ended = false
    @Published var rate: Float = 1
    /// 长按快进的倍速
    static let boostRate: Float = 3
    private var resumeTime: Int32?
    private var shouldPauseAfterOpening = false
    private var boosted = false
    /// 最近一秒的下载速度（字节/秒），缓冲时显示给用户看
    @Published private(set) var downloadSpeed: Double = 0
    private var speedTask: Task<Void, Never>?
    private var lastReadBytes = 0
    /// 当前打开的地址和 115 请求头，拖动预览要另开一路取画面时照着用
    private var currentURL: URL?
    private var currentDirect115 = false
    private var currentCookie = ""
    /// 当前解码方式，切换后从当前位置重新打开视频
    @Published private(set) var decoding = VideoDecoding.saved
    /// 提前缓存的时长，切换后从当前位置重新打开视频
    @Published private(set) var prebuffer = PrebufferLevel.saved
    /// 用户自己按了暂停。VLC 网络缓冲时也会报告「没在播放」，
    /// 不能拿它当成用户暂停，否则拖动进度后会被误停住。
    private var userPaused = false
    /// 播放中途网速跟不上、画面停住的状态（VLC 这时仍报告「正在播放」）
    private var stalled = false
    private var lastSampledTime: Int32 = -1
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
        preservingPosition: Bool = false,
        startTime: Double? = nil,
        openTimeoutSeconds: UInt64 = 20
    ) {
        openTimeoutTask?.cancel()
        pendingSeek = nil
        pauseAfterSeek = false
        boosted = false
        ended = false
        stalled = false
        lastSampledTime = -1
        currentURL = url
        currentDirect115 = direct115
        currentCookie = directCookie
        let oldTime = preservingPosition ? currentTime : max(0, startTime ?? 0)
        let oldPlaying = preservingPosition ? playing : true
        player.stop()
        error = ""; currentTime = 0; duration = 0; buffering = true; seekable = false; bufferProgress = 0
        resumeTime = oldTime > 0 ? Int32(clamping: Int(oldTime * 1000)) : nil
        shouldPauseAfterOpening = !oldPlaying
        userPaused = !oldPlaying
        let media = VLCMedia(url: url)
        // 网络视频先攒 3 秒再播：原画码率高，网速有起伏时有这 3 秒垫着就不会一卡一卡。
        // 长按 3× 松手时会重开音轨清掉错位的声音，缓存长一点也不会让声音对不上。
        media.addOption(":network-caching=\(prebuffer.milliseconds)")
        media.addOption(":file-caching=800")
        // 拖动进度时落到最近的关键帧就开始播，不必从关键帧一路解码到目标那一帧，4K 大跨度跳转快很多
        media.addOption(":input-fast-seek")
        Self.applyDecoding(decoding, to: media)
        Self.applyRequestOptions(to: media, url: url, direct115: direct115, cookie: directCookie)
        player.media = media
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        startSpeedSampling()
        openTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: openTimeoutSeconds * 1_000_000_000)
            guard let self, !Task.isCancelled, !self.player.isPlaying, self.currentTime < 0.1, self.error.isEmpty else { return }
            self.buffering = false
            self.player.stop()
            self.error = "视频加载超时，请重新打开或切换画质。"
        }
    }

    func toggle() {
        pauseAfterSeek = false
        if player.state == .ended {
            // 播完了再按播放：从头开始
            userPaused = false
            player.stop()
            player.play()
        } else if userPaused {
            userPaused = false
            player.play()
        } else {
            userPaused = true
            player.pause()
        }
        refresh()
    }
    func seek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0, player.isSeekable else { return }
        let target = duration > 0 ? min(seconds, duration) : seconds
        pendingSeek = target
        pendingSeekStarted = Date()
        // 只有用户自己暂停时，跳转后才停在新位置；正在缓冲不算暂停
        pauseAfterSeek = userPaused
        player.time = VLCTime(int: Int32(clamping: Int(target * 1000)))
        currentTime = target
        // HLS needs a decoded frame at the requested time before it can pause again.
        if pauseAfterSeek { player.play() }
    }
    func skip(_ seconds: Double) { seek(to: max(0, currentTime + seconds)) }
    func setRate(_ value: Float) { rate = value; if !boosted { player.rate = value } }

    /// 长按快进：声音跟着一起 3× 加速。
    ///
    /// 变速前 VLC 已经按旧速度把后面一两秒的声音解码进了音频缓冲，松手回到 1× 时这段声音会错位，
    /// 接着补一段静音才追上画面。以前靠「原地重新定位」清掉它，可网络视频定位要重新缓冲，画面卡一秒左右。
    /// 现在松手时只把音轨关掉再打开：清掉错位的声音，新的音频解码器从当前位置接着出声，画面不受影响。
    func setBoost(_ enabled: Bool) {
        guard boosted != enabled else { return }
        boosted = enabled
        player.rate = enabled ? Self.boostRate : rate
        if !enabled { flushAudio() }
    }

    private func flushAudio() {
        guard player.numberOfAudioTracks > 0 else { return }
        let track = player.currentAudioTrackIndex
        guard track >= 0 else { return }
        player.currentAudioTrackIndex = -1
        player.currentAudioTrackIndex = track
    }

    // MARK: 解码方式

    /// 切换硬解码 / 软解码：记住选择，从当前位置重新打开当前视频
    func setDecoding(_ value: VideoDecoding) {
        guard value != decoding else { return }
        decoding = value
        VideoDecoding.saved = value
        guard let url = currentURL else { return }
        open(url, direct115: currentDirect115, directCookie: currentCookie, preservingPosition: true)
    }

    /// 切换提前缓存时长：记住选择，从当前位置重新打开当前视频
    func setPrebuffer(_ value: PrebufferLevel) {
        guard value != prebuffer else { return }
        prebuffer = value
        PrebufferLevel.saved = value
        guard let url = currentURL else { return }
        open(url, direct115: currentDirect115, directCookie: currentCookie, preservingPosition: true)
    }

    private static func applyDecoding(_ decoding: VideoDecoding, to media: VLCMedia) {
        switch decoding {
        case .hardware:
            // 先用 VideoToolbox 硬件解码，遇到硬件不支持的格式再退回软解
            media.addOption(":codec=videotoolbox,avcodec,all")
        case .software:
            media.addOption(":codec=avcodec,all")
            media.addOption(":avcodec-hw=none")
            // 和 VLC 官方 App 的默认一样：非参考帧跳过去块滤波，软解 1080P 以上更跟得上
            media.addOption(":avcodec-skiploopfilter=1")
        }
    }

    // MARK: 网速与预览

    /// 每秒看一次读了多少字节，换算成下载速度
    private func startSpeedSampling() {
        speedTask?.cancel()
        lastReadBytes = 0
        downloadSpeed = 0
        speedTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.sampleSpeed()
            }
        }
    }

    private func sampleSpeed() {
        guard let media = player.media else {
            downloadSpeed = 0
            return
        }
        let bytes = Int(media.statistics.readBytes)
        let delta = bytes - lastReadBytes
        lastReadBytes = bytes
        let speed = delta > 0 ? Double(delta) : 0
        if speed != downloadSpeed { downloadSpeed = speed }

        // VLC 播放中途缓存见底时，状态仍是「正在播放」，只是时间不走了。
        // 正在播放、时间却一秒没动，就算卡住了，画面中间转圈并显示网速。
        let time = player.time.intValue
        let state = player.state
        let active = state != .paused && state != .ended && state != .stopped && state != .error
        let stuck = !userPaused && active && pendingSeek == nil && time == lastSampledTime && time > 0
        lastSampledTime = time
        if stuck != stalled {
            stalled = stuck
            updateBuffering()
        }
    }

    private func updateBuffering() {
        let state = player.state
        let value = stalled || (!player.isPlaying && (state == .opening || state == .buffering))
        if value != buffering { buffering = value }
    }

    /// 给拖动预览用的同一个视频：不要声音，缓存短一点，带上同样的 115 请求头
    func makePreviewMedia() -> VLCMedia? {
        guard let url = currentURL else { return nil }
        let media = VLCMedia(url: url)
        media.addOption(":no-audio")
        media.addOption(":network-caching=500")
        // 预览用软解，不和正片抢硬件解码器
        media.addOption(":codec=avcodec,all")
        media.addOption(":avcodec-hw=none")
        Self.applyRequestOptions(to: media, url: url, direct115: currentDirect115, cookie: currentCookie)
        return media
    }

    private static func applyRequestOptions(to media: VLCMedia, url: URL, direct115: Bool, cookie: String) {
        guard direct115 else { return }
        media.addOption(":http-user-agent=\(Direct115Client.userAgent)")
        media.addOption(":http-referrer=https://115.com/")
        media.addOption(":http-forward-cookies=1")
        if let cookieOptions = cookieOptions(cookie) {
            media.addOption(":http-cookies=\(cookieOptions)")
            storeCookies(cookie, on: media, for: url)
        }
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
        stalled = false
        speedTask?.cancel()
        speedTask = nil
        downloadSpeed = 0
        player.stop()
        if detach { player.drawable = nil }
        playing = false; buffering = false; bufferProgress = 0; resumeTime = nil; shouldPauseAfterOpening = false
        userPaused = false
        ended = false
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
        if player.isPlaying { openTimeoutTask?.cancel() }
        // 「在播放」按用户意图算：没按暂停、没播完、没出错就是在播放，网络缓冲时按钮不会跳成播放键
        playing = !userPaused && state != .ended && state != .error && state != .stopped && player.media != nil
        // 时间又走起来了，就不算卡住
        if stalled, player.time.intValue != lastSampledTime || userPaused { stalled = false }
        updateBuffering()
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
        if state == .ended {
            ended = true
        } else if state == .playing || state == .opening {
            ended = false
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
