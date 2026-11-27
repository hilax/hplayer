import AVFoundation
import Combine
import Foundation

/// 投屏状态：未投屏 / DLNA（电视与盒子）/ AirPlay（隔空播放）。
enum CastMode: Equatable {
    case none
    case dlna(CastDevice)
    case airplay(deviceName: String)
}

/// 统一投屏调度中心：管理 DLNA 与 AirPlay 两种协议的生命周期、局域网中转、进度同步与控制指令。
@MainActor
final class CastManager: ObservableObject {
    @Published private(set) var mode: CastMode = .none
    @Published private(set) var isConnecting = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var volume: Int? = nil
    @Published private(set) var statusText = ""
    @Published private(set) var errorMessage = ""
    @Published private(set) var ended = false
    @Published var notice = ""

    let discovery: DLNADiscovery
    let airplay: AirPlayCastController

    var isCasting: Bool { mode != .none }

    var activeDeviceName: String {
        switch mode {
        case .none: return ""
        case .dlna(let device): return device.name
        case .airplay(let name): return name
        }
    }

    var activeDeviceID: String? {
        if case .dlna(let device) = mode { return device.id }
        return nil
    }

    var canAdjustVolume: Bool {
        if case .dlna(let device) = mode {
            return device.renderingControlURL != nil && volume != nil
        }
        return false
    }

    /// 投屏真正接管播放时触发：用于暂停本地 mpv。
    var onStartedCasting: (() -> Void)?
    /// 投屏过程中的时间同步（秒）：同步回 `PlaybackController` 与观看记录。
    var onPositionSync: ((Double, Double) -> Void)?
    /// 退出投屏时触发：`(是否恢复本地播放, 投屏最后的播放位置)`。
    var onStoppedCasting: ((Bool, Double) -> Void)?

    private let soap: DLNASoapClient
    private let server: CastMediaServer
    private let keepAlive: CastBackgroundKeepAlive
    private let enableKeepAlive: Bool
    private var cancellables: Set<AnyCancellable> = []
    private var pollTask: Task<Void, Never>?
    private var castSessionID = UUID()
    private var activeMedia: CastMediaDescriptor?
    private var pendingInitialSeek: Double?
    private var lastLocalSeekAt: Date = .distantPast
    private var dlnaHadPlayback = false

    init(
        discovery: DLNADiscovery? = nil,
        soap: DLNASoapClient = DLNASoapClient(),
        server: CastMediaServer = CastMediaServer(),
        airplay: AirPlayCastController? = nil,
        enableKeepAlive: Bool = true
    ) {
        self.discovery = discovery ?? DLNADiscovery()
        self.soap = soap
        self.server = server
        self.airplay = airplay ?? AirPlayCastController()
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        self.enableKeepAlive = enableKeepAlive && !isRunningTests
        self.keepAlive = CastBackgroundKeepAlive()
        bindAirPlay()
    }

    // MARK: - DLNA 投屏

    func castToDLNA(_ device: CastDevice, media: CastMediaDescriptor) async {
        let session = UUID()
        castSessionID = session
        pollTask?.cancel()
        pollTask = nil
        airplay.stop()

        activeMedia = media
        isConnecting = true
        errorMessage = ""
        ended = false
        dlnaHadPlayback = false
        currentTime = max(0, media.position)
        duration = max(0, media.duration)
        statusText = "正在连接 \(device.name)…"

        guard server.currentLANHost != nil else {
            isConnecting = false
            statusText = ""
            errorMessage = "请先连接与电视相同的 Wi-Fi 网络"
            return
        }

        guard let registered = await server.registerMedia(media) else {
            isConnecting = false
            statusText = ""
            errorMessage = "无法启动局域网投屏服务"
            return
        }
        guard castSessionID == session else { return }

        var subURL: URL?
        if let localSubtitle = media.subtitleFileURL {
            subURL = await server.registerSubtitle(fileURL: localSubtitle)
        }
        guard castSessionID == session else { return }

        // 先尝试停掉电视上残余的上一段会话（电视空闲时忽略错误）
        try? await soap.stop(device: device)
        guard castSessionID == session else { return }

        do {
            try await soap.setAVTransportURI(
                device: device,
                uri: registered.url,
                title: media.title,
                mimeType: registered.mimeType,
                subtitleURL: subURL
            )
            guard castSessionID == session else { return }
            try await soap.play(device: device)
            guard castSessionID == session else { return }
        } catch {
            guard castSessionID == session else { return }
            isConnecting = false
            isPlaying = false
            isBuffering = false
            statusText = ""
            errorMessage = error.userMessage
            return
        }

        pendingInitialSeek = media.position > 2 ? media.position : nil
        lastLocalSeekAt = .distantPast
        mode = .dlna(device)
        isConnecting = false
        isPlaying = true
        isBuffering = true
        statusText = "正在缓冲…"
        discovery.markUsed(device)
        onStartedCasting?()

        if enableKeepAlive {
            keepAlive.start()
        }

        volume = await soap.getVolume(device: device)
        guard castSessionID == session else { return }
        startDLNAPolling(for: device, session: session)
    }

    // MARK: - AirPlay 隔空播放

    func prepareAirPlay(
        media: CastMediaDescriptor,
        fallbackResolver: (() async -> CastResolvedStream?)? = nil
    ) async -> Bool {
        errorMessage = ""

        var effectiveMedia = media
        if !AirPlayCastController.isAirPlayNativelySupported(url: media.url) {
            if let fallback = await fallbackResolver?() {
                effectiveMedia = CastMediaDescriptor(
                    url: fallback.url,
                    localProxyURL: nil,
                    title: media.title,
                    headers: fallback.headers,
                    position: media.position,
                    duration: media.duration,
                    subtitleFileURL: media.subtitleFileURL,
                    isTorrentStream: false
                )
                if !fallback.qualityNotice.isEmpty {
                    notice = fallback.qualityNotice
                }
            } else {
                errorMessage = "隔空播放不支持当前视频格式，请选择上方 DLNA 设备投屏"
                return false
            }
        }

        guard server.currentLANHost != nil,
              let registered = await server.registerMedia(effectiveMedia) else {
            errorMessage = "请先连接 Wi-Fi 网络后使用隔空播放"
            return false
        }

        activeMedia = effectiveMedia
        currentTime = max(0, effectiveMedia.position)
        duration = max(0, effectiveMedia.duration)
        ended = false
        airplay.prepareAndLoad(url: registered.url, startTime: effectiveMedia.position, autoPlayOnExternal: true)
        return true
    }

    // MARK: - 切集 / 换画质同步

    func updateMedia(
        _ media: CastMediaDescriptor,
        fallbackResolver: (() async -> CastResolvedStream?)? = nil
    ) async {
        activeMedia = media
        switch mode {
        case .none:
            return
        case .dlna(let device):
            await castToDLNA(device, media: media)
        case .airplay:
            _ = await prepareAirPlay(media: media, fallbackResolver: fallbackResolver)
        }
    }

    // MARK: - 遥控操作

    func togglePlayPause() {
        switch mode {
        case .none:
            return
        case .dlna(let device):
            let shouldPause = isPlaying
            isPlaying = !shouldPause
            statusText = shouldPause ? "已暂停" : "正在播放"
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    if shouldPause {
                        try await self.soap.pause(device: device)
                    } else {
                        try await self.soap.play(device: device)
                    }
                } catch {
                    self.errorMessage = error.userMessage
                }
            }
        case .airplay:
            airplay.togglePlayPause()
        }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        let target = duration > 0 ? min(seconds, max(0, duration - 1)) : seconds
        currentTime = target
        ended = false
        lastLocalSeekAt = Date()
        pendingInitialSeek = nil

        switch mode {
        case .none:
            return
        case .dlna(let device):
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.soap.seek(device: device, to: target)
                } catch {
                    self.errorMessage = error.userMessage
                }
            }
        case .airplay:
            airplay.seek(to: target)
        }
    }

    func adjustVolume(delta: Int) {
        let base = volume ?? 50
        setVolume(base + delta)
    }

    func setVolume(_ desired: Int) {
        guard case .dlna(let device) = mode else { return }
        let clamped = min(max(desired, 0), 100)
        volume = clamped
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.soap.setVolume(device: device, volume: clamped)
        }
    }

    func retry(fallbackResolver: (() async -> CastResolvedStream?)? = nil) async {
        guard let media = activeMedia else { return }
        let resumeMedia = CastMediaDescriptor(
            url: media.url,
            localProxyURL: media.localProxyURL,
            title: media.title,
            headers: media.headers,
            position: currentTime,
            duration: duration,
            subtitleFileURL: media.subtitleFileURL,
            isTorrentStream: media.isTorrentStream
        )
        switch mode {
        case .none:
            return
        case .dlna(let device):
            await castToDLNA(device, media: resumeMedia)
        case .airplay:
            _ = await prepareAirPlay(media: resumeMedia, fallbackResolver: fallbackResolver)
        }
    }

    func cancelPendingAirPlay() {
        guard !isCasting else { return }
        airplay.stop()
        server.stop()
        errorMessage = ""
    }

    func stopCasting(resumeLocal: Bool) {
        let oldMode = mode
        let finalTime = currentTime
        castSessionID = UUID()
        pollTask?.cancel()
        pollTask = nil
        keepAlive.stop()

        mode = .none
        isConnecting = false
        isPlaying = false
        isBuffering = false
        statusText = ""
        errorMessage = ""
        volume = nil
        ended = false
        pendingInitialSeek = nil
        dlnaHadPlayback = false

        switch oldMode {
        case .none:
            server.stop()
            return
        case .dlna(let device):
            let soapClient = soap
            let mediaServer = server
            Task {
                try? await soapClient.stop(device: device)
                mediaServer.stop()
            }
        case .airplay:
            airplay.stop()
            server.stop()
        }

        onStoppedCasting?(resumeLocal, finalTime)
    }

    // MARK: - 内部绑定与轮询

    private func bindAirPlay() {
        airplay.onExternalPlaybackStarted = { [weak self] name in
            guard let self else { return }
            self.pollTask?.cancel()
            self.pollTask = nil
            self.keepAlive.stop()
            self.isConnecting = false
            self.mode = .airplay(deviceName: name)
            self.statusText = "正在通过隔空播放"
            self.onStartedCasting?()
        }

        airplay.onExternalPlaybackEnded = { [weak self] in
            guard let self, case .airplay = self.mode else { return }
            self.stopCasting(resumeLocal: true)
        }

        airplay.onPositionChanged = { [weak self] time, total in
            guard let self, case .airplay = self.mode else { return }
            self.currentTime = time
            if total > 0 { self.duration = total }
            self.onPositionSync?(self.currentTime, self.duration)
        }

        airplay.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in
                guard let self, case .airplay = self.mode else { return }
                self.isPlaying = playing
                if playing {
                    self.statusText = "正在播放"
                } else if !self.isBuffering {
                    self.statusText = "已暂停"
                }
            }
            .store(in: &cancellables)

        airplay.$isBuffering
            .receive(on: DispatchQueue.main)
            .sink { [weak self] buffering in
                guard let self, case .airplay = self.mode else { return }
                self.isBuffering = buffering
                if buffering { self.statusText = "正在缓冲…" }
            }
            .store(in: &cancellables)

        airplay.$ended
            .receive(on: DispatchQueue.main)
            .sink { [weak self] didEnd in
                guard let self, case .airplay = self.mode, didEnd else { return }
                self.ended = true
            }
            .store(in: &cancellables)

        airplay.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self, case .airplay = self.mode, !message.isEmpty else { return }
                self.errorMessage = message
            }
            .store(in: &cancellables)
    }

    private func startDLNAPolling(for device: CastDevice, session: UUID) {
        pollTask = Task { @MainActor [weak self] in
            var consecutiveFailures = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled, self.castSessionID == session,
                      case .dlna = self.mode else { return }

                do {
                    let state = try await self.soap.getTransportInfo(device: device)
                    guard self.castSessionID == session else { return }
                    let posInfo = try? await self.soap.getPositionInfo(device: device)
                    guard self.castSessionID == session else { return }

                    consecutiveFailures = 0
                    self.errorMessage = ""

                    if let posInfo {
                        if posInfo.duration > 0 {
                            self.duration = posInfo.duration
                        }
                        let recentlySeeked = Date().timeIntervalSince(self.lastLocalSeekAt) < 1.5
                        let nearNaturalEnd = (state == .stopped || state == .noMedia)
                            && self.dlnaHadPlayback
                            && self.duration > 10
                            && self.currentTime >= self.duration - 5
                            && posInfo.relTime == 0
                        if self.pendingInitialSeek == nil && !recentlySeeked && !nearNaturalEnd && posInfo.relTime >= 0 {
                            self.currentTime = posInfo.relTime
                        }
                    }

                    switch state {
                    case .playing:
                        self.isPlaying = true
                        self.isBuffering = false
                        self.dlnaHadPlayback = true
                        self.statusText = "正在播放"
                        if let initialSeek = self.pendingInitialSeek {
                            self.pendingInitialSeek = nil
                            try? await self.soap.seek(device: device, to: initialSeek)
                        }
                    case .transitioning:
                        self.isPlaying = false
                        self.isBuffering = true
                        self.statusText = "正在缓冲…"
                    case .paused:
                        self.isPlaying = false
                        self.isBuffering = false
                        self.statusText = "已暂停"
                    case .stopped, .noMedia:
                        self.isPlaying = false
                        self.isBuffering = false
                        self.statusText = "已停止"
                        if self.dlnaHadPlayback, self.duration > 10, self.currentTime >= self.duration - 5 {
                            self.ended = true
                        }
                    case .unknown:
                        break
                    }

                    self.onPositionSync?(self.currentTime, self.duration)
                } catch {
                    consecutiveFailures += 1
                    if consecutiveFailures >= 5 {
                        self.errorMessage = "与电视连接不稳定：\(error.userMessage)"
                    }
                }
            }
        }
    }
}

/// 投屏期间维持后台静音音频会话，避免锁屏或退后台后系统立即冻结 `CastMediaServer` 的局域网拉流连接。
private final class CastBackgroundKeepAlive {
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var active = false

    func start() {
        guard !active else { return }
        active = true
        PlayerAudioSession.activate()

        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)
        let node = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in list {
                if let ptr = buffer.mData {
                    memset(ptr, 0, Int(buffer.mDataByteSize))
                }
            }
            return noErr
        }
        engine.attach(node)
        if let format {
            engine.connect(node, to: engine.mainMixerNode, format: format)
        } else {
            engine.connect(node, to: engine.mainMixerNode, format: nil)
        }
        engine.mainMixerNode.outputVolume = 0
        do {
            try engine.start()
            self.engine = engine
            self.sourceNode = node
        } catch {
            engine.stop()
            active = false
        }
    }

    func stop() {
        guard active else { return }
        active = false
        engine?.stop()
        if let sourceNode {
            engine?.detach(sourceNode)
        }
        sourceNode = nil
        engine = nil
    }
}
