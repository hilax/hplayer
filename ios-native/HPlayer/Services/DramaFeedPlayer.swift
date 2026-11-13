import AVFoundation
import Combine
import SwiftUI

/// 竖屏短剧播放器里的一集：一个 AVPlayer，负责取播放地址、续播位置、播放进度和画面尺寸。
/// 同一时间最多留三集（当前集和前后各一集），前后两集提前缓冲好，翻页时立刻有画面。
@MainActor
final class DramaEpisodePlayer: ObservableObject {
    enum State: Equatable {
        case idle, loading, ready
        case failed(String)
    }

    let ref: DramaEpisodeRef
    let player = AVPlayer()

    @Published private(set) var state: State = .idle
    /// 视频画面的像素尺寸；没拿到之前是 .zero（按竖屏处理）
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var finished = false

    /// 播完一集时调用（翻到下一集）
    var onFinished: (() -> Void)?

    var source: PlaybackSource { .drama(ref) }
    /// 取当前画面用：暂停和离开时截一帧给「继续观看」当封面
    private var frameOutput: AVPlayerItemVideoOutput?
    var isPortraitVideo: Bool { videoSize == .zero || videoSize.height >= videoSize.width }

    private var wantsPlay = false
    private var rate: Float = 1
    private var pendingSeek: Double?
    private var loadTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var observations: [NSKeyValueObservation] = []
    private var lastSaved = Date.distantPast

    init(ref: DramaEpisodeRef) {
        self.ref = ref
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .pause
        player.preventsDisplaySleepDuringVideoPlayback = true
        observePlayer()
    }

    // MARK: 加载

    /// 取播放地址并开始缓冲；已经在加载或加载过就什么都不做。
    func prepare() {
        guard state == .idle || isFailed else { return }
        state = .loading
        finished = false
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.load() }
    }

    func retry() {
        state = .idle
        prepare()
        if wantsPlay { play() }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func load() async {
        do {
            // 地址带时效签名，每次现取，不缓存
            let playback = try await DramaClient.shared.playback(videoId: ref.videoId, episode: ref.episode)
            guard !Task.isCancelled else { return }
            let asset = AVURLAsset(url: playback.url, options: ["AVURLAssetHTTPHeaderFieldsKey": playback.headers])
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 10
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(output)
            frameOutput = output
            pendingSeek = RecentStore.shared.position(for: source)
            observe(item)
            player.replaceCurrentItem(with: item)
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed((error as? LocalizedError)?.errorDescription ?? "这一集暂时播放不了")
        }
    }

    private func observePlayer() {
        observations.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor [weak self] in
                self?.isPlaying = status == .playing
                self?.isBuffering = status == .waitingToPlayAtSpecifiedRate
            }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in self?.tick(time) }
        }
    }

    private func observe(_ item: AVPlayerItem) {
        observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor [weak self] in self?.statusChanged(status, message: message) }
        })
        observations.append(item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            let size = item.presentationSize
            Task { @MainActor [weak self] in
                if size.width > 0, size.height > 0 { self?.videoSize = size }
            }
        })
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                             queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.didFinish() }
        }
    }

    private func statusChanged(_ status: AVPlayerItem.Status, message: String?) {
        switch status {
        case .readyToPlay:
            guard state != .ready else { return }
            state = .ready
            if let seconds = pendingSeek, seconds > 1 {
                player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            pendingSeek = nil
            if wantsPlay { startPlayback() }
        case .failed:
            state = .failed(message ?? "视频加载失败")
        default:
            break
        }
    }

    private func tick(_ time: CMTime) {
        let seconds = time.seconds
        if seconds.isFinite { currentTime = max(0, seconds) }
        if let total = player.currentItem?.duration.seconds, total.isFinite, total > 0 { duration = total }
        // 播放中每 5 秒存一次续播位置，被系统杀掉也不会丢太多
        if isPlaying, Date().timeIntervalSince(lastSaved) > 5 { savePosition() }
    }

    private func didFinish() {
        finished = true
        savePosition(reachedEnd: true)
        onFinished?()
    }

    // MARK: 控制

    func play() {
        wantsPlay = true
        prepare()
        if state == .ready { startPlayback() }
    }

    private func startPlayback() {
        if finished {
            finished = false
            player.seek(to: .zero)
        }
        RecentStore.shared.record(source)
        ref.rememberAsLastWatched()
        player.playImmediately(atRate: rate)
    }

    func pause() {
        wantsPlay = false
        player.pause()
        savePosition()
        captureResumeFrame()
    }

    /// 把当前画面存成这一集在「继续观看」里的封面
    private func captureResumeFrame() {
        guard state == .ready, currentTime > 3, !finished, let output = frameOutput,
              let buffer = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) else { return }
        PlaybackFrameStore.shared.ingest(pixelBuffer: buffer, for: PlaybackFrameStore.key(for: source))
    }

    func togglePlay() {
        if isPlaying || (wantsPlay && isBuffering) { pause() } else { play() }
    }

    /// 倍速（长按快进、倍速按钮）。不在播放时只记下来，开播时生效。
    func setRate(_ value: Float) {
        rate = value
        if isPlaying || (wantsPlay && isBuffering) { player.rate = value }
    }

    var currentRate: Float { rate }

    func seek(to seconds: Double) {
        guard duration > 0 else { return }
        let target = min(max(0, seconds), duration - 0.5)
        currentTime = target
        finished = false
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func savePosition(reachedEnd: Bool = false) {
        guard duration > 0 else { return }
        lastSaved = Date()
        RecentStore.shared.savePosition(for: source, seconds: reachedEnd ? duration : currentTime, duration: duration)
    }

    /// 离开播放器或这一集被回收时调用：存好进度，停下并释放网络连接。
    func tearDown() {
        if state == .ready { savePosition(); captureResumeFrame() }
        wantsPlay = false
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        observations.removeAll()
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        state = .idle
    }
}

/// 一部短剧的竖屏连播：当前第几集，以及前后各一集的播放器。
@MainActor
final class DramaFeedModel: ObservableObject {
    let detail: DramaDetail
    @Published private(set) var index: Int
    @Published var speed: Float = 1
    private var players: [Int: DramaEpisodePlayer] = [:]

    init(detail: DramaDetail, startIndex: Int) {
        self.detail = detail
        index = min(max(0, startIndex), max(0, detail.episodes.count - 1))
    }

    var count: Int { detail.episodes.count }
    var current: DramaEpisodePlayer? { players[index] }

    func episode(at position: Int) -> DramaEpisode? {
        detail.episodes.indices.contains(position) ? detail.episodes[position] : nil
    }

    /// 某一集的播放器（只给当前集和前后各一集建）
    func player(at position: Int) -> DramaEpisodePlayer? {
        guard let episode = episode(at: position) else { return nil }
        if let existing = players[position] { return existing }
        guard abs(position - index) <= 1 else { return nil }
        let player = DramaEpisodePlayer(ref: DramaEpisodeRef(videoId: detail.id, seriesName: detail.title, episode: episode.number))
        player.onFinished = { [weak self] in self?.episodeFinished(position) }
        players[position] = player
        return player
    }

    /// 翻到第 position 集：它开始播，前后两集提前缓冲（暂停着），更远的释放掉。
    func show(_ position: Int) {
        guard episode(at: position) != nil else { return }
        let previous = index
        index = position
        if previous != position { players[previous]?.pause() }
        for (key, player) in players where abs(key - position) > 1 {
            player.tearDown()
            players.removeValue(forKey: key)
        }
        for neighbor in [position - 1, position + 1] {
            if let player = player(at: neighbor) {
                player.pause()
                player.prepare()
            }
        }
        if let player = player(at: position) {
            player.setRate(speed)
            player.play()
        }
    }

    func setSpeed(_ value: Float) {
        speed = value
        current?.setRate(value)
    }

    func pauseCurrent() { current?.pause() }

    func tearDownAll() {
        for player in players.values { player.tearDown() }
        players.removeAll()
    }

    /// 播完自动翻到下一集；最后一集播完就停在结尾。
    var onAdvance: ((Int) -> Void)?

    private func episodeFinished(_ position: Int) {
        guard position == index, position + 1 < count else { return }
        onAdvance?(position + 1)
    }
}
