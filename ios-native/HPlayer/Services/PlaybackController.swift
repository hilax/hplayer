import AVFoundation
import Foundation
import Libmpv
import Network
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
    @Published private(set) var decoding = VideoDecoding.saved
    @Published private(set) var readahead = ReadaheadLevel.saved
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
    /// 内核报告的真实播放时间（不含正在跳转的目标），给 UI 测试读
    @Published private(set) var engineTime: Double = 0

    private var engine: MPVEngine?
    private weak var layer: CAMetalLayer?
    private var pendingOpen: (() -> Void)?

    private var currentURL: URL?
    private var currentDirect115 = false
    private var currentCookie = ""
    private var urlRefresher: (() async throws -> URL)?
    private var watchdogEnabled = true
    private var openTimeoutSeconds: UInt64 = 20

    /// 用户自己按了暂停
    private var userPaused = false
    private var boosted = false
    private var loaded = false
    private var opening = false
    private var pausedForCache = false
    private var seeking = false
    private var eofReached = false
    private var hasPlayed = false
    private var pendingSeek: Double?
    private var pendingSeekStarted = Date.distantPast
    private var resumePoint: Double = 0
    private var videoHeight: Int64 = 0
    private var hdr = false

    /// 内核最近的警告和错误
    private var logLines: [String] = []
    private var openTimeoutTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryAttempts: [Date] = []
    private var noDataSeconds = 0
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
        Self.clearDiskCache()
    }

    deinit {
        network.cancel()
        backgroundObservers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: 画面

    /// 播放画面所在的图层准备好了；第一次时创建内核
    func attach(layer: CAMetalLayer) {
        self.layer = layer
        if let engine {
            engine.attach(layer: layer)
        } else {
            createEngine(layer: layer)
        }
        if let pendingOpen {
            self.pendingOpen = nil
            pendingOpen()
        }
    }

    private func createEngine(layer: CAMetalLayer) {
        var options: [(String, String)] = [
            ("config", "no"),
            ("load-scripts", "no"),
            ("ytdl", "no"),
            ("input-default-bindings", "no"),
            ("idle", "yes"),
            ("keep-open", "yes"),
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", decoding == .hardware ? "videotoolbox" : "no"),
            ("video-rotate", "no"),
            ("audio-display", "no"),
            ("sub-auto", "fuzzy"),
            ("subs-fallback", "yes"),
            ("slang", "zh,chi,zho,chs,sc,cht,tc,en,eng"),
            ("screenshot-format", "jpg"),
            // 网络：连接或读取 10 秒没反应就算超时，断了自动重连
            ("network-timeout", "10"),
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
            ("demuxer-cache-dir", Self.cacheDirectory.path),
            ("demuxer-max-back-bytes", "256MiB"),
        ]
        if UIScreen.main.potentialEDRHeadroom > 1 {
            options.append(("target-colorspace-hint", "yes"))
        }
        guard let engine = MPVEngine(options: options, layer: layer) else {
            error = "播放内核启动失败"
            return
        }
        engine.onEvent = { [weak self] event in self?.handle(event) }
        for (name, format) in Self.observed {
            engine.observe(name, format)
        }
        self.engine = engine
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
        ("video-params/sig-peak", MPV_FORMAT_DOUBLE),
        ("mute", MPV_FORMAT_FLAG),
    ]

    // MARK: 打开

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
        if !preservingPosition {
            aspect = .fit
            zoom = 1
        }
        start(url, direct115: direct115, cookie: directCookie, position: position, keepPlaying: keepPlaying, keepDuration: preservingPosition)
    }

    private func start(_ url: URL, direct115: Bool, cookie: String, position: Double, keepPlaying: Bool, keepDuration: Bool) {
        currentURL = url
        currentDirect115 = direct115
        currentCookie = cookie
        resetState(keepDuration: keepDuration)
        resumePoint = position
        if position > 0 {
            currentTime = position
            pendingSeek = position
            pendingSeekStarted = Date()
        }
        userPaused = !keepPlaying
        playing = keepPlaying
        buffering = true
        opening = true
        guard let engine else {
            // 画面还没准备好：等图层交过来再打开
            pendingOpen = { [weak self] in
                self?.start(url, direct115: direct115, cookie: cookie, position: position, keepPlaying: keepPlaying, keepDuration: keepDuration)
            }
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        engine.set("hwdec", decoding == .hardware ? "videotoolbox" : "no")
        applyCacheOptions(engine)
        engine.set("user-agent", direct115 ? Direct115Client.userAgent : "HPlayer")
        engine.set("referrer", direct115 ? "https://115.com/" : "")
        let cookieHeader = Self.cookieHeader(cookie)
        engine.set("http-header-fields", direct115 && !cookieHeader.isEmpty ? "Cookie: \(cookieHeader)" : "")
        engine.set("start", position > 0 ? String(format: "%.3f", position) : "none")
        engine.set("pause", !keepPlaying)
        engine.set("speed", Double(rate))
        applyAspect(engine)
        engine.command(["loadfile", url.isFileURL ? url.path : url.absoluteString, "replace"])
        startWatchdog()

        let timeout = openTimeoutSeconds
        let currentSession = session
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

    private func resetState(keepDuration: Bool) {
        openTimeoutTask?.cancel()
        pendingSeek = nil
        boosted = false
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
        downloadSpeed = 0
        lastPublishedTime = -1
        if !keepDuration {
            duration = 0
            currentTime = 0
            audioTracks = []
            subtitleTracks = []
            selectedAudio = nil
            selectedSubtitle = nil
            videoBadges = []
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
        engine.set("demuxer-max-bytes", "\(Self.diskCacheLimitMiB())MiB")
    }

    // MARK: 播放控制

    func toggle() {
        if playing {
            userPaused = true
            engine?.set("pause", true)
        } else {
            userPaused = false
            noDataSeconds = 0
            if eofReached, duration > 0, resumePoint >= duration - 5 {
                // 真的播完了：从头开始
                resumePoint = 0
                ended = false
                engine?.command(["seek", "0", "absolute"])
                engine?.set("pause", false)
            } else if !loaded, currentURL != nil, recoveryTask == nil, !opening || !error.isEmpty {
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
        guard seconds.isFinite, seconds >= 0 else { return }
        let target = duration > 0 ? min(seconds, max(0, duration - 0.5)) : seconds
        resumePoint = target
        currentTime = target
        if currentURL != nil, recoveryTask != nil || (!loaded && !opening) {
            // 连接已经断了或正在重连：直接从新的目标位置重新打开
            recoveryTask?.cancel()
            recoveryTask = nil
            recoveryAttempts = []
            recover(reason: "")
            return
        }
        guard seekable else { return }
        pendingSeek = target
        pendingSeekStarted = Date()
        noDataSeconds = 0
        // 大跨度跳转只落到关键帧，4K 原画也能很快开播；小跳转精确到帧
        let far = abs(target - engineTime) > 60
        engine?.command(["seek", String(format: "%.3f", target), far ? "absolute+keyframes" : "absolute+exact"])
        updateFlags()
    }

    func skip(_ seconds: Double) { seek(to: max(0, currentTime + seconds)) }

    func setRate(_ value: Float) {
        rate = value
        if !boosted { engine?.set("speed", Double(value)) }
    }

    /// 长按快进：画面和声音一起 3× 加速（mpv 自动保持音调）
    func setBoost(_ enabled: Bool) {
        guard boosted != enabled else { return }
        boosted = enabled
        engine?.set("speed", Double(enabled ? Self.boostRate : rate))
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
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("hplayer-shot-\(UUID().uuidString).jpg").path
        guard engine.command(["screenshot-to-file", path, "video"]) >= 0 else { return false }
        for _ in 0..<20 {
            if FileManager.default.fileExists(atPath: path), let image = UIImage(contentsOfFile: path) {
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                try? FileManager.default.removeItem(atPath: path)
                return true
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
            loaded = true
            opening = false
            openTimeoutTask?.cancel()
            refreshTracks()
        case .playbackRestart:
            hasPlayed = true
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
            engineTime = time
            if let pending = pendingSeek {
                if abs(time - pending) < 2 || !seeking && Date().timeIntervalSince(pendingSeekStarted) > 6 {
                    pendingSeek = nil
                }
            }
            if pendingSeek == nil {
                if abs(time - lastPublishedTime) >= 0.25 || time < lastPublishedTime {
                    lastPublishedTime = time
                    currentTime = time
                }
                if time > 0 { resumePoint = time }
            }
            checkFailedSeek(time)
        case ("duration", .double(let value)):
            if value.isFinite, value > 0 { duration = value }
        case ("pause", .flag(let paused)):
            // 内核在缓存不够时不会改 pause；这里的变化来自用户或打开时的设定
            if paused != userPaused, loaded { userPaused = paused }
        case ("paused-for-cache", .flag(let value)):
            pausedForCache = value
        case ("seeking", .flag(let value)):
            seeking = value
        case ("eof-reached", .flag(let value)):
            eofReached = value
            if value { handleReachedEnd() }
        case ("seekable", .flag(let value)):
            seekable = value
        case ("demuxer-cache-time", .double(let value)):
            bufferedUntil = value
        case ("demuxer-cache-duration", .double(let value)):
            cachedSeconds = value
        case ("cache-speed", .int(let value)):
            downloadSpeed = Double(max(0, value))
            if value > 0 { noDataSeconds = 0 }
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
            updateBadges()
        case ("video-params/sig-peak", .double(let value)):
            hdr = value > 1
            updateBadges()
        case ("mute", .flag(let value)):
            muted = value
        default:
            break
        }
    }

    private func handleReachedEnd() {
        guard duration > 0 else { return }
        if resumePoint >= duration - 5 || engineTime >= duration - 5 {
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
        guard reason != stopped else { return }
        loaded = false
        if reason == failed {
            if watchdogEnabled, currentURL != nil {
                recover(reason: hasPlayed ? "网络连接断了" : "视频打开失败")
            } else {
                giveUp(message.map { "播放失败：\($0)" } ?? "播放失败，请尝试其他画质或检查网络")
            }
        }
    }

    /// 跳转根本没生效（例如服务器拒绝了跳转用的新连接，还在按原来的位置播）：从目标位置重新打开
    private func checkFailedSeek(_ time: Double) {
        guard let pending = pendingSeek, watchdogEnabled, recoveryTask == nil, !seeking,
              Date().timeIntervalSince(pendingSeekStarted) > 5, abs(time - pending) > 20 else { return }
        pendingSeek = nil
        resumePoint = pending
        recover(reason: "跳转没有成功")
    }

    private func updateFlags() {
        let newBuffering = error.isEmpty && (recoveryTask != nil || opening || pausedForCache || (seeking && !userPaused))
        if newBuffering != buffering { buffering = newBuffering }
        let newPlaying = !userPaused && error.isEmpty && !(eofReached && ended)
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
        if downloadSpeed <= 0 { noDataSeconds += 1 }
        guard watchdogEnabled, recoveryTask == nil, currentURL != nil, error.isEmpty, !userPaused, loaded else { return }
        if pendingSeek != nil, Date().timeIntervalSince(pendingSeekStarted) >= 7, noDataSeconds >= 5, seeking || pausedForCache {
            recover(reason: "跳转后网络没有响应")
            return
        }
        if hasPlayed, pausedForCache, noDataSeconds >= 15 {
            recover(reason: "网络卡住了")
        }
    }

    /// 停掉卡住的连接，换（新）地址从原位置重新打开。90 秒内最多自动试 3 次，之后提示用户点重试。
    private func recover(reason: String) {
        guard let url = currentURL, recoveryTask == nil else { return }
        let now = Date()
        recoveryAttempts = recoveryAttempts.filter { now.timeIntervalSince($0) < 90 }
        guard recoveryAttempts.count < 3 else {
            engine?.command(["stop"])
            giveUp(reason.isEmpty ? "网络连接中断" : reason)
            return
        }
        recoveryAttempts.append(now)
        let position = pendingSeek ?? resumePoint
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
        recoveryTask = Task { @MainActor [weak self] in
            var target = url
            if let refresher, let fresh = try? await refresher() { target = fresh }
            guard let self, !Task.isCancelled, self.session == currentSession else { return }
            self.recoveryTask = nil
            self.start(target, direct115: direct115, cookie: cookie, position: position, keepPlaying: !self.userPaused, keepDuration: true)
        }
        updateFlags()
    }

    private func giveUp(_ reason: String) {
        openTimeoutTask?.cancel()
        recoveryTask?.cancel()
        recoveryTask = nil
        statusNote = ""
        opening = false
        loaded = false
        error = resumePoint > 1
            ? "\(reason)，自动重连几次都没成功。点「重试」会从 \(Self.clock(resumePoint)) 接着播放。"
            : "\(reason)，请点「重试」，或换一个画质。"
        updateFlags()
    }

    /// 播放出问题时复制给开发者的诊断信息：地址类型、状态和内核最近的警告错误
    var diagnostics: String {
        var lines = [
            "HPlayer 播放诊断",
            "地址：\(currentURL.map { "\($0.scheme ?? "")://\($0.host ?? "")\($0.path.suffix(40))" } ?? "无")",
            "115：\(currentDirect115) 解码：\(decoding.rawValue) 缓存：\(readahead.rawValue)s",
            "状态：loaded=\(loaded) opening=\(opening) playedOnce=\(hasPlayed) cache=\(pausedForCache) seeking=\(seeking) speed=\(Int(downloadSpeed)) cached=\(Int(cachedSeconds))s",
            "错误：\(error)",
            "—— 内核日志 ——",
        ]
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

    private static var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = caches.appendingPathComponent("PlayerCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 上次没清掉的缓存文件（例如 App 被系统结束）
    private static func clearDiskCache() {
        let directory = cacheDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// 最多 2GB；手机剩余空间不多时只用剩余空间的一半
    private static func diskCacheLimitMiB() -> Int {
        let limit = 2048
        let values = try? cacheDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage, free > 0 else { return limit }
        let half = Int(free / 2 / 1_048_576)
        return max(64, min(limit, half))
    }

    private static func cookieHeader(_ header: String) -> String {
        header.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { pair in
                guard let equals = pair.firstIndex(of: "=") else { return false }
                let name = String(pair[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return !name.isEmpty && !["path", "domain", "expires", "max-age", "samesite"].contains(name)
            }
            .joined(separator: "; ")
            .replacingOccurrences(of: ",", with: "%2C")
    }

    static func clock(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
    }
}

// MARK: - 播放画面

/// mpv 把画面画在这个视图的 Metal 图层上
struct PlayerVideoSurface: UIViewRepresentable {
    @ObservedObject var playback: PlaybackController

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        playback.attach(layer: view.metalLayer)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {}
}

final class PlayerLayerView: UIView {
    let metalLayer = MPVMetalLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(metalLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        metalLayer.contentsScale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        CATransaction.commit()
    }
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
