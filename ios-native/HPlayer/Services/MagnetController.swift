import Combine
import Foundation

/// 所有磁力页面共用一个 BT 引擎。
///
/// 进入磁力页面时就启动引擎，DHT 在用户粘贴链接的这段时间里先热起来；
/// 页面都关闭 20 秒后再关引擎，关闭时引擎会把 DHT 节点表和已解析的种子信息存到本机，
/// 下次打开同一个链接可以直接读到文件列表。
@MainActor
final class MagnetEngineHost {
    static let shared = MagnetEngineHost()

    private var runningEngine: NuvioEngine?
    private var creating: Task<NuvioEngine, Error>?
    private var shuttingDown: Task<Void, Never>?
    private var idleShutdown: Task<Void, Never>?
    private var users = 0

    var isRunning: Bool { runningEngine != nil }

    func acquire() {
        users += 1
        idleShutdown?.cancel()
        idleShutdown = nil
    }

    func release() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        idleShutdown?.cancel()
        idleShutdown = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.shutdownIfIdle()
        }
    }

    func engine() async throws -> NuvioEngine {
        if let runningEngine { return runningEngine }
        if let creating { return try await creating.value }
        let previousShutdown = shuttingDown
        let task = Task<NuvioEngine, Error> {
            await previousShutdown?.value
            return try await NuvioEngine.create(configuration: try Self.configuration())
        }
        creating = task
        do {
            let created = try await task.value
            if runningEngine == nil { runningEngine = created }
            creating = nil
            return runningEngine ?? created
        } catch {
            creating = nil
            throw error
        }
    }

    private func shutdownIfIdle() async {
        guard users == 0 else { return }
        var candidate = runningEngine
        if candidate == nil, let creating { candidate = try? await creating.value }
        guard users == 0, let current = candidate else { return }
        runningEngine = nil
        creating = nil
        let task = Task { await current.shutdown() }
        shuttingDown = task
        await task.value
    }

    private static func configuration() throws -> NuvioEngineConfiguration {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw APIError.server("无法创建本机缓存")
        }
        let root = caches.appendingPathComponent("HPlayerMagnet", isDirectory: true)
        let data = root.appendingPathComponent("state", isDirectory: true)
        let pieces = root.appendingPathComponent("pieces", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pieces, withIntermediateDirectories: true)
        pruneSavedTorrents(in: data)
        // 剩余空间充足时多留一些缓存，往回拖进度不用重新下载
        let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let gigabyte: UInt64 = 1024 * 1024 * 1024
        let diskCache: UInt64 = free > 12 * 1024 * 1024 * 1024 ? 2 * gigabyte : gigabyte
        return NuvioEngineConfiguration(
            dataDirectory: data,
            cacheDirectory: pieces,
            memoryCacheCapacityBytes: 64 * 1024 * 1024,
            diskCacheCapacityBytes: diskCache,
            torrentProfile: .fast,
            uploadMode: .limited(bytesPerSecond: 512 * 1024),
            // 默认 30 秒没有读取就回收数据流，暂停久一点再继续会播不了；放宽到 30 分钟
            streamInactivityTimeoutMilliseconds: 30 * 60 * 1000
        )
    }

    /// 引擎把每个种子的信息存成「哈希.resume」。只保留最近播放记录里的，删掉记录后下次启动时清理。
    private static func pruneSavedTorrents(in data: URL) {
        let keep = Set(MagnetHistoryStore.shared.items.map(\.infoHash))
        let folder = data
            .appendingPathComponent("nuvio-engine-state", isDirectory: true)
            .appendingPathComponent("resume", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasSuffix(".resume") {
            let id = String(name.dropLast(".resume".count))
            if !keep.contains(id) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }
    }
}

/// 磁力在线播放：识别链接、解析文件列表、边下边播、记住每一集看到哪里。
/// 只使用本机 BT 引擎和本机 HTTP 流，不依赖 HPlayer 服务器或 115 账号。
@MainActor
final class MagnetController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case resolving
        case ready
        case failed
    }

    /// 解析进行到哪一步
    enum ResolveStep: Int, Comparable {
        case engine
        case peers
        case metadata
        case done

        static func < (lhs: ResolveStep, rhs: ResolveStep) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Swarm: Equatable {
        var connected = 0
        var connecting = 0
        var known = 0
        var seeds = 0
        var downloadRate: UInt64 = 0
    }

    let playback = VLCPlaybackController()

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var step: ResolveStep = .engine
    @Published private(set) var link: MagnetLink?
    @Published private(set) var catalog: MagnetCatalog?
    @Published private(set) var error = ""
    @Published private(set) var elapsed = 0
    @Published private(set) var swarm = Swarm()

    @Published var playerVisible = false
    @Published private(set) var playingIndex: UInt32?
    @Published private(set) var preparing = false
    @Published private(set) var playError = ""
    @Published private(set) var fileProgress: Double = 0

    /// 115 离线中转的进度
    enum CloudState: Equatable {
        case off
        case submitting
        case downloading(Double)
        case ready
        case failed(String)
    }

    @Published private(set) var cloud: CloudState = .off
    /// 115 离线完成的结果。正在用 BT 播放时先放在这里，页面上提示可以改用 115
    @Published private(set) var cloudCatalog: MagnetCatalog?
    /// 交给 115 播放器的播放队列
    @Published var cloudQueue: PlaybackQueue?

    private let host = MagnetEngineHost.shared
    private let history = MagnetHistoryStore.shared
    private var torrentID: String?
    private var stream: NuvioStream?
    private var resolveTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var resolveStarted: Date?
    private var engineReady = false
    private var active = false
    private var lastSavedAt = Date.distantPast
    /// 最近一次看到的播放进度，播放结束时 VLC 报告的时间不一定可靠
    private var lastKnownTime: Double = 0
    private var lastKnownDuration: Double = 0
    private var cancellables = Set<AnyCancellable>()
    private var cloudClient: Direct115Client?
    private var cloudEnabled = false
    private var cloudUserID = 0
    private var cloudTask: Task<Void, Never>?

    init() {
        playback.$ended
            .removeDuplicates()
            .sink { [weak self] ended in
                guard ended else { return }
                Task { @MainActor in self?.handleEnded() }
            }
            .store(in: &cancellables)
    }

    // MARK: 页面生命周期

    /// 进入页面：占用并提前启动引擎，顺便在线更新 Tracker 列表
    func activate() {
        guard !active else { return }
        active = true
        host.acquire()
        Task { await PublicTrackers.refreshIfNeeded() }
        Task { [weak self] in
            guard let self else { return }
            if (try? await self.host.engine()) != nil {
                self.engineReady = true
                if self.phase == .resolving, self.step < .peers { self.step = .peers }
            }
        }
        startMonitor()
    }

    /// 离开页面：停止播放和数据流；种子信息留在本机，引擎稍后自动关闭
    func deactivate() {
        guard active else { return }
        active = false
        savePosition()
        resolveTask?.cancel()
        resolveTask = nil
        playTask?.cancel()
        playTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        cloudTask?.cancel()
        cloudTask = nil
        if case .submitting = cloud { cloud = .off }
        if case .downloading = cloud { cloud = .off }
        playback.stop()
        playerVisible = false
        let oldStream = stream
        stream = nil
        let host = self.host
        Task {
            if let oldStream, host.isRunning, let engine = try? await host.engine() {
                try? await engine.stopStream(oldStream.id)
            }
            host.release()
        }
    }

    // MARK: 解析

    /// 识别并解析用户输入；识别不到返回 false
    @discardableResult
    func start(_ text: String) -> Bool {
        guard let parsed = MagnetLink.parse(text) else { return false }
        open(parsed)
        return true
    }

    func open(_ newLink: MagnetLink) {
        activate()
        let sameTorrent = newLink.infoHash == link?.infoHash
        if sameTorrent && (phase == .resolving || (phase == .ready && catalog != nil)) { return }
        resolveTask?.cancel()
        closePlayer()
        if !sameTorrent || resolveStarted == nil { resolveStarted = Date() }
        link = newLink
        catalog = nil
        torrentID = nil
        error = ""
        elapsed = 0
        phase = .resolving
        step = engineReady ? .peers : .engine
        let uri = newLink.engineURI(publicTrackers: PublicTrackers.current)
        resolveTask = Task { [weak self] in
            await self?.resolve(newLink, uri: uri)
        }
        // 同一个资源的 115 离线已经在进行或已经完成时，不再重复提交
        let cloudBusyOrDone = sameTorrent && (cloudTask != nil || cloud == .ready)
        if !cloudBusyOrDone { startCloud(newLink) }
    }

    /// 解析失败后再试一次。引擎里的任务一直在找节点，重试会接着等，不会从头开始。
    func retry() {
        guard let link else { return }
        if case .failed = cloud { cloud = .off; cloudTask = nil }
        phase = .idle
        open(link)
    }

    /// 放弃当前资源，回到输入状态
    func reset() {
        resolveTask?.cancel()
        resolveTask = nil
        cloudTask?.cancel()
        cloudTask = nil
        cloud = .off
        cloudCatalog = nil
        cloudQueue = nil
        closePlayer()
        link = nil
        catalog = nil
        torrentID = nil
        error = ""
        resolveStarted = nil
        elapsed = 0
        phase = .idle
    }

    private func resolve(_ link: MagnetLink, uri: String) async {
        do {
            let engine = try await host.engine()
            engineReady = true
            guard !Task.isCancelled else { return }
            if step < .peers { step = .peers }
            let id = try await Self.withTimeout(seconds: 150, message: Self.timeoutMessage) {
                try await engine.addMagnet(uri)
            }
            guard !Task.isCancelled else { return }
            let files = try await engine.files(for: id)
            guard !Task.isCancelled else { return }
            torrentID = id
            // 115 离线已经先完成并接管了列表，BT 的结果就不用了
            guard self.catalog?.source != .cloud else { return }
            let catalog = MagnetCatalog(files: files, fallbackName: link.displayName ?? link.shortHash)
            self.catalog = catalog
            step = .done
            phase = .ready
            resolveStarted = nil
            history.recordResolved(link: link, catalog: catalog)
            // 只有一个正片时直接开始播放
            if catalog.main.count == 1 { play(catalog.main[0]) }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            self.error = Self.describe(error)
            phase = .failed
        }
    }

    // MARK: 播放

    /// 播放列表：正在放的是正片就只列正片，否则列出全部视频
    var playlist: [MagnetFile] {
        guard let catalog else { return [] }
        if let playingIndex, !catalog.main.contains(where: { $0.index == playingIndex }) { return catalog.allVideos }
        return catalog.main
    }

    var playingFile: MagnetFile? {
        guard let playingIndex else { return nil }
        return catalog?.allVideos.first { $0.index == playingIndex }
    }

    /// 上次看到的那一集
    var lastPlayed: MagnetFile? {
        guard let link, let index = history.item(for: link.infoHash)?.lastFileIndex else { return nil }
        return catalog?.allVideos.first { $0.historyIndex == index }
    }

    func savedPosition(for file: MagnetFile) -> Double? {
        guard let link, !file.isCloud else { return nil }
        return history.position(infoHash: link.infoHash, fileIndex: file.index)
    }

    func play(_ file: MagnetFile) {
        guard let link, file.isPlayable else { return }
        if let pickCode = file.pickCode {
            playCloud(file, pickCode: pickCode, link: link)
            return
        }
        guard let torrentID else { return }
        playTask?.cancel()
        savePosition()
        playError = ""
        preparing = true
        fileProgress = 0
        lastKnownTime = 0
        lastKnownDuration = 0
        playingIndex = file.index
        playerVisible = true
        history.recordPlayed(infoHash: link.infoHash, file: file)
        let resume = history.position(infoHash: link.infoHash, fileIndex: file.index)
        playTask = Task { [weak self] in
            await self?.prepare(file, torrentID: torrentID, resume: resume)
        }
    }

    func retryPlayback() {
        guard let file = playingFile else { return }
        play(file)
    }

    /// 真正播到结尾才自动下一集；中途因为网络断开而停止时不跳集
    private func handleEnded() {
        let duration = max(playback.duration, lastKnownDuration)
        let position = max(playback.currentTime, lastKnownTime)
        guard duration > 0, position >= duration * 0.9 || duration - position < 30 else { return }
        playNext()
    }

    func playNext() {
        guard let link, let current = playingIndex else { return }
        let list = playlist
        guard let position = list.firstIndex(where: { $0.index == current }), position + 1 < list.count else { return }
        history.clearPosition(infoHash: link.infoHash, fileIndex: current)
        play(list[position + 1])
    }

    /// 关闭播放器：停止当前数据流，保留文件列表，可以接着选别的集
    func closePlayer() {
        savePosition()
        playTask?.cancel()
        playTask = nil
        playerVisible = false
        preparing = false
        playError = ""
        playingIndex = nil
        playback.stop()
        if let old = stream {
            stream = nil
            let host = self.host
            Task {
                guard host.isRunning, let engine = try? await host.engine() else { return }
                try? await engine.stopStream(old.id)
            }
        }
    }

    private func prepare(_ file: MagnetFile, torrentID: String, resume: Double?) async {
        do {
            let engine = try await host.engine()
            playback.stop(detach: false)
            if let old = stream {
                stream = nil
                try? await engine.stopStream(old.id)
            }
            guard !Task.isCancelled else { return }
            let next = try await engine.prepareStream(torrentID: torrentID, fileIndex: file.index)
            guard !Task.isCancelled else {
                try? await engine.stopStream(next.id)
                return
            }
            stream = next
            try await waitForHead(of: next, engine: engine)
            guard !Task.isCancelled else { return }
            preparing = false
            // 开头已经下好，后面边播边下；节点少时缓冲会慢一些，给 VLC 足够的等待时间
            playback.open(next.url, startTime: resume, openTimeoutSeconds: 120)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            preparing = false
            playError = Self.describePlayback(error)
        }
    }

    /// 等文件开头下好再交给播放器。
    /// 先发一个范围请求让引擎优先下载开头；大种子的分块可能有好几 MB，节点慢时要多等一会儿。
    private func waitForHead(of stream: NuvioStream, engine: NuvioEngine) async throws {
        let target = min(stream.fileSize, 512 * 1024)
        guard target > 0 else { return }
        let url = stream.url
        let trigger = Task.detached {
            var request = URLRequest(url: url)
            request.setValue("bytes=0-\(target - 1)", forHTTPHeaderField: "Range")
            request.timeoutInterval = 300
            _ = try? await URLSession.shared.data(for: request)
        }
        defer { trigger.cancel() }
        let started = Date()
        while true {
            try Task.checkCancellation()
            let stats = try await engine.currentStreamStats(stream.id)
            fileProgress = stats.fileProgress
            if stats.contiguousReadyBytes >= target { return }
            if Date().timeIntervalSince(started) > 240 {
                throw APIError.server("4 分钟内没能下载到视频开头，节点可能太少或太慢。可以重试，或换一集、换一个链接。")
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    // MARK: 状态

    /// 播放器顶部显示的网络状态
    var networkStatus: String {
        var parts = ["\(swarm.connected) 个节点"]
        let rate = formatSize(Int(clamping: swarm.downloadRate))
        if !rate.isEmpty { parts.append("\(rate)/s") }
        if fileProgress >= 0.01 { parts.append("已下载 \(Int(fileProgress * 100))%") }
        return parts.joined(separator: " · ")
    }

    /// 准备播放时的提示
    var preparingText: String {
        if swarm.connected == 0 { return "正在连接节点…" }
        let rate = formatSize(Int(clamping: swarm.downloadRate))
        return rate.isEmpty
            ? "正在下载视频开头 · \(swarm.connected) 个节点"
            : "正在下载视频开头 · \(swarm.connected) 个节点 · \(rate)/s"
    }

    private func startMonitor() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func tick() async {
        if phase == .resolving, let resolveStarted {
            elapsed = Int(Date().timeIntervalSince(resolveStarted))
        }
        guard engineReady, host.isRunning, let engine = try? await host.engine() else { return }
        if let stats = try? await engine.currentStats() {
            swarm = Swarm(
                connected: Int(stats.connectedPeers),
                connecting: Int(stats.connectingPeers),
                known: Int(stats.knownPeers),
                seeds: Int(stats.connectedSeeds),
                downloadRate: stats.downloadRateBytesPerSecond
            )
            if phase == .resolving, step == .peers, stats.connectedPeers > 0 { step = .metadata }
        }
        if let stream, !preparing, let stats = try? await engine.currentStreamStats(stream.id) {
            fileProgress = stats.fileProgress
        }
        if playback.playing {
            lastKnownTime = playback.currentTime
            lastKnownDuration = playback.duration
            if Date().timeIntervalSince(lastSavedAt) >= 5 { savePosition() }
        }
    }

    private func savePosition() {
        guard let link, let index = playingIndex, playback.duration > 0, playback.currentTime > 0 else { return }
        lastSavedAt = Date()
        history.savePosition(
            infoHash: link.infoHash,
            fileIndex: index,
            seconds: playback.currentTime,
            duration: playback.duration
        )
    }

    // MARK: 115 离线中转

    /// 手机直连登录了 115 且开关打开时，解析的同时把磁力交给 115 离线下载
    func configureCloud(client: Direct115Client?, enabled: Bool) {
        if client?.cookie != cloudClient?.cookie { cloudUserID = 0 }
        cloudClient = client
        let nowEnabled = enabled && client != nil
        let wasEnabled = cloudEnabled
        cloudEnabled = nowEnabled
        if !nowEnabled {
            cloudTask?.cancel()
            cloudTask = nil
            if cloud != .ready { cloud = .off }
        } else if !wasEnabled, let link, phase == .resolving || phase == .failed {
            startCloud(link)
        }
    }

    /// 改用 115 离线的结果播放
    func useCloudCatalog() {
        guard let result = cloudCatalog, let link else { return }
        if playerVisible { closePlayer() }
        resolveTask?.cancel()
        resolveTask = nil
        catalog = result
        phase = .ready
        step = .done
        error = ""
        resolveStarted = nil
        history.recordResolved(link: link, catalog: result)
        if result.main.count == 1 { play(result.main[0]) }
    }

    /// 页面上显示的 115 离线状态
    var cloudStatusText: String {
        switch cloud {
        case .off:
            return ""
        case .submitting:
            return "正在提交到 115…"
        case .downloading(let percent):
            if percent >= 100 { return "115 已下载完成，正在找视频…" }
            return percent > 0 ? "115 正在离线下载 \(Int(percent))%" : "115 已接收，等待开始下载"
        case .ready:
            return "115 离线完成，可以直接播放"
        case .failed(let message):
            return message
        }
    }

    private func startCloud(_ link: MagnetLink) {
        cloudTask?.cancel()
        cloudTask = nil
        cloudCatalog = nil
        guard cloudEnabled, let client = cloudClient else {
            cloud = .off
            return
        }
        cloud = .submitting
        cloudTask = Task { [weak self] in
            await self?.runCloud(link, client: client)
        }
    }

    private func runCloud(_ link: MagnetLink, client: Direct115Client) async {
        do {
            if cloudUserID == 0 { cloudUserID = try await client.user().userId ?? 0 }
            guard !Task.isCancelled else { return }
            try await client.addOfflineTask(link.uri, userID: cloudUserID)
            guard !Task.isCancelled else { return }
            cloud = .downloading(0)
            let started = Date()
            var interval: UInt64 = 1_000_000_000
            var failures = 0
            while !Task.isCancelled {
                var found: Direct115OfflineTask?
                do {
                    found = try await client.offlineTask(infoHash: link.infoHash)
                    failures = 0
                } catch {
                    failures += 1
                    if failures >= 4 { throw error }
                }
                guard !Task.isCancelled else { return }
                if let task = found {
                    switch task.status {
                    case .done:
                        cloud = .downloading(100)
                        let videos = try await client.offlineVideos(for: task)
                        guard !Task.isCancelled else { return }
                        cloudFinished(videos, task: task, link: link)
                        return
                    case .failed:
                        cloud = .failed("115 也没能下载这个资源，可能已经没有来源了。")
                        return
                    case .waiting, .downloading:
                        cloud = .downloading(task.percent)
                    }
                }
                if Date().timeIntervalSince(started) > 30 * 60 {
                    cloud = .failed("115 离线超过 30 分钟还没完成，可以稍后到 115 的云下载里查看。")
                    return
                }
                try await Task.sleep(nanoseconds: interval)
                interval = min(interval + 1_000_000_000, 6_000_000_000)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            cloud = .failed(Self.describeCloud(error))
        }
    }

    private func cloudFinished(_ videos: [Direct115CloudVideo], task: Direct115OfflineTask, link: MagnetLink) {
        guard self.link?.infoHash == link.infoHash else { return }
        guard !videos.isEmpty else {
            cloud = .failed("115 离线完成了，但里面没有找到能播放的视频。")
            return
        }
        let name = task.name.isEmpty ? (catalog?.name ?? link.displayName ?? link.shortHash) : task.name
        cloudCatalog = MagnetCatalog(cloudVideos: videos, name: name, totalSize: UInt64(max(task.size, 0)))
        cloud = .ready
        // 正在用 BT 看的时候不打断，页面上会提示可以改用 115
        if playerVisible { return }
        useCloudCatalog()
    }

    private func playCloud(_ file: MagnetFile, pickCode: String, link: MagnetLink) {
        if playerVisible { closePlayer() }
        history.recordPlayed(infoHash: link.infoHash, file: file)
        let list = (catalog?.main.contains(file) ?? false) ? (catalog?.main ?? []) : (catalog?.allVideos ?? [])
        let items = list.compactMap { item in item.pickCode.map { PlaybackSource.p115(title: item.title, pickCode: $0) } }
        let source = PlaybackSource.p115(title: file.title, pickCode: pickCode)
        cloudQueue = PlaybackQueue(source: source, items: items.isEmpty ? [source] : items)
    }

    private static func describeCloud(_ error: Error) -> String {
        if let offline = error as? Direct115OfflineError {
            switch offline {
            case .quotaExhausted: return "115 离线额度用完了，这次只能用 BT。"
            case .invalidLink: return "115 认为这个链接无效。"
            case .server(let message): return "115 离线：\(message)"
            }
        }
        if let value = error as? APIError { return "115 离线：\(value.localizedDescription)" }
        return "115 离线没有成功：\(error.localizedDescription)"
    }

    // MARK: 工具

    private static let timeoutMessage = "等了两分半还没拿到文件列表。这个资源可能暂时没人做种；可以点「重试」接着等，引擎会继续找节点，不用从头开始。"

    private static func withTimeout<T: Sendable>(
        seconds: UInt64,
        message: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw APIError.server(message)
            }
            guard let first = try await group.next() else { throw APIError.server("磁力解析失败") }
            group.cancelAll()
            return first
        }
    }

    private static func describe(_ error: Error) -> String {
        if let value = error as? APIError { return value.localizedDescription }
        let message = (error as? NuvioEngineError)?.message ?? error.localizedDescription
        let lower = message.lowercased()
        if lower.contains("info hash") || lower.contains("info_hash") {
            return "链接里的信息哈希无效，请确认复制完整。"
        }
        if lower.contains("closed") {
            return "BT 引擎已经关闭，请重试。"
        }
        return "解析失败：\(message)"
    }

    private static func describePlayback(_ error: Error) -> String {
        if let value = error as? APIError { return value.localizedDescription }
        let message = (error as? NuvioEngineError)?.message ?? error.localizedDescription
        return "视频准备失败：\(message)"
    }
}
