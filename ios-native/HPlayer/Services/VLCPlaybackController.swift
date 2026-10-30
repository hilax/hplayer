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
    /// 当前打开的地址和 115 请求头，切换解码或预缓冲时照着重新打开
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
    private var openTimeoutSeconds: UInt64 = 20
    private var pendingSeek: Double?
    private var pendingSeekStarted = Date.distantPast
    private var pauseAfterSeek = false

    // MARK: 卡住自动重连
    //
    // VLC 3 读网络数据没有超时：拖动进度后新开的连接如果迟迟不回数据（CDN 冷门位置、连接被限制），
    // 它会一直等下去，画面就永远停在「正在缓冲」；连接中途断掉时又会被当成「播完了」，画面定住不动。
    // 这里每秒检查一次：长时间一个字节都没读到、或者没到结尾却停了，就停掉卡住的连接，
    // 换一个新地址（115 能拿到的话）从原来的位置重新打开，等于自动替用户「退出再进来」。

    /// 拿新播放地址的办法；115 的地址会过期或被限制连接，重连时先换新地址
    private var urlRefresher: (() async throws -> URL)?
    /// 是否自动重连（磁力边下边播等的是种子数据，不适用）
    private var watchdogEnabled = true
    /// 恢复播放用的位置：最近一次确定的播放时间，或者正在跳往的目标
    private var resumePoint: Double = 0
    /// 连续几秒没有读到任何数据
    private var noDataSeconds = 0
    /// VLC 的统计里能看到读取的字节数（直接读文件时能，HLS 分片不算在里面）
    private var bytesVisible = false
    /// 处于结束、出错、停止状态已经几秒
    private var badStateSeconds = 0
    /// 这个地址是否已经正常开始播放过
    private var hasPlayed = false
    private var recoveryAttempts: [Date] = []
    private var recoveryTask: Task<Void, Never>?
    /// 每次打开新视频或关闭播放器加一，旧的重连任务回来时对不上就作废
    private var session = 0
    /// 自动重连时画面中间显示的说明
    @Published private(set) var statusNote = ""

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
        refreshURL: (() async throws -> URL)? = nil,
        autoRecover: Bool = true,
        openTimeoutSeconds: UInt64 = 20
    ) {
        session += 1
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryAttempts = []
        statusNote = ""
        urlRefresher = refreshURL
        watchdogEnabled = autoRecover
        self.openTimeoutSeconds = openTimeoutSeconds
        let position = preservingPosition ? resumePoint : max(0, startTime ?? 0)
        let keepPlaying = preservingPosition ? !userPaused : true
        start(url, direct115: direct115, cookie: directCookie, position: position, keepPlaying: keepPlaying, keepDuration: preservingPosition)
    }

    /// 真正打开地址：新视频、切换设置、自动重连都走这里
    private func start(_ url: URL, direct115: Bool, cookie: String, position: Double, keepPlaying: Bool, keepDuration: Bool) {
        openTimeoutTask?.cancel()
        pendingSeek = nil
        pauseAfterSeek = false
        boosted = false
        ended = false
        stalled = false
        hasPlayed = false
        bytesVisible = false
        noDataSeconds = 0
        badStateSeconds = 0
        lastSampledTime = -1
        currentURL = url
        currentDirect115 = direct115
        currentCookie = cookie
        player.stop()
        error = ""; buffering = true; seekable = false; bufferProgress = 0
        if !keepDuration { duration = 0 }
        resumePoint = position
        if position > 0 {
            // 进度先停在要恢复的位置，等真正跳过去再按实际时间走，不会先跳回 0
            currentTime = position
            pendingSeek = position
            pendingSeekStarted = Date()
        } else {
            currentTime = 0
        }
        resumeTime = position > 0 ? Int32(clamping: Int(position * 1000)) : nil
        shouldPauseAfterOpening = !keepPlaying
        userPaused = !keepPlaying
        playing = keepPlaying
        let media = VLCMedia(url: url)
        // 网络视频先攒几秒再播（预缓冲可在菜单里调）：原画码率高，网速有起伏时有这几秒垫着就不会一卡一卡。
        // 长按 3× 松手时会重开音轨清掉错位的声音，缓存长一点也不会让声音对不上。
        media.addOption(":network-caching=\(prebuffer.milliseconds)")
        media.addOption(":file-caching=800")
        // 拖动进度时落到最近的关键帧就开始播，不必从关键帧一路解码到目标那一帧，4K 大跨度跳转快很多
        media.addOption(":input-fast-seek")
        Self.applyDecoding(decoding, to: media)
        Self.applyRequestOptions(to: media, url: url, direct115: direct115, cookie: cookie)
        player.media = media
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        startSpeedSampling()
        let timeout = openTimeoutSeconds
        let currentSession = session
        openTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
            guard let self, !Task.isCancelled, self.session == currentSession, !self.hasPlayed, self.error.isEmpty else { return }
            if self.watchdogEnabled {
                self.recover(reason: "视频加载超时")
            } else {
                self.player.stop()
                self.giveUp("视频加载超时")
            }
        }
    }

    func toggle() {
        pauseAfterSeek = false
        if playing {
            userPaused = true
            player.pause()
        } else {
            userPaused = false
            noDataSeconds = 0
            let state = player.state
            if state == .ended || state == .stopped || state == .error {
                if duration > 0, resumePoint < duration - 5, currentURL != nil {
                    // 没到结尾却停了（多半是网络断了）：从停下的位置重新打开，而不是什么都不做
                    recoveryAttempts = []
                    recover(reason: "")
                } else {
                    // 真的播完了：从头开始
                    resumePoint = 0
                    player.stop()
                    player.play()
                }
            } else {
                player.play()
            }
        }
        refresh()
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        let target = duration > 0 ? min(seconds, duration) : seconds
        let state = player.state
        if currentURL != nil, recoveryTask != nil || state == .ended || state == .stopped || state == .error {
            // 连接已经断了或正在重连：直接从新的目标位置重新打开
            resumePoint = target
            currentTime = target
            recoveryTask?.cancel()
            recoveryTask = nil
            recoveryAttempts = []
            recover(reason: "")
            return
        }
        guard player.isSeekable else { return }
        pendingSeek = target
        pendingSeekStarted = Date()
        resumePoint = target
        noDataSeconds = 0
        // 只有用户自己暂停时，跳转后才停在新位置；正在缓冲不算暂停
        pauseAfterSeek = userPaused
        player.time = VLCTime(int: Int32(clamping: Int(target * 1000)))
        currentTime = target
        // HLS needs a decoded frame at the requested time before it can pause again.
        if pauseAfterSeek { player.play() }
    }

    // MARK: 自动重连

    /// 停掉卡住的连接，换（新）地址从原位置重新打开。90 秒内最多自动试 3 次，之后提示用户点重试。
    private func recover(reason: String) {
        guard let url = currentURL, recoveryTask == nil else { return }
        let now = Date()
        recoveryAttempts = recoveryAttempts.filter { now.timeIntervalSince($0) < 90 }
        guard recoveryAttempts.count < 3 else {
            player.stop()
            giveUp(reason.isEmpty ? "网络连接中断" : reason)
            return
        }
        recoveryAttempts.append(now)
        let position = resumePoint
        let refresher = urlRefresher
        let direct115 = currentDirect115
        let cookie = currentCookie
        let currentSession = session
        openTimeoutTask?.cancel()
        statusNote = reason.isEmpty ? "正在重新连接…" : "\(reason)，正在重新连接…"
        stalled = false
        // 先停掉卡住的连接：VLC 读网络没有超时，不停掉它会一直等下去
        player.stop()
        recoveryTask = Task { @MainActor [weak self] in
            var target = url
            if let refresher, let fresh = try? await refresher() { target = fresh }
            guard let self, !Task.isCancelled, self.session == currentSession else { return }
            self.recoveryTask = nil
            self.start(target, direct115: direct115, cookie: cookie, position: position, keepPlaying: !self.userPaused, keepDuration: true)
        }
        refresh()
    }

    private func giveUp(_ reason: String) {
        openTimeoutTask?.cancel()
        recoveryTask?.cancel()
        recoveryTask = nil
        stalled = false
        buffering = false
        statusNote = ""
        let position = Self.clock(resumePoint)
        error = resumePoint > 1
            ? "\(reason)，自动重连几次都没成功。点「重试」会从 \(position) 接着播放。"
            : "\(reason)，请点「重试」，或换一个画质。"
    }

    /// 出错提示里的「重试」：从原位置重新打开（会先换新地址）
    var canRetryInPlace: Bool { currentURL != nil }

    func retry() {
        recoveryAttempts = []
        error = ""
        userPaused = false
        recover(reason: "")
    }

    /// 每秒检查一次播放是不是卡死了。
    ///
    /// 直接读文件（115 原画、MP4/MKV）时，VLC 的统计能看到读了多少字节，几秒一个字节都没有就是连接卡死；
    /// HLS 分片是另开连接下载的，统计里看不到，只能按「时间多久没走」判断，所以要等得久一些。
    private func checkHealth(readBytes delta: Int, bytesVisible: Bool, timeAdvanced: Bool) {
        let progressed = bytesVisible ? delta > 0 : (delta > 0 || timeAdvanced)
        noDataSeconds = progressed ? 0 : noDataSeconds + 1
        let seekLimit = bytesVisible ? 5 : 15
        let stallLimit = bytesVisible ? 8 : 20
        let state = player.state
        badStateSeconds = (state == .ended || state == .error || state == .stopped) ? badStateSeconds + 1 : 0
        guard watchdogEnabled, recoveryTask == nil, currentURL != nil, error.isEmpty, !userPaused else { return }
        // 没到结尾却停了、或者出错了：连接断了
        if badStateSeconds >= 2 {
            let reachedEnd = state == .ended && duration > 0 && resumePoint >= duration - 5
            if !reachedEnd { recover(reason: state == .error ? "播放出错" : "网络连接断了") }
            return
        }
        // 跳转后迟迟没有数据进来
        if pendingSeek != nil, Date().timeIntervalSince(pendingSeekStarted) >= Double(seekLimit + 2), noDataSeconds >= seekLimit {
            recover(reason: "跳转后网络没有响应")
            return
        }
        // 播放中卡住，而且一直没有数据进来
        if hasPlayed, buffering, noDataSeconds >= stallLimit {
            recover(reason: "网络卡住了")
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
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
        open(url, direct115: currentDirect115, directCookie: currentCookie, preservingPosition: true, refreshURL: urlRefresher, autoRecover: watchdogEnabled, openTimeoutSeconds: openTimeoutSeconds)
    }

    /// 切换提前缓存时长：记住选择，从当前位置重新打开当前视频
    func setPrebuffer(_ value: PrebufferLevel) {
        guard value != prebuffer else { return }
        prebuffer = value
        PrebufferLevel.saved = value
        guard let url = currentURL else { return }
        open(url, direct115: currentDirect115, directCookie: currentCookie, preservingPosition: true, refreshURL: urlRefresher, autoRecover: watchdogEnabled, openTimeoutSeconds: openTimeoutSeconds)
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
        // 统计是 32 位整数，读过 2GB 会绕回负数，所以一旦看到过有效的字节数就一直认为能看到
        if bytes > 2_000_000 { bytesVisible = true }
        let time = player.time.intValue
        checkHealth(readBytes: delta, bytesVisible: bytesVisible, timeAdvanced: time != lastSampledTime)
        guard recoveryTask == nil else { return }

        // VLC 播放中途缓存见底时，状态仍是「正在播放」，只是时间不走了。
        // 正在播放、时间却一秒没动，就算卡住了，画面中间转圈并显示网速。
        let state = player.state
        let active = state != .paused && state != .ended && state != .stopped && state != .error
        // 跳转后时间迟迟不动也算卡住，这样跳转等待时也会转圈并显示网速
        let stuck = !userPaused && active && time == lastSampledTime && (time > 0 || pendingSeek != nil) && hasPlayed
        lastSampledTime = time
        if stuck != stalled {
            stalled = stuck
            updateBuffering()
        }
    }

    private func updateBuffering() {
        let state = player.state
        let value = recoveryTask != nil || stalled || (!player.isPlaying && (state == .opening || state == .buffering))
        if value != buffering { buffering = value }
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
        session += 1
        recoveryTask?.cancel()
        recoveryTask = nil
        statusNote = ""
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
        // VLCKit 的 state 收到一次缓冲事件后会一直停在 .buffering（之后不再发 .playing），
        // 所以「真的在播」以内核的 isPlaying 为准
        if state == .playing || player.isPlaying { hasPlayed = true }
        let halted = state == .ended || state == .error || state == .stopped
        // 「在播放」按用户意图算：没按暂停、没卡在结束或出错上就是在播放；网络缓冲、自动重连时按钮不会跳成播放键
        playing = !userPaused && (recoveryTask != nil || (!halted && player.media != nil))
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
            if !landed, gaveUp, watchdogEnabled, recoveryTask == nil, abs(decodedTime - pendingSeek) > 20 {
                // 跳转根本没生效（例如服务器拒绝了跳转用的新连接，还在按原来的位置播）：从目标位置重新打开
                self.pendingSeek = nil
                recover(reason: "跳转没有成功")
                return
            }
            if landed || gaveUp {
                self.pendingSeek = nil
                currentTime = decodedTime
                if pauseAfterSeek { pauseAfterSeek = false; player.pause() }
            }
        } else if !halted && recoveryTask == nil {
            // 连接断掉、重连时 VLC 的时间会归零，这时保留最后的进度
            currentTime = decodedTime
        }
        if pendingSeek == nil, player.isPlaying, !halted, decodedTime > 0 { resumePoint = decodedTime }
        if player.isPlaying, pendingSeek == nil, !stalled, !statusNote.isEmpty { statusNote = "" }
        let length = Double(player.media?.length.intValue ?? 0) / 1000
        if length.isFinite && length > 0 { duration = length }
        // 同样不能等 state == .playing：缓冲事件一来它就变了，续播的跳转可能永远等不到
        if let resumeTime, player.isPlaying, player.isSeekable {
            player.time = VLCTime(int: resumeTime)
            self.resumeTime = nil
        }
        if state == .ended, duration > 0, resumePoint >= duration - 5 {
            ended = true
        } else if player.isPlaying || state == .opening {
            ended = false
        }
        if player.isPlaying {
            let targetRate: Float = boosted ? Self.boostRate : rate
            if abs(player.rate - targetRate) > 0.01 { player.rate = targetRate }
            if shouldPauseAfterOpening { shouldPauseAfterOpening = false; player.pause() }
        }
        if state == .error, !watchdogEnabled, error.isEmpty, recoveryTask == nil {
            // 不自动重连的来源（磁力边下边播）直接提示；其余的交给每秒的检查去重连
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
