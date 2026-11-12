import AVFoundation
import Foundation
import Libmpv
import Network
import Photos
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

/// 边播边存：打开后攒够一点点就开播，播放过程中在后台往前多下载这么长时间的视频。
/// 存在手机存储里（不占内存），最多 2GB；退出播放器或换集时自动清掉。
enum ReadaheadLevel: Int, CaseIterable, Identifiable {
    case oneMinute = 60
    case fiveMinutes = 300
    case tenMinutes = 600

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .oneMinute: return "1 分钟"
        case .fiveMinutes: return "5 分钟"
        case .tenMinutes: return "10 分钟"
        }
    }

    private static let key = "player.readaheadSeconds"

    static var saved: ReadaheadLevel {
        get { ReadaheadLevel(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .tenMinutes }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// 字幕样式：经典（半透明黑底）、大字（黑底放大）、描边（默认，和以前一样）、透明底（只有柔和阴影）。
/// SRT 这类纯文字字幕完全按样式显示；ASS 特效字幕保留自带的样式，只跟着「大字」放大。
enum SubtitleStyle: String, CaseIterable, Identifiable {
    case classic, large, outline, soft

    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: return "经典"
        case .large: return "大字"
        case .outline: return "描边"
        case .soft: return "透明底"
        }
    }

    private static let key = "player.subtitleStyle"

    static var saved: SubtitleStyle {
        get { SubtitleStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .outline }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// 样式会改到的 mpv 字幕选项。没写到的项用内核默认值，所以「描边」就是原来的样子
    static let optionKeys = ["sub-border-style", "sub-outline-size", "sub-outline-color", "sub-shadow-offset",
                             "sub-back-color", "sub-blur", "sub-scale"]

    /// 和内核默认值不同的那几项（颜色是 #AARRGGBB）
    var overrides: [String: String] {
        switch self {
        case .classic:
            // 把描边画成紧贴每行文字的半透明黑框
            return ["sub-border-style": "opaque-box", "sub-outline-size": "3", "sub-outline-color": "#A0000000",
                    "sub-shadow-offset": "0"]
        case .large:
            return ["sub-border-style": "opaque-box", "sub-outline-size": "3", "sub-outline-color": "#A0000000",
                    "sub-shadow-offset": "0", "sub-scale": "1.3"]
        case .outline:
            return [:]
        case .soft:
            // 不描边，只留一圈柔和的投影
            return ["sub-outline-size": "0", "sub-shadow-offset": "2", "sub-back-color": "#B4000000", "sub-blur": "0.6"]
        }
    }
}

/// 画面比例
enum VideoAspect: String, CaseIterable, Identifiable {
    case fit, fill, stretch, ratio16x9, ratio4x3, ratio235

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fit: return "适应"
        case .fill: return "铺满裁切"
        case .stretch: return "拉伸"
        case .ratio16x9: return "16:9"
        case .ratio4x3: return "4:3"
        case .ratio235: return "2.35"
        }
    }
    var subtitle: String? {
        switch self {
        case .ratio16x9, .ratio4x3: return "强制"
        case .ratio235: return "宽银幕"
        default: return nil
        }
    }
}

/// 一条音轨或字幕
struct MediaTrack: Identifiable, Hashable {
    let id: Int
    let title: String
    let detail: String
    let external: Bool
}

/// 播放控制：统一使用 mpv（MPVKit）内核，界面由 HPlayer 自己绘制。
@MainActor
final class PlaybackController: ObservableObject {
    /// 长按快进的倍速
    static let boostRate: Float = 3

    @Published private(set) var playing = false
    @Published private(set) var buffering = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var seekable = false
    /// 已经缓存到的播放位置（秒），进度条上的浅色段
    @Published private(set) var bufferedUntil: Double = 0
    /// 当前位置往后已经缓存了多少秒
    @Published private(set) var cachedSeconds: Double = 0
    /// 下载速度（字节/秒）
    @Published private(set) var downloadSpeed: Double = 0
    @Published private(set) var muted = false
    @Published private(set) var error = ""
    /// 真的播放到了结尾（用于自动播放下一集）
    @Published private(set) var ended = false
    @Published private(set) var rate: Float = 1
    /// Includes temporary/adaptive long-press acceleration; `rate` remains the user's setting.
    @Published private(set) var effectiveRate: Float = 1
    /// Sampled once a second, without refreshing the entire UI for each decoded frame.
    private(set) var avSync: Double?
    private(set) var boostAVSyncPeak: Double?
    @Published private(set) var decoding = VideoDecoding.saved
    @Published private(set) var readahead = ReadaheadLevel.saved
    @Published private(set) var subtitleStyle = SubtitleStyle.saved
    /// 内核刚建好时字幕选项的默认值，切回「描边」或某项没被样式改到时用它还原
    private var subtitleDefaults: [String: String] = [:]
    @Published private(set) var aspect: VideoAspect = .fit
    /// 画面缩放，1 = 原始大小
    @Published private(set) var zoom: Double = 1
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subtitleTracks: [MediaTrack] = []
    @Published private(set) var selectedAudio: Int?
    @Published private(set) var selectedSubtitle: Int?
    /// 例如「4K · HDR」
    @Published private(set) var videoBadges: [String] = []
    /// 自动重连时画面中间显示的说明
    @Published private(set) var statusNote = ""
    /// 出错时内核给出的具体原因（技术信息，小字显示在错误提示下面）
    @Published private(set) var errorDetail = ""
    /// 需要在画面上方短暂提示的一句话，显示后由界面清空
    @Published var notice = ""
    /// 内核报告的真实播放时间（不含正在跳转的目标），给 UI 测试读。
    /// 它每一帧都在变：不能用 @Published，否则整个播放页（连同下面的信息页、选集）会跟着视频帧率
    /// 每秒重算几十次，CPU 一直闲不下来，长时间播放手机发烫。变化超过 0.25 秒才通知界面刷新一次。
    private(set) var engineTime: Double = 0 {
        didSet {
            guard abs(engineTime - notifiedEngineTime) >= 0.25 || engineTime < notifiedEngineTime else { return }
            notifiedEngineTime = engineTime
            objectWillChange.send()
        }
    }
    private var notifiedEngineTime = -1.0
    /// 内核当前缓存了多少秒（原值）；界面上的 cachedSeconds 只在变化超过半秒时才更新
    private var rawCachedSeconds: Double = 0
    /// 内核实际用的解码方式：videotoolbox 是硬解码，no 是软解码；视频解码器还没起来时为空
    private var activeHwdec = ""
    /// 这个视频已经提示过「不支持硬解码、改用软解码」
    private var softwareFallbackNoticed = false
    /// Only a confirmed playback position may be written to viewing history.
    private(set) var confirmedTime: Double?

    private var engine: MPVEngine?
    private weak var layer: CAMetalLayer?
    private var pendingOpen: (() -> Void)?
    /// 内核正在后台创建
    private var creatingEngine = false
    /// 播放控制器创建的时间（点封面后播放页开始出现的时刻），诊断信息里用来对「出画面花了多久」
    private let createdAt = Date()

    private var currentURL: URL?
    private var currentDirect115 = false
    private var currentCookie = ""
    private var currentCustomHeaders: [String: String] = [:]
    private var urlRefresher: (() async throws -> URL)?
    private var watchdogEnabled = true
    private var openTimeoutSeconds: UInt64 = 45
    /// 这次 open 之后有没有真正播出来过（自动重连不清零）
    private var playedThisSession = false

    /// 用户自己按了暂停
    private var userPaused = false
    /// Prevent late asynchronous opens from restarting audio while closing.
    private var closingPlayback = false
    private var boosted = false
    private var boostDesyncSince: TimeInterval?
    private var lastBoostReduction = -Double.infinity
    private var loaded = false
    private var opening = false
    private var pausedForCache = false
    private var seeking = false
    private var eofReached = false
    private var hasPlayed = false
    private var pendingSeek: Double?
    private var pendingSeekStarted = Date.distantPast
    /// A requested position is not confirmed until mpv has restarted playback for the seek.
    private var seekAwaitingRestart = false
    private var seekObservedTime: Double?
    private var seekUsesKeyframes = false
    /// An EOF reported while seeking can belong to the previous position.
    private var eofDuringSeek = false
    private var resumePoint: Double = 0
    private var lastConfirmedUptime: TimeInterval?
    private var discardedPlaybackPosition = false
    private var videoWidth: Int64 = 0
    private var videoHeight: Int64 = 0
    private var hdr = false

    /// 内核最近的警告和错误
    private var logLines: [String] = []
    /// 最近的播放事件（打开、跳转、播到结尾、重连），和内核日志一起放进诊断信息
    private var eventLines: [String] = []
    private static let eventClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    private var openTimeoutTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var addressTask: Task<Void, Never>?
    private var addressGeneration = 0
    private var recoveryAttempts: [Date] = []
    private var noDataSeconds = 0
    /// 上一次看门狗检查之后有没有新数据进缓存。读卡死时内核的下载线程堵在网络读取里，
    /// 不会再把下载速度更新成 0，所以不能只看 downloadSpeed，要看有没有新的数据事件
    private var dataSinceTick = false
    private var session = 0
    private var lastPublishedTime = -1.0
    private var backgroundObservers: [NSObjectProtocol] = []
    private let network = NWPathMonitor()
    private var expensiveNetwork = false

    init() {
        network.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive
            Task { @MainActor [weak self] in self?.expensiveNetwork = expensive }
        }
        network.start(queue: DispatchQueue(label: "app.hplayer.network"))
        backgroundObservers = [
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                // 退到后台时只留声音，回来再打开画面，避免回到前台画面变黑
                Task { @MainActor [weak self] in self?.engine?.set("vid", "no") }
            },
            NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.engine?.set("vid", "auto") }
            },
        ]
        // 清理上次没清掉的缓存文件、量一下能用多少空间：都要访问磁盘，放到后台做，不挡着播放页出现
        PlayerDiskCache.prepare()
    }

    deinit {
        network.cancel()
        backgroundObservers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: 画面

    /// 播放画面所在的图层准备好了。第一次时创建内核。
    ///
    /// 创建内核（mpv_create / mpv_initialize）要几十到上百毫秒。如果在这里同步做，
    /// 点封面之后播放页要等它做完才出得来，所以放到后台线程去建，页面先出现；
    /// 建好之后回到主线程接上，这期间要打开的视频先记在 pendingOpen 里，内核一就绪就接着打开。
    func attach(layer: CAMetalLayer) {
        self.layer = layer
        if let engine {
            engine.attach(layer: layer)
            runPendingOpen()
        } else {
            createEngineInBackground(layer: layer)
        }
    }

    private func runPendingOpen() {
        guard let pendingOpen else { return }
        self.pendingOpen = nil
        pendingOpen()
    }

    private func createEngineInBackground(layer: CAMetalLayer) {
        guard !creatingEngine else { return }
        creatingEngine = true
        let options = engineOptions()
        let began = Date()
        PlayerDiskCache.queue.async { [weak self] in
            let created = MPVEngine(options: options, layer: layer)
            Task { @MainActor [weak self] in
                self?.engineDidCreate(created, layer: layer, began: began)
            }
        }
    }

    private func engineDidCreate(_ created: MPVEngine?, layer: CAMetalLayer, began: Date) {
        creatingEngine = false
        guard let created else {
            error = "播放内核启动失败"
            return
        }
        created.onEvent = { [weak self] event in self?.handle(event) }
        for (name, format) in Self.observed {
            created.observe(name, format)
        }
        engine = created
        applySubtitleStyle(created)
        logEvent("播放内核就绪（创建用了 \(Self.milliseconds(since: began)) 毫秒，距播放页创建 \(Self.milliseconds(since: createdAt)) 毫秒）")
        // 创建期间页面换了图层（很少见）：把现在的图层交给内核
        if let current = self.layer, current !== layer { created.attach(layer: current) }
        runPendingOpen()
    }

    private static func milliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    /// 创建内核时的选项（要在主线程读屏幕信息，所以在这里先备好，再交给后台线程）
    private func engineOptions() -> [(String, String)] {
        var options: [(String, String)] = [
            ("config", "no"),
            ("load-scripts", "no"),
            ("ytdl", "no"),
            ("input-default-bindings", "no"),
            ("idle", "yes"),
            ("keep-open", "yes"),
            // EOF must not turn an interrupted seek into a user pause and disable recovery.
            // HPlayer owns pause/replay and decides whether an EOF is a real ending.
            ("keep-open-pause", "no"),
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", decoding == .hardware ? "videotoolbox" : "no"),
            ("video-sync", "audio"),
            ("framedrop", "vo"),
            // 画面处理用 mpv 给低功耗设备准备的省电档（内置的 fast 档，只保留抖动）。mpv 的默认值是给电脑显卡的：
            // lanczos 放大再加 sigmoid、线性光 + 抗锯齿缩小、每帧算 HDR 峰值，一帧要跑好几遍全屏着色器，
            // 手机 GPU 长时间满负荷就会发烫。手机屏幕像素很密，换成双线性看不出区别，GPU 的活少一大截。
            ("scale", "bilinear"),
            ("dscale", "bilinear"),
            ("correct-downscaling", "no"),
            ("linear-downscaling", "no"),
            ("sigmoid-upscaling", "no"),
            ("hdr-compute-peak", "no"),
            ("video-rotate", "no"),
            ("audio-display", "no"),
            ("sub-auto", "fuzzy"),
            ("subs-fallback", "yes"),
            ("slang", "zh,chi,zho,chs,sc,cht,tc,en,eng"),
            ("screenshot-format", "jpg"),
            // 网络：115 的冷门文件第一次读可能要等十几秒，给足 30 秒；真卡死由看门狗换地址重连
            ("network-timeout", "30"),
            ("stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=4"),
            // 边播边存：开头不等缓存，攒到一点就播；卡住时攒够 3 秒再继续，免得一顿一顿
            ("cache", "yes"),
            ("cache-pause", "yes"),
            ("cache-pause-initial", "no"),
            // 卡住后攒够 1 秒就接着播，不要等太久
            ("cache-pause-wait", "1"),
            // 打开时少探测一点格式信息，网络视频更快出画面
            ("demuxer-lavf-analyzeduration", "1"),
            ("demuxer-lavf-probesize", "4194304"),
            // 续播和大跨度跳转只落到关键帧，4K 原画不用从关键帧一路解码到目标；小跳转单独要求精确
            ("hr-seek", "no"),
            ("cache-on-disk", "yes"),
            ("demuxer-cache-dir", PlayerDiskCache.directory.path),
            ("demuxer-max-back-bytes", "256MiB"),
        ]
        if UIScreen.main.potentialEDRHeadroom > 1 {
            options.append(("target-colorspace-hint", "yes"))
        }
        return options
    }

    private static let observed: [(String, mpv_format)] = [
        ("time-pos", MPV_FORMAT_DOUBLE),
        ("duration", MPV_FORMAT_DOUBLE),
        ("pause", MPV_FORMAT_FLAG),
        ("paused-for-cache", MPV_FORMAT_FLAG),
        ("seeking", MPV_FORMAT_FLAG),
        ("eof-reached", MPV_FORMAT_FLAG),
        ("seekable", MPV_FORMAT_FLAG),
        ("demuxer-cache-time", MPV_FORMAT_DOUBLE),
        ("demuxer-cache-duration", MPV_FORMAT_DOUBLE),
        ("cache-speed", MPV_FORMAT_INT64),
        ("track-list/count", MPV_FORMAT_INT64),
        ("aid", MPV_FORMAT_STRING),
        ("sid", MPV_FORMAT_STRING),
        ("video-params/h", MPV_FORMAT_INT64),
        ("video-params/w", MPV_FORMAT_INT64),
        ("video-params/sig-peak", MPV_FORMAT_DOUBLE),
        ("mute", MPV_FORMAT_FLAG),
        ("hwdec-current", MPV_FORMAT_STRING),
    ]

    // MARK: 打开

    func open(
        _ url: URL,
        direct115: Bool = false,
        directCookie: String = "",
        customHeaders: [String: String] = [:],
        preservingPosition: Bool = false,
        startTime: Double? = nil,
        refreshURL: (() async throws -> URL)? = nil,
        autoRecover: Bool = true,
        openTimeoutSeconds: UInt64 = 45
    ) {
        guard !closingPlayback else { return }
        session += 1
        if !preservingPosition {
            playedThisSession = false
            softwareFallbackNoticed = false
        }
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryAttempts = []
        statusNote = ""
        urlRefresher = refreshURL
        watchdogEnabled = autoRecover
        self.openTimeoutSeconds = openTimeoutSeconds
        let position = preservingPosition ? resumePoint : max(0, startTime ?? 0)
        let keepPlaying = preservingPosition ? !userPaused : true
        if !preservingPosition {
            aspect = .fit
            zoom = 1
        }
        start(url, direct115: direct115, cookie: directCookie, customHeaders: customHeaders, position: position, keepPlaying: keepPlaying, keepDuration: preservingPosition)
    }

    private func start(_ url: URL, direct115: Bool, cookie: String, customHeaders: [String: String] = [:], position: Double, keepPlaying: Bool, keepDuration: Bool) {
        guard !closingPlayback else { return }
        cancelAddressResolution()
        logEvent("打开 \(url.host ?? url.lastPathComponent)，从 \(Self.clock(position))（距播放页创建 \(Self.milliseconds(since: createdAt)) 毫秒）")
        currentURL = url
        currentDirect115 = direct115
        currentCookie = cookie
        currentCustomHeaders = customHeaders
        resetState(keepDuration: keepDuration)
        resumePoint = position
        errorDetail = ""
        if position > 0 {
            currentTime = position
            pendingSeek = position
            pendingSeekStarted = Date()
            seekAwaitingRestart = true
            seekUsesKeyframes = true
        }
        userPaused = !keepPlaying
        playing = keepPlaying
        buffering = true
        opening = true
        guard let engine else {
            // 画面还没准备好：等图层交过来再打开
            pendingOpen = { [weak self] in
                self?.start(url, direct115: direct115, cookie: cookie, customHeaders: customHeaders, position: position, keepPlaying: keepPlaying, keepDuration: keepDuration)
            }
            return
        }
        // 激活音频会话要和系统音频服务通信，可能阻塞，放到后台做（内核自己打开音频输出时也会再确认一次）
        PlayerAudioSession.activate()

        engine.set("hwdec", decoding == .hardware ? "videotoolbox" : "no")
        applyCacheOptions(engine)
        engine.set("hls-bitrate", "max")
        if let ua = customHeaders["User-Agent"] {
            engine.set("user-agent", ua)
        } else {
            engine.set("user-agent", direct115 ? Direct115Client.userAgent : "HPlayer")
        }
        if let ref = customHeaders["Referer"] {
            engine.set("referrer", ref)
        } else {
            engine.set("referrer", direct115 ? "https://115.com/" : "")
        }
        let cookieHeader = Self.cookieHeader(cookie)
        engine.set("http-header-fields", direct115 && !cookieHeader.isEmpty ? "Cookie: \(cookieHeader.replacingOccurrences(of: ",", with: "%2C"))" : "")
        engine.set("start", position > 0 ? String(format: "%.3f", position) : "none")
        engine.set("pause", !keepPlaying)
        engine.set("speed", Double(rate))
        applyAspect(engine)
        let currentSession = session
        let generation = addressGeneration
        let renew = urlRefresher
        addressTask = Task { @MainActor [weak self, weak engine] in
            let address = await Self.engineAddress(for: url, direct115: direct115, cookieHeader: cookieHeader,
                                                   customHeaders: customHeaders, renew: renew)
            guard let self, let engine, !Task.isCancelled, !self.closingPlayback,
                  self.session == currentSession, self.addressGeneration == generation,
                  self.engine === engine else { return }
            self.addressTask = nil
            engine.command(["loadfile", address, "replace"])
        }
        startWatchdog()

        let timeout = openTimeoutSeconds
        openTimeoutTask?.cancel()
        openTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
            guard let self, !Task.isCancelled, self.session == currentSession, !self.loaded, self.error.isEmpty else { return }
            if self.watchdogEnabled {
                self.recover(reason: "视频加载超时")
            } else {
                self.engine?.command(["stop"])
                self.giveUp("视频加载超时")
            }
        }
    }

    private func cancelAddressResolution() {
        addressGeneration &+= 1
        addressTask?.cancel()
        addressTask = nil
    }

    private func resetState(keepDuration: Bool) {
        openTimeoutTask?.cancel()
        pendingSeek = nil
        seekAwaitingRestart = false
        seekObservedTime = nil
        seekUsesKeyframes = false
        eofDuringSeek = false
        boosted = false
        boostDesyncSince = nil
        lastBoostReduction = -Double.infinity
        effectiveRate = rate
        avSync = nil
        boostAVSyncPeak = nil
        lastConfirmedUptime = nil
        discardedPlaybackPosition = false
        loaded = false
        hasPlayed = false
        pausedForCache = false
        seeking = false
        eofReached = false
        ended = false
        error = ""
        noDataSeconds = 0
        seekable = false
        bufferedUntil = 0
        cachedSeconds = 0
        rawCachedSeconds = 0
        downloadSpeed = 0
        lastPublishedTime = -1
        notifiedEngineTime = -1
        activeHwdec = ""
        if !keepDuration {
            duration = 0
            currentTime = 0
            engineTime = 0
            confirmedTime = nil
            audioTracks = []
            subtitleTracks = []
            selectedAudio = nil
            selectedSubtitle = nil
            videoBadges = []
            videoWidth = 0
            videoHeight = 0
            hdr = false
        }
    }

    private func applyCacheOptions(_ engine: MPVEngine) {
        #if DEBUG
        // UI 测试用很小的缓存，让跳转一定要发新的网络请求，才能模拟连接卡死
        if let kb = ProcessInfo.processInfo.environment["HPLAYER_UI_TEST_PREFETCH_KB"].flatMap(Int.init) {
            engine.set("cache-on-disk", false)
            engine.set("demuxer-max-bytes", "\(kb)KiB")
            engine.set("demuxer-max-back-bytes", "0")
            engine.set("demuxer-readahead-secs", "2")
            engine.set("cache-secs", "2")
            return
        }
        #endif
        // 用手机流量时最多只往前存 1 分钟，免得白白多下
        let seconds = expensiveNetwork ? min(readahead.rawValue, ReadaheadLevel.oneMinute.rawValue) : readahead.rawValue
        engine.set("demuxer-readahead-secs", "\(seconds)")
        engine.set("cache-secs", "\(seconds)")
        engine.set("demuxer-max-bytes", "\(PlayerDiskCache.limitMiB())MiB")
    }

    // MARK: 播放控制

    /// Pause immediately when closing without discarding the current position.
    /// This also covers loading/buffering: a pending recovery must not resume audio
    /// while the portrait transition is in progress.
    func pauseForClose() {
        closingPlayback = true
        userPaused = true
        pendingOpen = nil
        cancelAddressResolution()
        openTimeoutTask?.cancel()
        engine?.set("pause", true)
        updateFlags()
    }

    /// Magnet playback can reuse its controller for the next presentation.
    func prepareForPresentation() { closingPlayback = false }

    func toggle() {
        guard !closingPlayback, currentURL != nil else { return }
        if ended || (!playing && eofReached) {
            // A genuine ending replays from zero; an interrupted seek resumes its
            // latest target. seek also reloads the file if mpv has already closed it.
            let target = ended ? 0 : (pendingSeek ?? resumePoint)
            userPaused = false
            seek(to: target)
            return
        }
        if playing {
            userPaused = true
            engine?.set("pause", true)
        } else {
            userPaused = false
            noDataSeconds = 0
            if !loaded, recoveryTask == nil, !opening || !error.isEmpty {
                // 连接断了停在那里：从停下的位置重新打开
                recoveryAttempts = []
                recover(reason: "")
            } else {
                engine?.set("pause", false)
            }
        }
        updateFlags()
    }

    func seek(to seconds: Double) {
        guard !closingPlayback, currentURL != nil, seconds.isFinite, seconds >= 0 else { return }
        guard seekable || recoveryTask != nil || (!loaded && !opening) else { return }
        let target = duration > 0 ? min(seconds, max(0, duration - 1)) : seconds
        logEvent("跳转 \(Self.clock(engineTime)) → \(Self.clock(target))（总长 \(Self.clock(duration))）")
        resumePoint = target
        currentTime = target
        if ended {
            // 播到结尾停住以后再往回拖：接着播，不要停在那里
            userPaused = false
        }
        ended = false
        eofReached = false
        eofDuringSeek = false
        if recoveryTask != nil || (!loaded && !opening) {
            // 连接已经断了或正在重连：直接从新的目标位置重新打开
            recoveryTask?.cancel()
            recoveryTask = nil
            recoveryAttempts = []
            pendingSeek = target
            pendingSeekStarted = Date()
            seekAwaitingRestart = true
            seekObservedTime = nil
            recover(reason: "")
            return
        }
        pendingSeek = target
        pendingSeekStarted = Date()
        seekAwaitingRestart = true
        seekObservedTime = nil
        noDataSeconds = 0
        // Keep fast keyframe seeks away from the tail: sparse indexes can snap
        // past the requested position and immediately hit EOF.
        let far = abs(target - engineTime) > 60 && (duration <= 0 || target < duration - 30)
        seekUsesKeyframes = far
        let result = engine?.command(["seek", String(format: "%.3f", target), far ? "absolute+keyframes" : "absolute+exact"])
        engine?.set("pause", userPaused)
        if let result, result < 0 {
            if watchdogEnabled {
                recover(reason: "跳转没有成功")
            } else {
                giveUp("跳转没有成功，请重试")
            }
            return
        }
        #if DEBUG
        if !injectedStaleEOFForUITest,
           ProcessInfo.processInfo.environment["HPLAYER_UI_TEST_STALE_EOF_ON_SEEK"] == "1", duration > 5 {
            injectedStaleEOFForUITest = true
            handle(.property("time-pos", .double(duration - 1)))
            handle(.property("pause", .flag(true)))
            handle(.property("eof-reached", .flag(true)))
        }
        #endif
        updateFlags()
    }

    #if DEBUG
    private var injectedStaleEOFForUITest = false

    func receiveEventForTesting(_ event: MPVEngine.Event) { handle(event) }

    func checkBoostSyncForTesting(_ avSync: Double?, at uptime: TimeInterval) {
        checkBoostSync(avSync, at: uptime)
    }

    func checkHealthForTesting() { checkHealth() }
    #endif

    func skip(_ seconds: Double) { seek(to: max(0, currentTime + seconds)) }

    func setRate(_ value: Float) {
        rate = value
        if !boosted { applyRate(value) }
    }

    /// 长按临时加速；高负载时降低倍速，松手恢复用户设置（mpv 自动保持音调）。
    func setBoost(_ enabled: Bool) {
        guard boosted != enabled else { return }
        boosted = enabled
        boostDesyncSince = nil
        lastBoostReduction = -Double.infinity
        if enabled { boostAVSyncPeak = nil }
        applyRate(enabled ? preferredBoostRate : rate)
    }

    /// 4K at 3× can exceed the hardware decoder's throughput. Start at 2× and
    /// lower only the temporary speed if sustained A/V drift shows it still cannot keep up.
    private var preferredBoostRate: Float {
        videoWidth >= 3840 || videoHeight >= 2160 || activeHwdec == "no" ? 2 : Self.boostRate
    }

    private func applyRate(_ value: Float) {
        if effectiveRate != value { effectiveRate = value }
        engine?.set("speed", Double(value))
    }

    private func limitBoostForVideo() {
        if boosted, effectiveRate > preferredBoostRate { applyRate(preferredBoostRate) }
    }

    private func checkBoostSync(_ avSync: Double?, at uptime: TimeInterval) {
        guard boosted, loaded, !userPaused, !pausedForCache, !seeking, pendingSeek == nil,
              !eofReached, error.isEmpty, let avSync, avSync.isFinite else {
            boostDesyncSince = nil
            return
        }
        boostAVSyncPeak = max(boostAVSyncPeak ?? 0, abs(avSync))
        guard abs(avSync) > 0.2 else {
            boostDesyncSince = nil
            return
        }
        guard let since = boostDesyncSince else {
            boostDesyncSince = uptime
            return
        }
        guard uptime - since >= 1, uptime - lastBoostReduction >= 2, effectiveRate > 1 else { return }
        applyRate(max(1, effectiveRate - 0.5))
        boostDesyncSince = nil
        lastBoostReduction = uptime
        logEvent("长按快进调整到 \(effectiveRate)×，保持音画同步")
    }

    func toggleMute() { setMuted(!muted) }

    func setMuted(_ value: Bool) {
        muted = value
        engine?.set("mute", value)
    }

    /// 拿不到系统音量控制时（例如模拟器）才使用播放器自己的软件音量
    func setSoftwareVolume(_ normalized: Double) {
        engine?.set("volume", min(max(normalized, 0), 1) * 100)
    }

    func stop(detach: Bool = true) {
        session += 1
        cancelAddressResolution()
        recoveryTask?.cancel()
        recoveryTask = nil
        openTimeoutTask?.cancel()
        watchdogTask?.cancel()
        watchdogTask = nil
        pendingOpen = nil
        statusNote = ""
        engine?.command(["stop"])
        resetState(keepDuration: false)
        playing = false
        buffering = false
        opening = false
        userPaused = false
        currentURL = nil
    }

    // MARK: 设置

    func setDecoding(_ value: VideoDecoding) {
        guard value != decoding else { return }
        decoding = value
        VideoDecoding.saved = value
        reopenInPlace()
    }

    func setReadahead(_ value: ReadaheadLevel) {
        guard value != readahead else { return }
        readahead = value
        ReadaheadLevel.saved = value
        // 缓存长度不用重新打开，直接生效
        if let engine { applyCacheOptions(engine) }
    }

    func setAspect(_ value: VideoAspect) {
        aspect = value
        if let engine { applyAspect(engine) }
    }

    func setSubtitleStyle(_ value: SubtitleStyle) {
        guard value != subtitleStyle else { return }
        subtitleStyle = value
        SubtitleStyle.saved = value
        if let engine { applySubtitleStyle(engine) }
    }

    /// 字幕样式直接改内核属性，正在显示的字幕马上换样子，不用重新打开视频
    private func applySubtitleStyle(_ engine: MPVEngine) {
        if subtitleDefaults.isEmpty {
            for key in SubtitleStyle.optionKeys {
                if let value = engine.string(key) { subtitleDefaults[key] = value }
            }
        }
        let overrides = subtitleStyle.overrides
        for key in SubtitleStyle.optionKeys {
            if let value = overrides[key] ?? subtitleDefaults[key] { engine.set(key, value) }
        }
    }

    func setZoom(_ value: Double) {
        zoom = min(max(value, 1), 3)
        engine?.set("video-zoom", log2(zoom))
    }

    private func applyAspect(_ engine: MPVEngine) {
        engine.set("keepaspect", aspect != .stretch)
        engine.set("panscan", aspect == .fill ? 1.0 : 0.0)
        let override: String
        switch aspect {
        case .ratio16x9: override = "16:9"
        case .ratio4x3: override = "4:3"
        case .ratio235: override = "2.35:1"
        default: override = "-1"
        }
        engine.set("video-aspect-override", override)
        engine.set("video-zoom", log2(zoom))
    }

    func selectAudio(_ id: Int) {
        engine?.set("aid", String(id))
    }

    /// id 为 nil 时关闭字幕
    func selectSubtitle(_ id: Int?) {
        engine?.set("sid", id.map(String.init) ?? "no")
    }

    /// 截一张当前画面，存进相册；返回是否成功
    func screenshot() async -> Bool {
        guard let engine, loaded else { return false }
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited,
              !Task.isCancelled, loaded, self.engine === engine else { return false }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hplayer-shot-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        guard engine.command(["screenshot-to-file", file.path, "video"]) >= 0 else { return false }
        for _ in 0..<20 {
            guard !Task.isCancelled else { return false }
            if let image = UIImage(contentsOfFile: file.path) {
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.creationRequestForAsset(from: image)
                    }
                    return true
                } catch {
                    return false
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private func reopenInPlace() {
        guard let url = currentURL else { return }
        open(url, direct115: currentDirect115, directCookie: currentCookie, preservingPosition: true,
             refreshURL: urlRefresher, autoRecover: watchdogEnabled, openTimeoutSeconds: openTimeoutSeconds)
    }

    // MARK: 内核事件

    private func handle(_ event: MPVEngine.Event) {
        switch event {
        case .property(let name, let value):
            handleProperty(name, value)
        case .startFile:
            opening = true
        case .fileLoaded:
            if !loaded { logEvent("文件已加载（距播放页创建 \(Self.milliseconds(since: createdAt)) 毫秒）") }
            loaded = true
            opening = false
            openTimeoutTask?.cancel()
            refreshTracks()
        case .playbackRestart:
            logEvent(hasPlayed
                ? "开始播放 \(Self.clock(engineTime))"
                : "开始播放 \(Self.clock(engineTime))（出画面，距播放页创建 \(Self.milliseconds(since: createdAt)) 毫秒）")
            hasPlayed = true
            playedThisSession = true
            seekAwaitingRestart = false
            if let observed = seekObservedTime {
                checkFailedSeek(observed)
                settlePendingSeek(at: observed)
            }
            if pendingSeek == nil, eofDuringSeek {
                // Discard an EOF observed for the position we just left.
                eofReached = false
                eofDuringSeek = false
            }
            if !statusNote.isEmpty, recoveryTask == nil { statusNote = "" }
        case .endFile(let reason, let message):
            handleEndFile(reason: reason, message: message)
        case .log(let line):
            logLines.append(line)
            if logLines.count > 60 { logLines.removeFirst(logLines.count - 60) }
        }
        updateFlags()
    }

    private func handleProperty(_ name: String, _ value: MPVEngine.Value) {
        switch (name, value) {
        case ("time-pos", .double(let time)):
            guard time.isFinite, time >= 0 else { return }
            // A failed read/queued event can jump straight to the file tail after
            // seeking clears. It must not become playback history or an actual EOF.
            if pendingSeek == nil, let confirmedTime, let lastConfirmedUptime {
                let elapsed = max(0, ProcessInfo.processInfo.systemUptime - lastConfirmedUptime)
                let nearEnd = duration > 0 && time >= duration - min(1.5, duration * 0.1)
                let advance = max(nearEnd ? 1.5 : 8, elapsed * Double(effectiveRate) + 0.5)
                if time - confirmedTime > advance || time < confirmedTime - 2 {
                    if !discardedPlaybackPosition { logEvent("忽略未播放的位置跳变：\(Self.clock(time))") }
                    discardedPlaybackPosition = true
                    return
                }
            }
            engineTime = time
            if pendingSeek != nil { seekObservedTime = time }
            checkFailedSeek(time)
            settlePendingSeek(at: time)
            if pendingSeek == nil, recoveryTask == nil, !opening {
                if abs(time - lastPublishedTime) >= 0.25 || time < lastPublishedTime {
                    lastPublishedTime = time
                    currentTime = time
                }
                if time > 0 { resumePoint = time }
                confirmPlaybackTime(time)
            }
        case ("duration", .double(let value)):
            if value.isFinite, value > 0 {
                if abs(value - duration) > 1 { logEvent("总时长 \(Self.clock(value))") }
                duration = value
            }
        case ("pause", .flag):
            // Notifications can be queued before a newer toggle/seek, and mpv's
            // keep-open EOF can also pause. Only explicit controls own userPaused.
            break
        case ("paused-for-cache", .flag(let value)):
            if value && !pausedForCache && !seeking { noDataSeconds = 0 }
            pausedForCache = value
            if !value, let observed = seekObservedTime { settlePendingSeek(at: observed) }
        case ("seeking", .flag(let value)):
            if value && !seeking && !pausedForCache { noDataSeconds = 0 }
            seeking = value
            if !value, let observed = seekObservedTime {
                checkFailedSeek(observed)
                settlePendingSeek(at: observed)
            }
        case ("eof-reached", .flag(let value)):
            // Events are delivered to the main queue in batches. A newer seek
            // may already have cleared EOF by the time this notification arrives.
            if value, engine?.flag("eof-reached") == false { return }
            eofReached = value
            if !value { eofDuringSeek = false }
            if value {
                if pendingSeek != nil || seekAwaitingRestart || seeking || opening || recoveryTask != nil {
                    eofDuringSeek = true
                }
                handleReachedEnd()
            }
        case ("seekable", .flag(let value)):
            seekable = value
        case ("demuxer-cache-time", .double(let value)):
            // 进度条上的浅色缓存段：差不到半秒画不出区别，不必每次都让播放页重算
            if value != bufferedUntil, abs(value - bufferedUntil) >= 0.5 || value < bufferedUntil { bufferedUntil = value }
        case ("demuxer-cache-duration", .double(let value)):
            // 看门狗按原值判断有没有新数据进来；界面上「已缓冲 N 秒」变化超过半秒才更新
            if value > rawCachedSeconds + 0.01 { dataSinceTick = true }
            rawCachedSeconds = value
            if abs(value - cachedSeconds) >= 0.5 || (value < 1 && cachedSeconds >= 1) { cachedSeconds = value }
        case ("cache-speed", .int(let value)):
            let speed = Double(max(0, value))
            // 网速显示到小数点后一位，变化不到 5% 看不出来
            if speed != downloadSpeed, speed == 0 || downloadSpeed == 0 || abs(speed - downloadSpeed) >= downloadSpeed * 0.05 {
                downloadSpeed = speed
            }
            if value > 0 { dataSinceTick = true }
        case ("track-list/count", .int):
            refreshTracks()
        case ("aid", .string(let value)):
            selectedAudio = Int(value)
        case ("aid", .none):
            selectedAudio = nil
        case ("sid", .string(let value)):
            selectedSubtitle = Int(value)
        case ("sid", .none):
            selectedSubtitle = nil
        case ("video-params/h", .int(let value)):
            videoHeight = value
            limitBoostForVideo()
            updateBadges()
        case ("video-params/w", .int(let value)):
            videoWidth = value
            limitBoostForVideo()
        case ("video-params/sig-peak", .double(let value)):
            hdr = value > 1
            updateBadges()
        case ("mute", .flag(let value)):
            muted = value
        case ("hwdec-current", .string(let value)):
            guard value != activeHwdec else { return }
            activeHwdec = value
            limitBoostForVideo()
            logEvent(value == "no" ? "解码：软解码（CPU）" : "解码：硬解码（\(value)）")
            if value == "no", decoding == .hardware { warnSoftwareFallback() }
        case ("hwdec-current", .none):
            activeHwdec = ""
        default:
            break
        }
    }

    /// 选的是硬解码，但这个视频的编码手机的视频芯片解不了（例如老的 WMV / RMVB、10bit 的 H.264），
    /// 内核自动退回了 CPU 软解码。软解码比硬解码费电得多，手机会明显发热：每个视频提示一次，让用户知道原因。
    /// 等两秒再确认一次，避开解码器初始化时可能出现的短暂状态。
    private func warnSoftwareFallback() {
        guard !softwareFallbackNoticed else { return }
        let current = session
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.session == current, self.activeHwdec == "no", self.decoding == .hardware,
                  !self.softwareFallbackNoticed, self.error.isEmpty else { return }
            self.softwareFallbackNoticed = true
            self.notice = "这个视频的编码手机不能硬件解码，已改用软解码，会比平时更耗电、发热"
        }
    }

    private func handleReachedEnd() {
        guard duration.isFinite, duration > 0, currentURL != nil, !closingPlayback else { return }
        logEvent("播到结尾：画面 \(Self.clock(engineTime))，位置 \(Self.clock(resumePoint))，总长 \(Self.clock(duration))")
        // resumePoint can be the requested destination, not a position mpv has played.
        guard pendingSeek == nil, !seekAwaitingRestart, !seeking, !opening, recoveryTask == nil else { return }
        let tolerance = min(1.5, duration * 0.1)
        if hasPlayed, !pausedForCache, !discardedPlaybackPosition,
           let confirmedTime, confirmedTime >= duration - tolerance {
            ended = true
        } else if watchdogEnabled, !userPaused {
            // 没到结尾却「播完」了：多半是网络断了，从断开的位置接着连
            recover(reason: "网络连接断了")
        }
    }

    private func handleEndFile(reason: Int32, message: String?) {
        // 2 = 被新的打开或 stop 结束，不算出错
        let stopped = Int32(bitPattern: MPV_END_FILE_REASON_STOP.rawValue)
        let failed = Int32(bitPattern: MPV_END_FILE_REASON_ERROR.rawValue)
        let eof = Int32(bitPattern: MPV_END_FILE_REASON_EOF.rawValue)
        guard reason != stopped else { return }
        // A previous file can finish while the next address is being prepared.
        guard addressTask == nil, !(reason == eof && opening) else { return }
        logEvent("内核结束文件 reason=\(reason)\(message.map { " \($0)" } ?? "")")
        loaded = false
        if reason == failed {
            if watchdogEnabled, currentURL != nil {
                // 这次会话里播出来过（重连后的重新打开也算）就是连接断了，不是「打开失败」
                recover(reason: hasPlayed || playedThisSession ? "网络连接断了" : "视频打开失败")
            } else {
                giveUp(message.map { "播放失败：\($0)" } ?? "播放失败，请尝试其他画质或检查网络")
            }
        } else if reason == eof {
            if pendingSeek != nil || seekAwaitingRestart || seeking || opening {
                if watchdogEnabled, !userPaused {
                    recover(reason: "跳转时连接中断")
                } else if !userPaused {
                    giveUp("跳转未完成，请重试")
                }
            } else {
                eofReached = true
                handleReachedEnd()
            }
        }
    }

    private func settlePendingSeek(at time: Double) {
        guard let pending = pendingSeek, !seekAwaitingRestart, !seeking, !pausedForCache, !eofReached,
              time.isFinite, time >= 0 else { return }
        let offset = time - pending
        // A fast keyframe seek can land before its target. A later old position
        // must not confirm a new seek, especially when it is near the end.
        let nearEnd = duration > 0 && time >= duration - min(1.5, duration * 0.1)
        let reachedTarget = offset > (seekUsesKeyframes ? -30 : -2) && offset < (nearEnd ? 1 : 5)
        guard reachedTarget else { return }
        // The notification batch can lag behind a newer seek/cache transition.
        guard engine?.flag("seeking") != true, engine?.flag("paused-for-cache") != true,
              engine?.flag("eof-reached") != true else { return }
        pendingSeek = nil
        seekObservedTime = nil
        if eofDuringSeek {
            eofReached = false
            eofDuringSeek = false
        }
        if abs(time - lastPublishedTime) >= 0.25 || time < lastPublishedTime {
            lastPublishedTime = time
            currentTime = time
        }
        if time > 0 { resumePoint = time }
        confirmPlaybackTime(time)
    }

    private func confirmPlaybackTime(_ time: Double) {
        guard hasPlayed, !opening, !seeking, !pausedForCache else { return }
        confirmedTime = time
        lastConfirmedUptime = ProcessInfo.processInfo.systemUptime
        discardedPlaybackPosition = false
    }

    /// 跳转根本没生效（例如服务器拒绝了跳转用的新连接，还在按原来的位置播）：从目标位置重新打开
    private func checkFailedSeek(_ time: Double) {
        let tolerance = seekUsesKeyframes ? 30.0 : 20.0
        guard let pending = pendingSeek, !seekAwaitingRestart, watchdogEnabled, recoveryTask == nil, !seeking,
              Date().timeIntervalSince(pendingSeekStarted) > 5, abs(time - pending) > tolerance else { return }
        pendingSeek = nil
        resumePoint = pending
        recover(reason: "跳转没有成功")
    }

    private func updateFlags() {
        let newBuffering = error.isEmpty && !ended && (recoveryTask != nil || opening || pausedForCache
            || ((seeking || pendingSeek != nil) && !userPaused))
        if newBuffering != buffering { buffering = newBuffering }
        let newPlaying = !userPaused && error.isEmpty && !ended
            && (loaded || opening || recoveryTask != nil)
        if newPlaying != playing { playing = newPlaying }
    }

    private func refreshTracks() {
        guard let engine else { return }
        let count = Int(engine.int("track-list/count") ?? 0)
        var audio: [MediaTrack] = []
        var subtitles: [MediaTrack] = []
        for index in 0..<count {
            let prefix = "track-list/\(index)"
            guard let type = engine.string("\(prefix)/type"), let id = engine.int("\(prefix)/id") else { continue }
            let title = engine.string("\(prefix)/title") ?? ""
            let language = engine.string("\(prefix)/lang") ?? ""
            let codec = engine.string("\(prefix)/codec") ?? ""
            let external = engine.flag("\(prefix)/external") ?? false
            let name = Self.trackName(title: title, language: language, fallback: type == "audio" ? "音轨 \(id)" : "字幕 \(id)")
            var details: [String] = []
            if !language.isEmpty, !name.contains(language) { details.append(language) }
            if !codec.isEmpty { details.append(codec.uppercased()) }
            if type == "audio", let channels = engine.int("\(prefix)/demux-channel-count"), channels > 0 {
                details.append(channels == 6 ? "5.1" : channels == 8 ? "7.1" : "\(channels) 声道")
            }
            if external { details.append("外挂") }
            let track = MediaTrack(id: Int(id), title: name, detail: details.joined(separator: " · "), external: external)
            if type == "audio" { audio.append(track) }
            if type == "sub" { subtitles.append(track) }
        }
        audioTracks = audio
        subtitleTracks = subtitles
        selectedAudio = engine.string("aid").flatMap(Int.init)
        selectedSubtitle = engine.string("sid").flatMap(Int.init)
    }

    private func updateBadges() {
        var badges: [String] = []
        if videoHeight >= 2000 { badges.append("4K") }
        else if videoHeight >= 1000 { badges.append("1080P") }
        else if videoHeight >= 700 { badges.append("720P") }
        if hdr { badges.append("HDR") }
        if badges != videoBadges { videoBadges = badges }
    }

    private static func trackName(title: String, language: String, fallback: String) -> String {
        let names = ["chi": "中文", "zho": "中文", "chs": "简体中文", "cht": "繁体中文", "zh": "中文",
                     "eng": "英语", "en": "英语", "jpn": "日语", "ja": "日语", "kor": "韩语", "ko": "韩语"]
        if !title.isEmpty { return title }
        if let name = names[language.lowercased()] { return name }
        return language.isEmpty ? fallback : language
    }

    // MARK: 卡住自动重连
    //
    // FFmpeg 读网络 10 秒没反应会超时并自动重连；这里再加一层：长时间一个字节都没读到、
    // 没到结尾却停了、跳转没生效，就停掉当前连接，换一个新地址（115 能拿到的话）从原位置重新打开。

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.checkHealth()
            }
        }
    }

    private func checkHealth() {
        avSync = loaded ? engine?.double("avsync") : nil
        if boosted { checkBoostSync(avSync, at: ProcessInfo.processInfo.systemUptime) }
        if dataSinceTick {
            noDataSeconds = 0
        } else {
            noDataSeconds += 1
            // 一直没有新数据，界面上的网速也不要停在旧数字上
            if noDataSeconds >= 2, downloadSpeed > 0 { downloadSpeed = 0 }
        }
        dataSinceTick = false
        guard watchdogEnabled, recoveryTask == nil, currentURL != nil, error.isEmpty, !userPaused, loaded, !ended else { return }
        // With keep-open, a failed seek can leave an EOF without end-file, even
        // while the demuxer keeps downloading. Do not wait for a no-data timeout.
        if eofReached, engine?.flag("eof-reached") != false {
            recover(reason: pendingSeek == nil ? "网络连接断了" : "跳转未完成")
            return
        }
        // A failed seek need not leave seeking/cache/EOF set. Retain the pending
        // target until it is confirmed, and recover even when those flags clear.
        if pendingSeek != nil, Date().timeIntervalSince(pendingSeekStarted) >= 7, noDataSeconds >= 5 {
            recover(reason: "跳转后网络没有响应")
            return
        }
        // 卡在缓冲或跳转里、8 秒一个字节都没收到：连接多半已经死了，换地址从原位置接着连
        // 跳转后 mpv 处在「seeking」而不是「paused-for-cache」，两种都算
        if hasPlayed, pausedForCache || seeking, noDataSeconds >= 8 {
            recover(reason: "网络卡住了")
        }
    }

    /// 停掉卡住的连接，换（新）地址从原位置重新打开。90 秒内最多自动试 3 次，之后提示用户点重试。
    private func recover(reason: String) {
        guard let url = currentURL, recoveryTask == nil else { return }
        cancelAddressResolution()
        let now = Date()
        // 播过之后断了：90 秒内最多试 3 次；一次都没播出来：总共也只再试 3 次，免得一直转圈
        if playedThisSession {
            recoveryAttempts = recoveryAttempts.filter { now.timeIntervalSince($0) < 90 }
        }
        guard recoveryAttempts.count < 3 else {
            engine?.command(["stop"])
            giveUp(reason.isEmpty ? "网络连接中断" : reason)
            return
        }
        recoveryAttempts.append(now)
        let position = pendingSeek ?? resumePoint
        logEvent("重连（\(reason.isEmpty ? "手动" : reason)）第 \(recoveryAttempts.count) 次，从 \(Self.clock(position))")
        let refresher = urlRefresher
        let direct115 = currentDirect115
        let cookie = currentCookie
        let currentSession = session
        openTimeoutTask?.cancel()
        // 刚打开就失败的第一次重试悄悄进行，不弹「打开失败」吓人；之后再说明在重连
        if recoveryAttempts.count == 1 && !hasPlayed {
            statusNote = ""
        } else {
            statusNote = reason.isEmpty ? "正在重新连接…" : "\(reason)，正在重新连接…"
        }
        engine?.command(["stop"])
        // 第一次马上重连；再失败说明对方（115 的服务器、网络）当时正忙或在掐连接，隔几秒再来，
        // 不要 1 秒内连着撞三次就放弃
        let backoff: [Double] = [0, 2, 5]
        let wait = backoff[min(recoveryAttempts.count - 1, backoff.count - 1)]
        recoveryTask = Task { @MainActor [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            var target = url
            if let refresher, let fresh = try? await refresher() { target = fresh }
            guard let self, !Task.isCancelled, self.session == currentSession else { return }
            self.recoveryTask = nil
            self.start(target, direct115: direct115, cookie: cookie, position: position, keepPlaying: !self.userPaused, keepDuration: true)
        }
        updateFlags()
    }

    private func giveUp(_ reason: String) {
        logEvent("放弃：\(reason)")
        cancelAddressResolution()
        openTimeoutTask?.cancel()
        recoveryTask?.cancel()
        recoveryTask = nil
        statusNote = ""
        opening = false
        loaded = false
        let proxyProblem = LocalStreamProxy.shared.problem
        errorDetail = proxyProblem.isEmpty ? Self.shortReason(from: logLines) : proxyProblem
        error = resumePoint > 1
            ? "\(reason)，自动重连几次都没成功。点「重试」会从 \(Self.clock(resumePoint)) 接着播放。"
            : "\(reason)，请点「重试」，或换一个画质。"
        updateFlags()
    }

    private func logEvent(_ text: String) {
        eventLines.append("\(Self.eventClock.string(from: Date())) \(text)")
        if eventLines.count > 40 { eventLines.removeFirst(eventLines.count - 40) }
    }

    /// 从内核日志里挑最后一条错误，截短后给用户看
    private static func shortReason(from lines: [String]) -> String {
        let line = lines.last(where: { $0.contains("] error:") || $0.contains("] fatal:") }) ?? lines.last ?? ""
        let text = line.replacingOccurrences(of: "\n", with: " ")
        return text.count > 120 ? String(text.prefix(120)) + "…" : text
    }

    /// 播放出问题时复制给开发者的诊断信息：地址类型、状态和内核最近的警告错误
    var diagnostics: String {
        var lines = [
            "HPlayer 播放诊断",
            "地址：\(currentURL.map { "\($0.scheme ?? "")://\($0.host ?? "")\($0.path.suffix(40))" } ?? "无")",
            "115：\(currentDirect115) 解码：\(decoding.rawValue)（实际：\(activeHwdec.isEmpty ? "未知" : activeHwdec)） 缓存：\(readahead.rawValue)s",
            "状态：loaded=\(loaded) opening=\(opening) playedOnce=\(hasPlayed) cache=\(pausedForCache) seeking=\(seeking) speed=\(Int(downloadSpeed)) cached=\(Int(cachedSeconds))s",
            "位置：\(Self.clock(engineTime)) / \(Self.clock(duration)) 可跳转=\(seekable) 播完=\(ended) eof=\(eofReached) 暂停=\(userPaused)",
            "倍速：\(effectiveRate)× 音画偏差：\(avSync.map { String(format: "%.3fs", $0) } ?? "未知") 长按最大偏差：\(boostAVSyncPeak.map { String(format: "%.3fs", $0) } ?? "未知")",
            "错误：\(error)",
            "中转：\(LocalStreamProxy.shared.statusText)\(LocalStreamProxy.shared.problem.isEmpty ? "" : "；上游出错：" + LocalStreamProxy.shared.problem)",
            "—— 播放事件 ——",
        ]
        lines += eventLines
        let relayLog = LocalStreamProxy.shared.problemHistoryLines
        if !relayLog.isEmpty {
            lines.append("—— 中转记录（上游出错与重试）——")
            lines += relayLog
        }
        lines.append("—— 内核日志 ——")
        lines += logLines
        return lines.joined(separator: "\n")
    }

    /// 出错提示里的「重试」：从原位置重新打开（会先换新地址）
    var canRetryInPlace: Bool { currentURL != nil }

    func retry() {
        recoveryAttempts = []
        error = ""
        userPaused = false
        recover(reason: "")
    }

    // MARK: 工具

    private static func cookieHeader(_ header: String) -> String {
        header.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { pair in
                guard let equals = pair.firstIndex(of: "=") else { return false }
                let name = String(pair[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return !name.isEmpty && !["path", "domain", "expires", "max-age", "samesite"].contains(name)
            }
            .joined(separator: "; ")
    }

    /// 网络视频交给本机中转，由系统网络栈去连 115（mpv 自带的 TLS 连 115 会被断开）；本机地址（磁力边下边播）直接给内核
    /// `renew`：115 地址过期（上游 403）时中转自己换新地址接着下，不打断播放
    private static func engineAddress(for url: URL, direct115: Bool, cookieHeader: String, customHeaders: [String: String] = [:],
                                      renew: (() async throws -> URL)? = nil) async -> String {
        if url.isFileURL { return url.path }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return url.absoluteString }
        let host = url.host?.lowercased() ?? ""
        var loopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
        #if DEBUG
        // UI 测试的视频在本机测试服务器上，也走中转，好在模拟器上把中转一起测了
        if ProcessInfo.processInfo.environment["HPLAYER_UI_TEST_URL"] != nil { loopback = false }
        #endif
        guard !loopback else { return url.absoluteString }
        var headers = ["User-Agent": direct115 ? Direct115Client.userAgent : "HPlayer"]
        if direct115 {
            headers["Referer"] = "https://115.com/"
            if !cookieHeader.isEmpty { headers["Cookie"] = cookieHeader }
        }
        for (k, v) in customHeaders {
            headers[k] = v
        }
        return await LocalStreamProxy.shared.localURL(for: url, headers: headers, renew: renew)?.absoluteString ?? url.absoluteString
    }

    static func clock(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
    }
}

// MARK: - 播放画面

/// mpv 把画面画在这个视图的 Metal 图层上。
/// 用一个视图控制器承载，是为了在系统旋转屏幕时拿到旋转动画：
/// 画面的缩放和位置跟着旋转一起变化，而不是旋转开始的瞬间直接跳到竖屏的大小。
struct PlayerVideoSurface: UIViewControllerRepresentable {
    @ObservedObject var playback: PlaybackController

    func makeUIViewController(context: Context) -> PlayerVideoViewController {
        let controller = PlayerVideoViewController()
        playback.attach(layer: controller.metalLayer)
        return controller
    }

    func updateUIViewController(_ controller: PlayerVideoViewController, context: Context) {}
}

extension Notification.Name {
    /// 播放画面所在页面的尺寸过渡（屏幕旋转）走完时发出，关闭播放器时用它判断什么时候可以收起页面。
    static let playerSizeTransitionDidFinish = Notification.Name("app.hplayer.playerSizeTransitionDidFinish")
}

final class PlayerVideoViewController: UIViewController {
    private let canvas = PlayerCanvasView()
    var metalLayer: MPVMetalLayer { canvas.metalLayer }

    /// 画面图层固定用横屏尺寸渲染。MPVKit 的 iOS 渲染上下文不会把图层尺寸的变化告诉 mpv，
    /// 转到竖屏后 mpv 还按横屏的大小算画面位置，画面会被挤到左上角、右边被裁掉。
    /// 所以图层本身的尺寸始终不变，竖屏时只是把整块横屏画面等比缩小放在中间。
    private var renderSize = CGSize.zero
    /// 正在旋转：这段时间的画面位置和缩放只由旋转动画里的那一次设置决定，布局回调不插手，
    /// 否则布局先把终点值设上去，旋转动画就没有变化可以动了。
    private var transitioning = false

    override func loadView() {
        let container = UIView()
        container.backgroundColor = .black
        container.isUserInteractionEnabled = false
        container.addSubview(canvas)
        view = container
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !transitioning else { return }
        applyGeometry(in: view.bounds.size)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        transitioning = true
        // 这个闭包由系统放进旋转动画里执行：center 和 transform 的变化会用和旋转一样的时长、曲线动起来，
        // 画面于是跟着界面一起转过去、缩放到竖屏的大小。
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.applyGeometry(in: size)
        }, completion: { [weak self] _ in
            guard let self else { return }
            self.transitioning = false
            self.applyGeometry(in: self.view.bounds.size)
            NotificationCenter.default.post(name: .playerSizeTransitionDidFinish, object: nil)
        })
    }

    /// 把横屏尺寸的画面等比缩放后放在容器正中。只改 center 和 transform，图层的 bounds 始终不变。
    private func applyGeometry(in container: CGSize) {
        guard container.width > 0, container.height > 0 else { return }
        if renderSize == .zero {
            let screen = view.window?.screen.bounds.size ?? UIScreen.main.bounds.size
            let reference = screen.width > 0 && screen.height > 0 ? screen : container
            renderSize = CGSize(width: max(reference.width, reference.height), height: min(reference.width, reference.height))
            canvas.bounds = CGRect(origin: .zero, size: renderSize)
        }
        let nativeScale = view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
        if canvas.contentScaleFactor != nativeScale { canvas.contentScaleFactor = nativeScale }
        let scale = min(container.width / renderSize.width, container.height / renderSize.height)
        canvas.center = CGPoint(x: container.width / 2, y: container.height / 2)
        canvas.transform = CGAffineTransform(scaleX: scale, y: scale)
    }
}

/// 图层就是视图自己的 Metal 图层：视图的 center、transform 参与系统的动画，单独挂的子图层做不到。
final class PlayerCanvasView: UIView {
    override class var layerClass: AnyClass { MPVMetalLayer.self }
    var metalLayer: MPVMetalLayer { layer as! MPVMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        isUserInteractionEnabled = false
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class MPVMetalLayer: CAMetalLayer {
    // MoltenVK 有时会把 drawableSize 设成 1x1 来强制结束一帧，会导致闪烁或画面一直是 1x1
    // https://github.com/mpv-player/mpv/pull/13651
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    // HDR 需要在主线程打开屏幕的 EDR 模式
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.sync { super.wantsExtendedDynamicRangeContent = newValue }
            }
        }
    }
}
