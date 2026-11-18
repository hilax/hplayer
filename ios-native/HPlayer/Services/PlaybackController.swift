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

    /// 默认全局字幕缩放倍率（保持 mpv 原生垂直位置不变）
    static let defaultSubScale = "1.26"

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
                    "sub-shadow-offset": "0", "sub-scale": "1.52"]
        case .outline:
            return [:]
        case .soft:
            // 显式关闭 sub-blur（无描边时模糊会连文字本身一并糊掉），改用微弱暗影护边 + 清晰投影保证透明底通透锐利
            return ["sub-border-style": "outline-and-shadow", "sub-outline-size": "0.9", "sub-outline-color": "#59000000",
                    "sub-shadow-offset": "2", "sub-back-color": "#99000000", "sub-blur": "0"]
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
    /// 内核报告的画面宽高比（宽 ÷ 高，已经算上像素宽高比和强制比例）；还没出画面时是 0。
    /// 换下一集时先留着上一集的值：同一部剧比例一样，竖屏小窗不用先弹回 16:9 再变回来。
    @Published private(set) var videoAspect: Double = 0
    /// 竖屏信息页「文件信息」用：文件大小（字节，未知为 0）、视频 / 音频编码的简短名字（未知为空）
    @Published private(set) var fileSize: Int64 = 0
    @Published private(set) var videoCodecName = ""
    @Published private(set) var audioCodecName = ""
    /// 画面那一块现在摆在播放区域的什么位置（由画面视图报告）。只给诊断信息和界面测试看，不参与界面刷新
    private(set) var pictureFrame = CGRect.zero
    /// 整块画面图层现在占的位置（含它自带的黑边，竖屏时两边会伸到小窗外）
    private(set) var canvasFrame = CGRect.zero
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subtitleTracks: [MediaTrack] = []
    @Published private(set) var selectedAudio: Int?
    @Published private(set) var selectedSubtitle: Int?
    @Published private(set) var onlineSubtitles: [OnlineSubtitleCandidate] = []
    @Published private(set) var onlineSubtitleSearching = false
    @Published private(set) var onlineSubtitleStatus = ""
    @Published private(set) var onlineSubtitleSearchQuery = ""
    @Published private(set) var activeOnlineSubtitleID: String?
    @Published private(set) var autoOnlineSubtitleEnabled = OnlineSubtitlePrefs.autoMatchEnabled
    @Published private(set) var subtitleDelay: Double = 0
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

    /// 正在小窗（画中画）播放
    @Published private(set) var pictureInPictureActive = false
    /// 是否自动进小窗：播放中回到桌面时变成小窗继续播
    @Published private(set) var autoPictureInPicture = PictureInPictureSettings.automatic
    private var pictureInPicture: PlayerPictureInPicture?
    /// 这次打开的视频已经往小窗图层里放过一帧画面
    private var pictureInPictureStillReady = false
    /// 小窗刚开始、内核还在切换输出的这段时间，也算在小窗里（不要关画面）
    private var pictureInPictureStarting = false
    /// 点了小窗按钮：小窗出来以后自动回到桌面
    private var leaveAppAfterPictureInPicture = false
    private var pendingOpen: (() -> Void)?
    /// 内核正在后台创建
    private var creatingEngine = false
    /// 播放控制器创建的时间（点封面后播放页开始出现的时刻），诊断信息里用来对「出画面花了多久」
    private let createdAt = Date()

    private var currentURL: URL?
    /// 正在播的是本机文件（下载好的、导入的）：播放页右上角不显示网络和网速
    var isLocalFile: Bool { currentURL?.isFileURL ?? false }
    private var currentDirect115 = false
    private var currentCookie = ""
    private var currentCustomHeaders: [String: String] = [:]
    private var currentStreamID: String?
    private var currentPlaylistRenew: (() async throws -> URL)?
    private var currentEngineURL: URL?
    private var currentTitle = ""
    private var currentSubtitleIdentifier: String?
    private var currentIMDBID: String?
    private var currentIsAdultVideo = false
    private var currentSkipRemoteHash = false
    private var currentTorrentStream = false
    private var onlineSubtitleTask: Task<Void, Never>?
    private var onlineSubtitleAutoHandledSession = -1
    private var mountedOnlineTrackID: Int?
    private var cachedFingerprint: VideoSubtitleFingerprint?
    private var subtitleDelayHydratedSession = -1
    private var rawCacheSpeed: Int = 0
    private var healthyPlaybackSeconds: Int = 0
    private var openingSeconds: Int = 0
    private var tier1RefreshAttemptedInStall = false
    private var pausedAtUptime: TimeInterval?
    private var preferLargerPauseWait = false
    private static let minHealthyCacheSpeedBytes = 32 * 1024
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
    /// 视频是否已经完成头信息加载（用于播放页错峰获取画质菜单）
    var hasLoaded: Bool { loaded }
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
            NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                // 可能要回到桌面了：把当前画面放进小窗图层，自动进小窗时从当前画面飞出去
                Task { @MainActor [weak self] in
                    guard let self, self.autoPictureInPicture, self.playing, self.loaded,
                          !self.pictureInPictureActive, !self.pictureInPictureStarting else { return }
                    self.pictureInPicture?.grabStill()
                }
            },
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                // 退到后台时只留声音，回来再打开画面，避免回到前台画面变黑；小窗播放时画面还要继续
                Task { @MainActor [weak self] in
                    // 关画面之前先给「继续观看」留一张当前画面
                    self?.captureResumeFrame()
                    guard let self, !self.pictureInPictureActive, !self.pictureInPictureStarting,
                          self.engine?.softwareOutputActive != true else { return }
                    self.engine?.set("vid", "no")
                }
            },
            NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.engine?.set("vid", "auto") }
            },
        ]
        // 清理上次没清掉的缓存文件、量一下能用多少空间、预热内置字幕字体：放到后台做，不挡着播放页出现
        PlayerDiskCache.prepare()
        PlayerDiskCache.queue.async {
            _ = SubtitleFontManager.prepareSubtitleFontDirectory()
        }
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
        var options = engineOptions()
        let began = Date()
        PlayerDiskCache.queue.async { [weak self] in
            if let fontDir = SubtitleFontManager.prepareSubtitleFontDirectory() {
                options.append(("sub-fonts-dir", fontDir.path))
                options.append(("sub-font", SubtitleFontManager.defaultFontName))
                options.append(("osd-fonts-dir", fontDir.path))
                options.append(("osd-font", SubtitleFontManager.defaultFontName))
            }
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
            ("sub-scale", SubtitleStyle.defaultSubScale),
            ("screenshot-format", "jpg"),
            // 网络：115 偶发卡顿时 15 秒触发一次底层重试，更早切换或重连
            ("network-timeout", "15"),
            ("stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=4"),
            // 边播边存：开头不等缓存，攒到一点就播；卡住重连后适度多攒 2.5 秒防抖动
            ("cache", "yes"),
            ("cache-pause", "yes"),
            ("cache-pause-initial", "no"),
            ("cache-pause-wait", preferLargerPauseWait ? "2.5" : "1"),
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
        ("video-params/aspect", MPV_FORMAT_DOUBLE),
        ("video-format", MPV_FORMAT_STRING),
        ("audio-codec-name", MPV_FORMAT_STRING),
        ("file-size", MPV_FORMAT_INT64),
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
        openTimeoutSeconds: UInt64 = 45,
        streamID: String? = nil,
        playlistRenew: (() async throws -> URL)? = nil,
        title: String = "",
        subtitleIdentifier: String? = nil,
        imdbID: String? = nil,
        isAdultVideo: Bool = false,
        skipRemoteHash: Bool = false,
        isTorrentStream: Bool = false
    ) {
        guard !closingPlayback else { return }
        session += 1
        currentTorrentStream = isTorrentStream
        if !preservingPosition {
            playedThisSession = false
            softwareFallbackNoticed = false
            pictureInPictureStillReady = false
            preferLargerPauseWait = false
            currentTitle = title
            currentSubtitleIdentifier = subtitleIdentifier
            currentIMDBID = imdbID
            currentIsAdultVideo = isAdultVideo
            currentSkipRemoteHash = skipRemoteHash
            onlineSubtitleTask?.cancel()
            onlineSubtitleTask = nil
            onlineSubtitleSearching = false
            onlineSubtitles = []
            onlineSubtitleStatus = ""
            activeOnlineSubtitleID = nil
            mountedOnlineTrackID = nil
            cachedFingerprint = nil
            onlineSubtitleAutoHandledSession = -1
            subtitleDelay = 0
            subtitleDelayHydratedSession = -1
            autoOnlineSubtitleEnabled = OnlineSubtitlePrefs.autoMatchEnabled
            onlineSubtitleSearchQuery = SubtitleQueryBuilder.build(
                rawTitle: title,
                streamURL: url,
                fallbackIdentifier: subtitleIdentifier,
                isAdultHint: isAdultVideo
            ).displayQuery
        } else if !title.isEmpty {
            currentTitle = title
        }
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryAttempts = []
        statusNote = ""
        urlRefresher = refreshURL
        currentStreamID = streamID
        currentPlaylistRenew = playlistRenew
        pausedAtUptime = nil
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

        engine.set("hwdec", hwdecOption)
        if currentTorrentStream {
            // 本机 BT 引擎已在 HPlayerMagnet/pieces 做了持久化分片缓存并支持 16KB 块级流式吐出：
            // 放宽超时以对齐底层 60 秒片块等待，避免 15 秒误切断本地流，并适当缩短探测与内存预读窗口
            engine.set("network-timeout", "60")
            engine.set("stream-lavf-o", "reconnect=0")
            engine.set("demuxer-lavf-probesize", "1572864")
            engine.set("cache-pause-wait", "2.0")
        } else {
            engine.set("network-timeout", "15")
            engine.set("stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=4")
            engine.set("demuxer-lavf-probesize", "4194304")
            engine.set("cache-pause-wait", preferLargerPauseWait ? "2.5" : "1")
        }
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
        let streamID = currentStreamID
        let playlistRenew = currentPlaylistRenew
        currentEngineURL = nil
        addressTask = Task { @MainActor [weak self, weak engine] in
            let address = await Self.engineAddress(for: url, direct115: direct115, cookieHeader: cookieHeader,
                                                   customHeaders: customHeaders, streamID: streamID,
                                                   renew: renew, playlistRenew: playlistRenew)
            guard let self, let engine, !Task.isCancelled, !self.closingPlayback,
                  self.session == currentSession, self.addressGeneration == generation,
                  self.engine === engine else { return }
            self.addressTask = nil
            self.currentEngineURL = URL(string: address)
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
        rawCacheSpeed = 0
        healthyPlaybackSeconds = 0
        openingSeconds = 0
        tier1RefreshAttemptedInStall = false
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
            fileSize = 0
            videoCodecName = ""
            audioCodecName = ""
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
        if currentTorrentStream {
            engine.set("cache-on-disk", false)
            let seconds = min(readahead.rawValue, 60)
            engine.set("demuxer-readahead-secs", "\(seconds)")
            engine.set("cache-secs", "\(seconds)")
            engine.set("demuxer-max-bytes", "96MiB")
            engine.set("demuxer-max-back-bytes", "32MiB")
            return
        }
        engine.set("cache-on-disk", true)
        engine.set("demuxer-max-back-bytes", "256MiB")
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
        pictureInPicture?.stop()
        closingPlayback = true
        userPaused = true
        pausedAtUptime = ProcessInfo.processInfo.systemUptime
        pendingOpen = nil
        cancelAddressResolution()
        openTimeoutTask?.cancel()
        engine?.set("pause", true)
        updateFlags()
        captureResumeFrame()
    }

    // MARK: 继续观看封面

    /// 这一集在「继续观看」里的键（见 `PlaybackFrameStore`）。播放页、磁力播放打开视频时设置；为 nil 时不截图。
    var resumeFrameKey: String?
    private var lastResumeFrame: (key: String, time: Double, at: Date)?

    /// 截一张当前画面（只有视频本身，不带字幕和控件）给「继续观看」当封面。
    /// 在暂停、换集、退出、退到后台时调用；同一位置 2 秒内不重复截。缩小和黑场判断在后台做。
    func captureResumeFrame() {
        guard let key = resumeFrameKey, let engine, loaded, error.isEmpty, !ended, currentTime > 3 else { return }
        if let last = lastResumeFrame, last.key == key, abs(last.time - currentTime) < 1,
           Date().timeIntervalSince(last.at) < 2 { return }
        lastResumeFrame = (key, currentTime, Date())
        // 直接取当前帧的像素（不依赖 mpv 的图片编码器）；取不到时再试写文件
        if let image = engine.videoFrameImage() {
            PlaybackFrameStore.shared.ingest(image: image, for: key)
            return
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hplayer-frame-\(UUID().uuidString).jpg")
        guard engine.command(["screenshot-to-file", file.path, "video"]) >= 0 else { return }
        PlaybackFrameStore.shared.ingest(file: file, for: key)
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
            pausedAtUptime = ProcessInfo.processInfo.systemUptime
            engine?.set("pause", true)
            captureResumeFrame()
        } else {
            let pauseElapsed = pausedAtUptime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
            pausedAtUptime = nil
            userPaused = false
            noDataSeconds = 0
            openingSeconds = 0
            tier1RefreshAttemptedInStall = false
            if !loaded, recoveryTask == nil, !opening || !error.isEmpty {
                // 连接断了停在那里：从停下的位置重新打开
                recoveryAttempts = []
                recover(reason: "")
            } else {
                engine?.set("pause", false)
                if pauseElapsed >= 90, urlRefresher != nil, let engineURL = currentEngineURL {
                    LocalStreamProxy.shared.refreshActiveUpstream(for: engineURL)
                }
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

    func setEngineURLForTesting(_ url: URL?) { currentEngineURL = url }

    var recoveryCountForTesting: Int { recoveryAttempts.count }

    var customHeadersForTesting: [String: String] { currentCustomHeaders }
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
        // 换集、退出都会先 stop：停之前把当前画面留给「继续观看」当封面
        captureResumeFrame()
        // 换集也会先 stop：小窗不关，下一集接着在小窗里播
        session += 1
        cancelAddressResolution()
        recoveryTask?.cancel()
        recoveryTask = nil
        openTimeoutTask?.cancel()
        watchdogTask?.cancel()
        watchdogTask = nil
        onlineSubtitleTask?.cancel()
        onlineSubtitleTask = nil
        onlineSubtitleSearching = false
        onlineSubtitles = []
        onlineSubtitleStatus = ""
        mountedOnlineTrackID = nil
        activeOnlineSubtitleID = nil
        cachedFingerprint = nil
        subtitleDelay = 0
        subtitleDelayHydratedSession = -1
        pendingOpen = nil
        statusNote = ""
        engine?.command(["stop"])
        resetState(keepDuration: false)
        playing = false
        buffering = false
        opening = false
        userPaused = false
        currentURL = nil
        currentTorrentStream = false
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

    /// 画面按现在的设置显示出来的宽高比（宽 ÷ 高）；还没出画面时为空。
    /// 竖屏小窗的高度和画面的缩放都按它算。强制比例直接用选的那个值（内核要到下一帧才改过来）。
    var displayAspect: Double? {
        switch aspect {
        case .ratio16x9: return 16.0 / 9.0
        case .ratio4x3: return 4.0 / 3.0
        case .ratio235: return 2.35
        case .fit, .fill, .stretch: return videoAspect > 0 ? videoAspect : nil
        }
    }

    /// 内核给的编码名（h264、hevc、aac、eac3…）换成常见写法
    static func codecName(_ raw: String) -> String {
        let known = ["h264": "H.264", "hevc": "H.265", "h265": "H.265", "av1": "AV1", "vp9": "VP9", "vp8": "VP8",
                     "mpeg4": "MPEG-4", "mpeg2video": "MPEG-2", "vc1": "VC-1", "wmv3": "WMV", "rv40": "RMVB",
                     "aac": "AAC", "ac3": "AC-3", "eac3": "E-AC-3", "truehd": "TrueHD", "dts": "DTS", "flac": "FLAC",
                     "mp3": "MP3", "opus": "Opus", "vorbis": "Vorbis", "alac": "ALAC"]
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if key.isEmpty { return "" }
        if let name = known[key] { return name }
        if key.hasPrefix("pcm") { return "PCM" }
        return key.uppercased()
    }

    /// 画面视图摆好位置后报告一次
    func notePictureGeometry(picture: CGRect, canvas: CGRect) {
        pictureFrame = picture
        canvasFrame = canvas
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
        if id == nil || id != mountedOnlineTrackID {
            activeOnlineSubtitleID = nil
        }
    }

    // MARK: 在线字幕与同步微调

    var subtitleDelayLabel: String {
        if abs(subtitleDelay) < 0.05 { return "0.0s" }
        return String(format: "%+.1fs", subtitleDelay)
    }

    func nudgeSubtitleDelay(by delta: Double) {
        setSubtitleDelay(subtitleDelay + delta)
    }

    func resetSubtitleDelay() {
        setSubtitleDelay(0)
    }

    func setSubtitleDelay(_ seconds: Double) {
        let rounded = (min(max(seconds, -60), 60) * 10).rounded() / 10
        let normalized = abs(rounded) < 0.05 ? 0 : rounded
        subtitleDelay = normalized
        engine?.set("sub-delay", normalized)
        if let key = currentOnlineSubtitleVideoKey {
            OnlineSubtitleCache.shared.updateDelay(normalized, for: key)
        }
    }

    func setAutoOnlineSubtitleEnabled(_ enabled: Bool) {
        autoOnlineSubtitleEnabled = enabled
        OnlineSubtitlePrefs.autoMatchEnabled = enabled
        if enabled {
            if activeOnlineSubtitleID == nil, loaded {
                triggerOnlineSubtitleSearch(manualQuery: nil, autoMount: true)
            }
        } else {
            onlineSubtitleTask?.cancel()
            onlineSubtitleTask = nil
            onlineSubtitleSearching = false
        }
    }

    func searchOnlineSubtitles(query: String? = nil) {
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        triggerOnlineSubtitleSearch(manualQuery: (trimmed?.isEmpty == false) ? trimmed : nil, autoMount: false)
    }

    func applyOnlineSubtitle(_ candidate: OnlineSubtitleCandidate) async {
        let activeSession = session
        onlineSubtitleSearching = true
        onlineSubtitleStatus = "正在下载字幕…"
        let localFile: URL?
        if let cached = OnlineSubtitleCache.shared.cachedFile(for: candidate) {
            localFile = cached
        } else if let text = await OnlineSubtitleService.shared.downloadSubtitleText(from: candidate) {
            localFile = OnlineSubtitleCache.shared.saveSubtitleText(text, for: candidate)
        } else {
            localFile = nil
        }
        guard session == activeSession, !closingPlayback else { return }
        onlineSubtitleSearching = false
        guard let localFile else {
            onlineSubtitleStatus = "字幕下载失败，请换一条"
            notice = "在线字幕下载失败，请尝试其他候选"
            return
        }
        let mounted = await mountSubtitleFile(localFile, candidate: candidate, expectedSession: activeSession)
        guard mounted, session == activeSession, !closingPlayback else {
            if session == activeSession, !closingPlayback {
                onlineSubtitleStatus = "字幕挂载失败，请换一条"
            }
            return
        }
        if let key = currentOnlineSubtitleVideoKey {
            OnlineSubtitleCache.shared.rememberSelection(candidate, fileURL: localFile, delaySeconds: subtitleDelay, for: key)
        }
        onlineSubtitleStatus = "已挂载 · \(candidate.source.shortTitle)"
        notice = "已挂载字幕：\(candidate.trackTitle)"
    }

    private var currentOnlineSubtitleVideoKey: String? {
        guard let url = currentURL else { return nil }
        return OnlineSubtitleCache.videoKey(streamID: currentStreamID, url: url, title: currentTitle)
    }

    private var shouldSkipAutomaticOnlineSubtitles: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["HPLAYER_ENABLE_ONLINE_SUBTITLE_TEST"] == "1" {
            return false
        }
        if ProcessInfo.processInfo.environment["HPLAYER_DISABLE_AUTO_ONLINE_SUBTITLES"] == "1"
            || ProcessInfo.processInfo.environment["HPLAYER_UI_TEST_URL"] != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil {
            return true
        }
        #endif
        return false
    }

    private func handleFileLoadedForOnlineSubtitles() {
        restoreSubtitleDelayIfNeeded()
        restoreMountedOnlineSubtitleIfNeeded()
        scheduleAutoOnlineSubtitleIfNeeded()
    }

    private func restoreSubtitleDelayIfNeeded() {
        guard let engine else { return }
        if subtitleDelayHydratedSession != session {
            subtitleDelayHydratedSession = session
            if let key = currentOnlineSubtitleVideoKey,
               let saved = OnlineSubtitleCache.shared.savedDelay(for: key),
               abs(saved) >= 0.05 {
                subtitleDelay = saved
            }
        }
        if abs(subtitleDelay) >= 0.05 {
            engine.set("sub-delay", subtitleDelay)
        }
    }

    private func restoreMountedOnlineSubtitleIfNeeded() {
        guard let key = currentOnlineSubtitleVideoKey,
              let activeID = activeOnlineSubtitleID,
              let saved = OnlineSubtitleCache.shared.savedSelection(for: key),
              saved.selection.candidate.id == activeID else { return }
        let alreadyMounted = subtitleTracks.contains { $0.external && $0.title == saved.selection.candidate.trackTitle }
        if !alreadyMounted {
            let activeSession = session
            Task { @MainActor [weak self] in
                _ = await self?.mountSubtitleFile(
                    saved.fileURL,
                    candidate: saved.selection.candidate,
                    expectedSession: activeSession
                )
            }
        }
    }

    private func scheduleAutoOnlineSubtitleIfNeeded() {
        guard autoOnlineSubtitleEnabled,
              onlineSubtitleAutoHandledSession != session,
              !shouldSkipAutomaticOnlineSubtitles,
              currentURL != nil else { return }
        onlineSubtitleAutoHandledSession = session
        let activeSession = session
        onlineSubtitleTask?.cancel()
        onlineSubtitleTask = Task { @MainActor [weak self] in
            // 等 mpv 完成轨道探测与文件大小上报
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, !Task.isCancelled, self.session == activeSession, !self.closingPlayback else { return }
            guard self.autoOnlineSubtitleEnabled else { return }

            // 已有内嵌或同目录中文字幕时不自动覆盖
            if self.subtitleTracks.contains(where: Self.isChineseTrack) {
                self.onlineSubtitleStatus = "视频已带中文字幕"
                return
            }

            // 先检查本机是否记忆过该视频选用的在线字幕
            if let key = self.currentOnlineSubtitleVideoKey,
               let saved = OnlineSubtitleCache.shared.savedSelection(for: key) {
                if await self.mountSubtitleFile(
                    saved.fileURL,
                    candidate: saved.selection.candidate,
                    expectedSession: activeSession
                ) {
                    if abs(saved.selection.delaySeconds) >= 0.05 {
                        self.setSubtitleDelay(saved.selection.delaySeconds)
                    }
                    self.onlineSubtitleStatus = "已恢复 · \(saved.selection.candidate.source.shortTitle)"
                    self.notice = "已挂载缓存字幕：\(saved.selection.candidate.trackTitle)"
                }
                return
            }

            await self.performOnlineSubtitleSearch(manualQuery: nil, autoMount: true, expectedSession: activeSession)
        }
    }

    /// 仅对本地磁盘文件（且未要求跳过远端 Hash）计算 4 段 Hash 指纹，
    /// 避免播放远程流/代理流时并发 Range 请求抢占主播放通道造成卡顿掉帧。
    static func shouldComputeSubtitleFingerprint(for url: URL, skipRemoteHash: Bool = false) -> Bool {
        url.isFileURL && !skipRemoteHash
    }

    private func triggerOnlineSubtitleSearch(manualQuery: String?, autoMount: Bool) {
        let activeSession = session
        onlineSubtitleTask?.cancel()
        onlineSubtitleTask = Task { @MainActor [weak self] in
            await self?.performOnlineSubtitleSearch(manualQuery: manualQuery, autoMount: autoMount, expectedSession: activeSession)
        }
    }

    private func performOnlineSubtitleSearch(
        manualQuery: String?,
        autoMount: Bool,
        expectedSession: Int
    ) async {
        guard let url = currentURL, session == expectedSession, !closingPlayback else { return }
        onlineSubtitleSearching = true
        onlineSubtitleStatus = "正在匹配在线字幕…"

        let resolvedURL = currentEngineURL ?? url
        let knownSize = fileSize > 0 ? fileSize : nil
        let context = OnlineSubtitleContext(
            rawTitle: currentTitle,
            streamURL: resolvedURL,
            knownFileSize: knownSize,
            durationSeconds: duration > 0 ? duration : nil,
            fallbackIdentifier: currentSubtitleIdentifier,
            imdbID: currentIMDBID,
            isAdultVideo: currentIsAdultVideo
        )

        var fingerprint = cachedFingerprint
        if fingerprint == nil, manualQuery == nil, Self.shouldComputeSubtitleFingerprint(for: resolvedURL, skipRemoteHash: currentSkipRemoteHash) {
            fingerprint = await VideoSubtitleFingerprint.compute(streamURL: resolvedURL, knownFileSize: knownSize)
            if session == expectedSession { cachedFingerprint = fingerprint }
        }
        guard !Task.isCancelled, session == expectedSession, !closingPlayback else { return }

        let result = await OnlineSubtitleService.shared.search(
            context: context,
            fingerprint: fingerprint,
            manualQuery: manualQuery
        )
        guard !Task.isCancelled, session == expectedSession, !closingPlayback else { return }

        onlineSubtitleSearchQuery = result.query
        onlineSubtitles = result.candidates

        if autoMount, let best = OnlineSubtitleService.autoPick(from: result.candidates) {
            await applyOnlineSubtitle(best)
            return
        }

        onlineSubtitleSearching = false
        if result.candidates.isEmpty {
            onlineSubtitleStatus = "暂未找到匹配字幕"
        } else if autoMount {
            onlineSubtitleStatus = "找到 \(result.candidates.count) 条，可手动选择"
        } else {
            onlineSubtitleStatus = "找到 \(result.candidates.count) 条字幕"
        }
    }

    private func mountSubtitleFile(
        _ fileURL: URL,
        candidate: OnlineSubtitleCandidate,
        expectedSession: Int
    ) async -> Bool {
        guard let engine, session == expectedSession, !closingPlayback else { return false }
        if let oldTrackID = mountedOnlineTrackID {
            mountedOnlineTrackID = nil
            _ = await engine.commandAsync(["sub-remove", String(oldTrackID)])
            guard session == expectedSession, !closingPlayback, self.engine === engine else { return false }
        }
        let status = await engine.commandAsync([
            "sub-add", fileURL.path, "select", candidate.trackTitle, candidate.trackLanguageCode,
        ])
        guard status >= 0, session == expectedSession, !closingPlayback, self.engine === engine else {
            return false
        }
        refreshTracks()
        if let currentID = engine.string("sid").flatMap(Int.init) {
            mountedOnlineTrackID = currentID
        } else if let matched = subtitleTracks.last(where: { $0.external && $0.title == candidate.trackTitle }) {
            mountedOnlineTrackID = matched.id
            selectSubtitle(matched.id)
        }
        activeOnlineSubtitleID = candidate.id
        applySubtitleStyle(engine)
        return true
    }

    private static func isChineseTrack(_ track: MediaTrack) -> Bool {
        let text = "\(track.title) \(track.detail)".lowercased()
        let phrases = ["中文", "简", "繁", "国语", "双语", "chi", "zho", "chs", "cht", "zh-cn", "zh-tw", "zh-hk", "zh_cn", "zh_tw"]
        if phrases.contains(where: { text.contains($0) }) { return true }
        let tokens = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return tokens.contains { $0 == "zh" || $0 == "sc" || $0 == "tc" || $0 == "cmn" }
    }

    /// 截一张当前画面，存进相册；返回是否成功
    func screenshot() async -> Bool {
        guard let engine, loaded else { return false }
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited,
              !Task.isCancelled, loaded, self.engine === engine else { return false }
        // 直接取当前帧的像素做成图片（原始分辨率，不含字幕）；取不到时再试 mpv 写文件
        if let frame = engine.videoFrameImage() {
            return await saveToPhotos(UIImage(cgImage: frame))
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hplayer-shot-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        guard engine.command(["screenshot-to-file", file.path, "video"]) >= 0 else { return false }
        for _ in 0..<20 {
            guard !Task.isCancelled else { return false }
            if let image = UIImage(contentsOfFile: file.path) {
                return await saveToPhotos(image)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private func saveToPhotos(_ image: UIImage) async -> Bool {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            return true
        } catch {
            return false
        }
    }

    private func reopenInPlace() {
        guard let url = currentURL else { return }
        open(url, direct115: currentDirect115, directCookie: currentCookie, customHeaders: currentCustomHeaders,
             preservingPosition: true, refreshURL: urlRefresher, autoRecover: watchdogEnabled,
             openTimeoutSeconds: openTimeoutSeconds, streamID: currentStreamID,
             playlistRenew: currentPlaylistRenew, isTorrentStream: currentTorrentStream)
    }

    // MARK: 小窗播放

    /// 选的解码方式对应的 mpv 选项。小窗播放时画面由 CPU 出图，硬解码要把帧拷回内存（videotoolbox-copy）
    private var hwdecOption: String {
        guard decoding == .hardware else { return "no" }
        return pictureInPictureActive || pictureInPictureStarting ? "videotoolbox-copy" : "videotoolbox"
    }

    var pictureInPictureSupported: Bool { PictureInPictureSettings.supported }

    /// 给小窗截引导帧用
    var engineForPictureInPicture: MPVEngine? { engine }

    /// 播放画面下面垫着的小窗图层准备好了
    func attachPictureInPicture(layer: AVSampleBufferDisplayLayer) {
        guard PictureInPictureSettings.supported else { return }
        if let pictureInPicture, pictureInPicture.layer === layer { return }
        pictureInPicture?.stop()
        pictureInPicture = PlayerPictureInPicture(layer: layer, playback: self)
        pictureInPictureStillReady = false
        if hasPlayed {
            pictureInPictureStillReady = true
            pictureInPicture?.grabStill()
        }
    }

    /// 播放页上的小窗按钮
    func togglePictureInPicture() {
        guard let pictureInPicture else {
            notice = "这台设备不支持小窗播放"
            return
        }
        if pictureInPictureActive {
            pictureInPicture.stop()
        } else {
            guard loaded, error.isEmpty else {
                notice = "视频开始播放后才能开小窗"
                return
            }
            leaveAppAfterPictureInPicture = true
            pictureInPicture.start()
        }
    }

    func setAutoPictureInPicture(_ enabled: Bool) {
        autoPictureInPicture = enabled
        PictureInPictureSettings.automatic = enabled
        pictureInPicture?.setAutomatic(enabled)
    }

    /// 小窗马上要出现：把内核换成 CPU 出图，画面送进小窗图层
    func pictureInPictureWillStart() {
        pictureInPictureStarting = true
        guard let engine, let layer = pictureInPicture?.layer else { return }
        let hwdec = decoding == .hardware ? "videotoolbox-copy" : "no"
        let size = CGSize(width: Int(videoWidth), height: Int(videoHeight))
        logEvent("开始小窗播放")
        PlayerPictureInPicture.engineQueue.async { [weak self] in
            let switched = engine.startSoftwareOutput(layer: layer, hwdec: hwdec, videoSize: size)
            Task { @MainActor [weak self] in
                guard let self, !switched else { return }
                self.logEvent("小窗：切换到 CPU 出图失败")
                self.pictureInPicture?.stop()
            }
        }
    }

    func pictureInPictureDidStart() {
        pictureInPictureStarting = false
        pictureInPictureActive = true
        guard leaveAppAfterPictureInPicture else { return }
        leaveAppAfterPictureInPicture = false
        // 小窗飞出去的动画走完再回桌面，视频留在小窗里继续播
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, self.pictureInPictureActive,
                  UIApplication.shared.applicationState == .active else { return }
            Self.returnToHomeScreen()
        }
    }

    /// 回到桌面（和按 Home 键一样，App 只是退到后台）
    private static func returnToHomeScreen() {
        UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
    }

    /// 小窗结束。resume 为 true 表示用户点了「回到播放页」，接着播；直接关掉小窗则暂停（和系统播放器一样）
    func pictureInPictureDidStop(resume: Bool) {
        let wasActive = pictureInPictureActive || pictureInPictureStarting
        leaveAppAfterPictureInPicture = false
        pictureInPictureStarting = false
        pictureInPictureActive = false
        guard wasActive else { return }
        logEvent(resume ? "小窗回到播放页" : "关闭小窗")
        if !resume, playing {
            userPaused = true
            engine?.set("pause", true)
            updateFlags()
        }
        guard let engine else { return }
        let hwdec = hwdecOption
        let keepVideo = UIApplication.shared.applicationState != .background
        PlayerPictureInPicture.engineQueue.async {
            engine.stopSoftwareOutput(hwdec: hwdec, keepVideo: keepVideo)
        }
        // 下次开小窗前重新放一帧当前画面
        pictureInPictureStillReady = false
        if keepVideo {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let self, !self.pictureInPictureActive, self.loaded else { return }
                self.pictureInPictureStillReady = true
                self.pictureInPicture?.grabStill()
            }
        }
    }

    func pictureInPictureRenderSizeChanged(_ size: CGSize) {
        engine?.setSoftwareOutput(renderSize: size)
    }

    private func updatePictureInPictureVideoSize() {
        guard pictureInPictureActive || pictureInPictureStarting else { return }
        engine?.setSoftwareOutput(videoSize: CGSize(width: Int(videoWidth), height: Int(videoHeight)))
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
            handleFileLoadedForOnlineSubtitles()
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
            if !pictureInPictureStillReady, !pictureInPictureActive {
                // 系统要等小窗图层里有画面才允许开小窗：开播后先放一帧
                pictureInPictureStillReady = true
                pictureInPicture?.grabStill()
            }
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
            // 缓冲停顿或起播卡住时，只有明显上涨才算真正在缓冲，防止龟速保活导致看门狗死锁
            let growthThreshold = (pausedForCache || seeking || !loaded) ? 0.25 : 0.01
            if value > rawCachedSeconds + growthThreshold { dataSinceTick = true }
            rawCachedSeconds = value
            if abs(value - cachedSeconds) >= 0.5 || (value < 1 && cachedSeconds >= 1) { cachedSeconds = value }
        case ("cache-speed", .int(let value)):
            rawCacheSpeed = Int(max(0, value))
            let speed = Double(rawCacheSpeed)
            // 网速显示到小数点后一位，变化不到 5% 看不出来
            if speed != downloadSpeed, speed == 0 || downloadSpeed == 0 || abs(speed - downloadSpeed) >= downloadSpeed * 0.05 {
                downloadSpeed = speed
            }
            let healthyFloor = (pausedForCache || seeking || !loaded) ? Self.minHealthyCacheSpeedBytes : 1
            if value >= healthyFloor { dataSinceTick = true }
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
            updatePictureInPictureVideoSize()
        case ("video-params/w", .int(let value)):
            videoWidth = value
            limitBoostForVideo()
            updatePictureInPictureVideoSize()
        case ("video-params/sig-peak", .double(let value)):
            hdr = value > 1
            updateBadges()
        case ("video-params/aspect", .double(let value)):
            // 换文件、关画面时内核会报空值（不走这里），所以上一集的比例一直留到下一集出画面
            guard value.isFinite, value > 0.1, value < 10, abs(value - videoAspect) > 0.002 else { return }
            videoAspect = value
        case ("video-format", .string(let value)):
            let name = Self.codecName(value)
            if name != videoCodecName { videoCodecName = name }
        case ("audio-codec-name", .string(let value)):
            let name = Self.codecName(value)
            if name != audioCodecName { audioCodecName = name }
        case ("file-size", .int(let value)):
            if value > 0, value != fileSize { fileSize = value }
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
            if !pausedForCache || rawCacheSpeed >= Self.minHealthyCacheSpeedBytes {
                tier1RefreshAttemptedInStall = false
            }
        } else {
            noDataSeconds += 1
            // 一直没有新数据，界面上的网速也不要停在旧数字上
            if noDataSeconds >= 2, downloadSpeed > 0 { downloadSpeed = 0 }
        }
        dataSinceTick = false

        if loaded, playing, !pausedForCache, !seeking, !ended, error.isEmpty {
            healthyPlaybackSeconds += 1
            if healthyPlaybackSeconds >= 25, !recoveryAttempts.isEmpty {
                recoveryAttempts = []
            }
        } else {
            healthyPlaybackSeconds = 0
        }

        guard watchdogEnabled, recoveryTask == nil, currentURL != nil, error.isEmpty, !userPaused, !ended else { return }

        // 起播卡住（尚未 fileLoaded）：不等 45 秒总超时，6 秒先由中转静默切节点，14 秒未果直接重开
        if !loaded {
            openingSeconds += 1
            if openingSeconds >= 6, noDataSeconds >= 6, !tier1RefreshAttemptedInStall,
               let engineURL = currentEngineURL, LocalStreamProxy.shared.refreshActiveUpstream(for: engineURL) {
                tier1RefreshAttemptedInStall = true
                statusNote = "连接缓慢，正在切换节点…"
                return
            }
            if noDataSeconds >= 14 || (openingSeconds >= 18 && rawCacheSpeed < Self.minHealthyCacheSpeedBytes) {
                recover(reason: "起播超时")
            }
            return
        }
        openingSeconds = 0

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
        // Tier-1 静默切节点：缓冲停住 5 秒（或播放中余量不足 6 秒且断流 6 秒）先由中转无缝续传，保留 mpv 本地缓存
        let lowBufferStall = playing && !pausedForCache && !seeking && cachedSeconds < 6
            && (duration <= 0 || currentTime + cachedSeconds < duration - 5) && noDataSeconds >= 6
        if (hasPlayed && (pausedForCache || seeking) && noDataSeconds >= 5) || lowBufferStall {
            if !tier1RefreshAttemptedInStall, let engineURL = currentEngineURL,
               LocalStreamProxy.shared.refreshActiveUpstream(for: engineURL) {
                tier1RefreshAttemptedInStall = true
                engine?.set("cache-pause-wait", "2.5")
                if pausedForCache || seeking { statusNote = "正在切换高速节点…" }
                return
            }
        }
        // Tier-2 兜底重开：中转节点刷新仍未恢复，才停掉重连
        let reopenThreshold = tier1RefreshAttemptedInStall ? 10 : 8
        if hasPlayed, pausedForCache || seeking, noDataSeconds >= reopenThreshold {
            recover(reason: "网络卡住了")
        }
    }

    /// 停掉卡住的连接，换（新）地址从原位置重新打开；连续恢复期间保留已攒下的重连额度（稳定播放 25 秒自动重置）。
    private func recover(reason: String) {
        guard let url = currentURL, recoveryTask == nil else { return }
        cancelAddressResolution()
        let now = Date()
        if playedThisSession {
            recoveryAttempts = recoveryAttempts.filter { now.timeIntervalSince($0) < 120 }
        }
        guard recoveryAttempts.count < 5 else {
            engine?.command(["stop"])
            giveUp(reason.isEmpty ? "网络连接中断" : reason)
            return
        }
        recoveryAttempts.append(now)
        preferLargerPauseWait = true
        let position = pendingSeek ?? resumePoint
        logEvent("重连（\(reason.isEmpty ? "手动" : reason)）第 \(recoveryAttempts.count) 次，从 \(Self.clock(position))")
        let refresher = urlRefresher
        let direct115 = currentDirect115
        let cookie = currentCookie
        let customHeaders = currentCustomHeaders
        let currentSession = session
        openTimeoutTask?.cancel()
        // 刚打开就失败的第一次重试悄悄进行，不弹「打开失败」吓人；之后再说明在重连
        if recoveryAttempts.count == 1 && !hasPlayed {
            statusNote = ""
        } else {
            statusNote = reason.isEmpty ? "正在重新连接…" : "\(reason)，正在重新连接…"
        }
        engine?.command(["stop"])
        let backoff: [Double] = [0, 1, 2, 4, 6]
        let wait = backoff[min(recoveryAttempts.count - 1, backoff.count - 1)]
        recoveryTask = Task { @MainActor [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            var target = url
            if let refresher, let fresh = try? await refresher() { target = fresh }
            guard let self, !Task.isCancelled, self.session == currentSession else { return }
            self.recoveryTask = nil
            self.start(target, direct115: direct115, cookie: cookie, customHeaders: customHeaders, position: position, keepPlaying: !self.userPaused, keepDuration: true)
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
            : (currentTorrentStream ? "\(reason)，请点「重试」，或换一个节点较多的链接。" : "\(reason)，请点「重试」，或换一个画质。")
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
                                      streamID: String? = nil, renew: (() async throws -> URL)? = nil,
                                      playlistRenew: (() async throws -> URL)? = nil) async -> String {
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
        return await LocalStreamProxy.shared.localURL(for: url, headers: headers, streamID: streamID,
                                                      renew: renew, playlistRenew: playlistRenew)?.absoluteString ?? url.absoluteString
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
        let playback = playback
        controller.onGeometry = { [weak playback] picture, canvas in
            playback?.notePictureGeometry(picture: picture, canvas: canvas)
        }
        playback.attach(layer: controller.metalLayer)
        playback.attachPictureInPicture(layer: controller.pictureInPictureLayer)
        return controller
    }

    func updateUIViewController(_ controller: PlayerVideoViewController, context: Context) {
        // 播放状态每秒会刷新好几次，这里只在比例真的变了时才重新摆画面
        controller.setVideo(aspect: playback.displayAspect.map { CGFloat($0) }, stretch: playback.aspect == .stretch)
    }
}

extension Notification.Name {
    /// 播放画面所在页面的尺寸过渡（屏幕旋转）走完时发出，关闭播放器时用它判断什么时候可以收起页面。
    static let playerSizeTransitionDidFinish = Notification.Name("app.hplayer.playerSizeTransitionDidFinish")
}

final class PlayerVideoViewController: UIViewController {
    private let canvas = PlayerCanvasView()
    var metalLayer: MPVMetalLayer { canvas.metalLayer }
    /// 小窗（画中画）用的图层。系统要它里面有画面才允许开小窗，所以开播后会放进一帧；
    /// 小窗从它的位置飞出去、回来时也飞回这里。它不该被看见，由 `stillHost` 保证永远压在画面正下方。
    let pictureInPictureLayer: AVSampleBufferDisplayLayer = {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        return layer
    }()
    /// 装着小窗图层的小视图：位置、大小始终等于屏幕上「视频那一块」，所以总被上面的画面盖住。
    /// 以前小窗图层铺满整个容器，竖屏时画面比容器矮，上下各露出一条——露出来的就是开播时放进去的那一帧。
    private let stillHost = UIView()

    /// 画面图层固定用横屏尺寸渲染。MPVKit 的 iOS 渲染上下文不会把图层尺寸的变化告诉 mpv，
    /// 转到竖屏后 mpv 还按横屏的大小算画面位置，画面会被挤到左上角、右边被裁掉。
    /// 所以图层本身的尺寸始终不变，竖屏时把它等比缩小：缩到视频那一块正好放进小窗，
    /// 图层自带的左右黑边伸到小窗外面，被容器裁掉。
    private var renderSize = CGSize.zero
    /// 正在旋转：这段时间的画面位置和缩放只由旋转动画里的那一次设置决定，布局回调不插手，
    /// 否则布局先把终点值设上去，旋转动画就没有变化可以动了。
    private var transitioning = false
    /// 视频显示出来的宽高比；还没出画面时为空（按 16:9 摆）
    private var videoAspect: CGFloat?
    /// 画面比例选的是「拉伸」
    private var stretch = false
    /// 每次摆好位置后报告：视频那一块、整块画面图层各自在容器里的位置
    var onGeometry: ((CGRect, CGRect) -> Void)?

    override func loadView() {
        let container = UIView()
        container.backgroundColor = .black
        container.isUserInteractionEnabled = false
        // 竖屏时画面图层比小窗宽（多出来的是它自带的黑边），不能画到小窗外面
        container.clipsToBounds = true
        stillHost.backgroundColor = .black
        stillHost.isUserInteractionEnabled = false
        stillHost.clipsToBounds = true
        stillHost.layer.addSublayer(pictureInPictureLayer)
        container.addSubview(stillHost)
        container.addSubview(canvas)
        view = container
    }

    /// 视频的显示比例或「拉伸」模式变了：重新摆画面
    func setVideo(aspect: CGFloat?, stretch: Bool) {
        guard aspect != videoAspect || stretch != self.stretch else { return }
        videoAspect = aspect
        self.stretch = stretch
        guard isViewLoaded, !transitioning else { return }
        applyGeometry(in: view.bounds.size)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !transitioning else { return }
        applyGeometry(in: view.bounds.size)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        transitioning = true
        // 系统给的是整个窗口转完以后的大小：转成竖屏时画面只占顶部的小窗，要按小窗的大小来摆
        let target = PlayerVideoGeometry.container(afterTransitionTo: size, aspect: videoAspect)
        // 这个闭包由系统放进旋转动画里执行：center 和 transform 的变化会用和旋转一样的时长、曲线动起来，
        // 画面于是跟着界面一起转过去、缩放到竖屏的大小。
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.applyGeometry(in: target)
        }, completion: { [weak self] _ in
            guard let self else { return }
            self.transitioning = false
            self.applyGeometry(in: self.view.bounds.size)
            NotificationCenter.default.post(name: .playerSizeTransitionDidFinish, object: nil)
        })
    }

    /// 把横屏尺寸的画面缩放后放在容器正中。只改 center 和 transform，图层的 bounds 始终不变。
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
        let placement = PlayerVideoGeometry.placement(canvas: renderSize, container: container,
                                                      aspect: videoAspect, stretch: stretch)
        let center = CGPoint(x: container.width / 2, y: container.height / 2)
        canvas.center = center
        canvas.transform = CGAffineTransform(scaleX: placement.scaleX, y: placement.scaleY)
        // 小窗图层跟着视频那一块走（不超出容器），和画面用同一次设置，转屏时也一起动
        let shown = placement.shownSize
        stillHost.bounds = CGRect(x: 0, y: 0, width: min(shown.width, container.width), height: min(shown.height, container.height))
        stillHost.center = center
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pictureInPictureLayer.frame = stillHost.bounds
        CATransaction.commit()
        onGeometry?(stillHost.frame, canvas.frame)
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
