import Combine
import Foundation
import Network
import UIKit

/// 所有磁力页面共用一个 BT 引擎。
///
/// 进入磁力页面时就启动引擎，DHT 在用户粘贴链接的这段时间里先热起来；
/// 前台切换页面期间保持 3 分钟温热，退入后台或长时间空闲后再关闭引擎，
/// 关闭时引擎会把 DHT 节点表和已解析的种子信息存到本机，下次打开同一个链接可以直接读到文件列表。
@MainActor
final class MagnetEngineHost {
    static let shared = MagnetEngineHost()

    private var runningEngine: NuvioEngine?
    private var creating: Task<NuvioEngine, Error>?
    private var shuttingDown: Task<Void, Never>?
    private var idleShutdown: Task<Void, Never>?
    private var users = 0
    /// 每个资源（信息哈希，小写）拿种子信息的任务：预取和真正播放共用同一个，不重复向引擎添加
    private var metadataTasks: [String: Task<String, Error>] = [:]
    private let networkMonitor = NWPathMonitor()
    private var expensiveNetwork = false
    private var inBackground = false

    private init() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive
            Task { @MainActor [weak self] in self?.expensiveNetwork = expensive }
        }
        networkMonitor.start(queue: DispatchQueue(label: "app.hplayer.magnet.network"))
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleBackgroundChange(true) }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleBackgroundChange(false) }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.users == 0 else { return }
                await self.shutdownIfIdle()
            }
        }
    }

    var isRunning: Bool { runningEngine != nil }

    /// 拿到这个磁力的种子 ID（种子信息已就绪，可以列文件）。
    /// 同一个资源只解析一次：详情页的预取、卡片上的「磁力播放」、播放窗口都等同一个任务。
    func metadataTask(link: MagnetLink) -> Task<String, Error> {
        let key = link.infoHash.lowercased()
        if let existing = metadataTasks[key] { return existing }
        let task = Task<String, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            async let engineTask = self.engine()
            async let trackersTask = PublicTrackers.ensureFresh(timeoutSeconds: 1.2)
            let (engine, trackers) = try await (engineTask, trackersTask)
            let uri = link.engineURI(publicTrackers: trackers)
            return try await engine.addMagnet(uri)
        }
        metadataTasks[key] = task
        // 失败了就忘掉，下次重新解析
        Task { [weak self] in
            if case .failure = await task.result, self?.metadataTasks[key] == task {
                self?.metadataTasks[key] = nil
            }
        }
        return task
    }

    /// 详情页打开时先在后台解析排在最前面的几个资源的种子信息，点「磁力播放」时文件列表往往已经到了。
    /// 引擎在此阶段只拉取几百 KB 元数据，不下载视频内容。
    func prefetch(_ magnets: [String], limit: Int = 3) {
        var seen = Set<String>()
        var count = 0
        for magnet in magnets {
            guard let link = MagnetLink.parse(magnet), seen.insert(link.infoHash.lowercased()).inserted else { continue }
            _ = metadataTask(link: link)
            count += 1
            if count >= limit { break }
        }
    }

    func prefetch(_ magnet: String) {
        prefetch([magnet], limit: 1)
    }

    func acquire() {
        users += 1
        idleShutdown?.cancel()
        idleShutdown = nil
    }

    func release() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        scheduleIdleShutdown(seconds: inBackground ? 15 : 180)
    }

    private func handleBackgroundChange(_ background: Bool) {
        inBackground = background
        guard users == 0 else { return }
        if background {
            scheduleIdleShutdown(seconds: 15)
        } else {
            idleShutdown?.cancel()
            idleShutdown = nil
        }
    }

    private func scheduleIdleShutdown(seconds: UInt64) {
        idleShutdown?.cancel()
        idleShutdown = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.shutdownIfIdle()
        }
    }

    func engine() async throws -> NuvioEngine {
        if let runningEngine { return runningEngine }
        if let creating { return try await creating.value }
        let previousShutdown = shuttingDown
        let expensive = expensiveNetwork
        let task = Task<NuvioEngine, Error> {
            await previousShutdown?.value
            return try await NuvioEngine.create(configuration: try Self.configuration(expensiveNetwork: expensive))
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
        // 引擎关了，里面的种子 ID 都不能再用
        metadataTasks.removeAll()
        let task = Task { await current.shutdown() }
        shuttingDown = task
        await task.value
    }

    private static func configuration(expensiveNetwork: Bool) throws -> NuvioEngineConfiguration {
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
        // Wi-Fi 下适度放宽上传以提升 BitTorrent 节点互换与 unchoke 速率，蜂窝网络下保持克制
        let uploadLimit: UInt64 = expensiveNetwork ? 256 * 1024 : 2 * 1024 * 1024
        return NuvioEngineConfiguration(
            dataDirectory: data,
            cacheDirectory: pieces,
            memoryCacheCapacityBytes: 64 * 1024 * 1024,
            diskCacheCapacityBytes: diskCache,
            torrentProfile: .fast,
            uploadMode: .limited(bytesPerSecond: uploadLimit),
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
/// 只使用本机 BT 引擎和本机 HTTP 流，不依赖 115 账号。
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
        var trackerReplies = 0
        var dhtReplies = 0
        var trackerPeers = 0
        var dhtPeers = 0
    }

    let playback = PlaybackController()

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var step: ResolveStep = .engine
    @Published private(set) var link: MagnetLink?
    @Published private(set) var catalog: MagnetCatalog?
    @Published private(set) var error = ""
    @Published private(set) var elapsed = 0
    @Published private(set) var resolveHint = ""
    @Published private(set) var swarm = Swarm()
    /// 只有一个正片时是否自动进入播放状态（卡片后台预解析设为 false，改在后台静默预热流）
    var autoPlaysSingleMain = true

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
    private var prewarmTask: Task<NuvioStream?, Never>?
    private var prewarmTargetIndex: UInt32?
    private var prewarmedStream: NuvioStream?
    private var resolveTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var resolveStarted: Date?
    private var engineReady = false
    private var active = false
    private var lastSavedAt = Date.distantPast
    /// 最近一次看到的播放进度，播放结束时内核报告的时间不一定可靠
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

    #if DEBUG
    /// Exercises the real resolving/catalog views without starting a network swarm.
    static func interfaceFixture(catalog: MagnetCatalog? = nil, cloudClient: Direct115Client? = nil) -> MagnetController {
        let value = MagnetController()
        value.link = MagnetLink.parse("magnet:?xt=urn:btih:0123456789012345678901234567890123456789&dn=Severance.S01")
        value.phase = catalog == nil ? .resolving : .ready
        value.step = .metadata
        value.elapsed = 8
        value.swarm = Swarm(connected: 18, connecting: 3, known: 42, seeds: 8, downloadRate: 25_190)
        value.catalog = catalog
        value.cloudClient = cloudClient
        value.cloudEnabled = cloudClient != nil
        if cloudClient != nil, catalog?.source == .cloud {
            value.cloudCatalog = catalog
            value.cloud = .ready
        }
        return value
    }
    #endif

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
        let oldPrewarm = consumePrewarmForStop(excludingID: oldStream?.id)
        let host = self.host
        Task {
            if let oldStream, host.isRunning, let engine = try? await host.engine() {
                try? await engine.stopStream(oldStream.id)
            }
            if let oldPrewarm, host.isRunning, let engine = try? await host.engine() {
                try? await engine.stopStream(oldPrewarm.id)
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
        resolveHint = ""
        phase = .resolving
        step = engineReady ? .peers : .engine
        if cloudEnabled {
            // 选了「使用 115 解析」：只交给 115 离线，软件自带的 BT 解析不参与
            resolveTask = nil
            if sameTorrent, cloud == .ready, cloudCatalog != nil {
                useCloudCatalog()
            } else if !(sameTorrent && cloudTask != nil) {
                startCloud(newLink)
            }
        } else {
            // 没选 115：只用软件自带的磁力解析
            cloudTask?.cancel()
            cloudTask = nil
            cloud = .off
            resolveTask = Task { [weak self] in
                await self?.resolve(newLink)
            }
        }
    }

    /// 当前用 115 离线解析（否则用软件自带的 BT 解析）
    var usesCloud: Bool { cloudEnabled }

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
        resolveHint = ""
        resolveStarted = nil
        elapsed = 0
        phase = .idle
    }

    private func resolve(_ link: MagnetLink) async {
        do {
            let engine = try await host.engine()
            engineReady = true
            guard !Task.isCancelled else { return }
            if step < .peers { step = .peers }
            // 详情页可能已经在预取这个资源：直接等那份结果，不重复添加
            let pending = host.metadataTask(link: link)
            let id = try await Self.withTimeout(seconds: 150, message: Self.timeoutMessage) {
                try await awaitCancellable(pending)
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
            resolveHint = ""
            history.recordResolved(link: link, catalog: catalog)
            if autoPlaysSingleMain {
                // 只有一个正片时直接开始播放
                if catalog.main.count == 1 { play(catalog.main[0]) }
            } else if let prewarmPick = preferredBTFile(in: catalog, infoHash: link.infoHash) {
                // 卡片接力等待打开窗口期间，提前调用 prepareStream 让底层开始调度片头与片尾关键块
                startPrewarm(torrentID: id, fileIndex: prewarmPick.index)
            }
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
        playback.prepareForPresentation()
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
        let oldStream = stream
        stream = nil
        let oldPrewarm = consumePrewarmForStop(excludingID: oldStream?.id)
        let host = self.host
        Task {
            if let oldStream, host.isRunning, let engine = try? await host.engine() {
                try? await engine.stopStream(oldStream.id)
            }
            if let oldPrewarm, host.isRunning, let engine = try? await host.engine() {
                try? await engine.stopStream(oldPrewarm.id)
            }
        }
    }

    private func preferredBTFile(in catalog: MagnetCatalog, infoHash: String) -> MagnetFile? {
        if let index = history.item(for: infoHash)?.lastFileIndex,
           let last = catalog.allVideos.first(where: { $0.historyIndex == index }),
           last.isPlayable {
            return last
        }
        return catalog.main.count == 1 ? catalog.main[0] : nil
    }

    private func startPrewarm(torrentID: String, fileIndex: UInt32) {
        if prewarmTargetIndex == fileIndex, prewarmedStream != nil || prewarmTask != nil { return }
        if let old = consumePrewarmForStop(excludingID: stream?.id) {
            let host = self.host
            Task {
                guard host.isRunning, let engine = try? await host.engine() else { return }
                try? await engine.stopStream(old.id)
            }
        }
        prewarmTargetIndex = fileIndex
        let host = self.host
        prewarmTask = Task { [weak self] in
            guard let engine = try? await host.engine(), !Task.isCancelled else { return nil }
            guard let prepared = try? await engine.prepareStream(torrentID: torrentID, fileIndex: fileIndex) else { return nil }
            if Task.isCancelled {
                try? await engine.stopStream(prepared.id)
                return nil
            }
            self?.finishPrewarm(prepared, torrentID: torrentID, fileIndex: fileIndex)
            return prepared
        }
    }

    private func finishPrewarm(_ prepared: NuvioStream, torrentID: String, fileIndex: UInt32) {
        guard self.torrentID == torrentID, prewarmTargetIndex == fileIndex, !Task.isCancelled else {
            let host = self.host
            Task {
                guard host.isRunning, let engine = try? await host.engine() else { return }
                try? await engine.stopStream(prepared.id)
            }
            return
        }
        prewarmedStream = prepared
    }

    private func consumePrewarmForStop(excludingID: String?) -> NuvioStream? {
        prewarmTask?.cancel()
        prewarmTask = nil
        prewarmTargetIndex = nil
        let existing = prewarmedStream
        prewarmedStream = nil
        guard let existing, existing.id != excludingID else { return nil }
        return existing
    }

    private func takePrewarmedStream(for fileIndex: UInt32, engine: NuvioEngine) async -> NuvioStream? {
        if prewarmTargetIndex == fileIndex {
            if let ready = prewarmedStream, ready.fileIndex == fileIndex {
                prewarmedStream = nil
                prewarmTask = nil
                prewarmTargetIndex = nil
                return ready
            }
            if let running = prewarmTask {
                let resolved = await running.value
                prewarmTask = nil
                prewarmTargetIndex = nil
                prewarmedStream = nil
                if let resolved, resolved.fileIndex == fileIndex {
                    if Task.isCancelled {
                        try? await engine.stopStream(resolved.id)
                        return nil
                    }
                    return resolved
                }
            }
        }
        if let unused = consumePrewarmForStop(excludingID: stream?.id) {
            try? await engine.stopStream(unused.id)
        }
        return nil
    }

    private func prepare(_ file: MagnetFile, torrentID: String, resume: Double?) async {
        do {
            let engine = try await host.engine()
            playback.stop(detach: false)
            // 这部资源在「继续观看」里的封面：暂停、换集、退出时截下的画面
            if let link { playback.resumeFrameKey = PlaybackFrameStore.key(forMagnet: link.infoHash) }
            let reusable = await takePrewarmedStream(for: file.index, engine: engine)
            if let old = stream, old.id != reusable?.id {
                stream = nil
                try? await engine.stopStream(old.id)
            }
            guard !Task.isCancelled else {
                if let reusable { try? await engine.stopStream(reusable.id) }
                return
            }
            let next: NuvioStream
            if let reusable {
                next = reusable
            } else {
                next = try await engine.prepareStream(torrentID: torrentID, fileIndex: file.index)
            }
            guard !Task.isCancelled else {
                try? await engine.stopStream(next.id)
                return
            }
            stream = next
            preparing = false
            // 直接把本机回环流交给 mpv 探测与播放：NuvioEngine 底层按 16KB 块流式吐出，
            // 并由 mpv 直接发起头/尾索引及续播点 Range 请求，避免按整片 SHA1 校验块干等两段阻塞。
            let videoTitle = file.title.isEmpty ? (catalog?.name ?? "") : file.title
            let catalogHint = catalog?.name
            let adultHint = SubtitleQueryBuilder.extractAVCode(from: videoTitle) != nil
                || SubtitleQueryBuilder.extractAVCode(from: catalogHint ?? "") != nil
            playback.open(next.url, startTime: resume, autoRecover: false, openTimeoutSeconds: 180,
                          title: videoTitle, subtitleIdentifier: catalogHint, isAdultVideo: adultHint,
                          skipRemoteHash: true, isTorrentStream: true)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            preparing = false
            playError = Self.describePlayback(error)
        }
    }

    // MARK: 状态

    /// 播放器顶部显示的网络状态
    var networkStatus: String {
        if !playback.hasLoaded, swarm.connected == 0 {
            if swarm.connecting > 0 {
                return "正在连接节点（\(swarm.connecting) 个尝试中）…"
            }
            if swarm.known > 0 {
                return "已发现 \(swarm.known) 个节点，正在连接…"
            }
            return "正在连接节点…"
        }
        var parts = ["\(swarm.connected) 个节点"]
        let rate = formatSize(Int(clamping: swarm.downloadRate))
        if !rate.isEmpty {
            parts.append("\(rate)/s")
        } else if !playback.hasLoaded {
            parts.append("正在缓冲开头")
        }
        if fileProgress >= 0.01 { parts.append("已下载 \(Int(fileProgress * 100))%") }
        return parts.joined(separator: " · ")
    }

    /// 准备播放时的提示
    var preparingText: String {
        if swarm.connected == 0 {
            return swarm.connecting > 0 ? "正在连接节点（\(swarm.connecting) 个尝试中）…" : "正在连接节点…"
        }
        let rate = formatSize(Int(clamping: swarm.downloadRate))
        return rate.isEmpty
            ? "正在准备视频流 · \(swarm.connected) 个节点"
            : "正在准备视频流 · \(swarm.connected) 个节点 · \(rate)/s"
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
                downloadRate: stats.downloadRateBytesPerSecond,
                trackerReplies: Int(stats.trackerReplyEvents),
                dhtReplies: Int(stats.dhtReplyEvents),
                trackerPeers: Int(stats.trackerPeersReturned),
                dhtPeers: Int(stats.dhtPeersReturned)
            )
            if phase == .resolving, step == .peers, stats.connectedPeers > 0 { step = .metadata }
        }
        if phase == .resolving && !usesCloud {
            if elapsed >= 25 && swarm.connected == 0 && swarm.known == 0 && (swarm.trackerReplies + swarm.dhtReplies) >= 4 {
                resolveHint = "Tracker 与 DHT 暂未返回做种节点，冷门或无源资源较难解析；可以换一条磁力或改用「115 播放」。"
            } else if elapsed >= 20 && swarm.connected == 0 && swarm.known > 0 {
                resolveHint = "已找到 \(swarm.known) 个候选节点但尚未连上，节点可能已离线或网络受限，仍在尝试…"
            } else if elapsed >= 25 {
                resolveHint = "冷门资源找节点会久一些，可以继续等待；超过两分半会提示你。"
            } else {
                resolveHint = ""
            }
        }
        if let stream, !preparing, let stats = try? await engine.currentStreamStats(stream.id) {
            fileProgress = stats.fileProgress
        }
        if playback.playing, let confirmedTime = playback.confirmedTime {
            lastKnownTime = confirmedTime
            lastKnownDuration = playback.duration
            if Date().timeIntervalSince(lastSavedAt) >= 5 { savePosition() }
        }
    }

    private func savePosition() {
        guard let link, let index = playingIndex, playback.duration > 0, let position = playback.confirmedTime else { return }
        lastSavedAt = Date()
        history.savePosition(
            infoHash: link.infoHash,
            fileIndex: index,
            seconds: position,
            duration: playback.duration
        )
    }

    // MARK: 115 离线中转

    /// 手机直连登录了 115 且开关打开时，解析的同时把磁力交给 115 离线下载
    func configureCloud(client: Direct115Client?, enabled: Bool) {
        let clientChanged = client?.cookie != cloudClient?.cookie
        if clientChanged {
            cloudUserID = 0
            cloudTask?.cancel()
            cloudTask = nil
            cloudCatalog = nil
            cloudQueue = nil
            cloud = .off
            // 已完成的网盘文件也属于旧会话；不能用新账号继续播放或复用这些 pickCode。
            if catalog?.source == .cloud {
                closePlayer()
                catalog = nil
                phase = .idle
                error = ""
                resolveStarted = nil
                elapsed = 0
            }
        }
        cloudClient = client
        let nowEnabled = enabled && client != nil
        let wasEnabled = cloudEnabled
        cloudEnabled = nowEnabled
        if !nowEnabled {
            cloudTask?.cancel()
            cloudTask = nil
            if cloud != .ready { cloud = .off }
        }
        // 解析中途切换了方式：按新的方式重新解析这个链接
        if (nowEnabled != wasEnabled || (clientChanged && nowEnabled)),
           let link, phase == .resolving || phase == .failed {
            resolveTask?.cancel()
            resolveTask = nil
            if case .failed = cloud { cloud = .off }
            phase = .idle
            open(link)
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
            // 1. 优先命中本机按账号隔离的已离线视频缓存：1 次原画直链请求即可验证并预热直链，秒开播放
            if let cached = MagnetCloudVideoCache.shared.get(infoHash: link.infoHash, cookie: client.cookie),
               let primary = preferredCloudVideo(from: cached.videos, infoHash: link.infoHash, name: cached.name, totalSize: cached.totalSize) {
                cloud = .downloading(100)
                do {
                    _ = try await client.originalURL(pickCode: primary.file.pickCode, useCache: false)
                    guard !Task.isCancelled, cloudClient?.cookie == client.cookie else { return }
                    let task = Direct115OfflineTask(
                        infoHash: link.infoHash,
                        name: cached.name,
                        size: cached.totalSize,
                        status: .done,
                        percent: 100,
                        fileID: "",
                        folderID: ""
                    )
                    cloudFinished(cached.videos, task: task, link: link, client: client)
                    return
                } catch Direct115FileError.notLoggedIn {
                    throw Direct115FileError.notLoggedIn
                } catch let urlError as URLError where urlError.code == .notConnectedToInternet || urlError.code == .timedOut || urlError.code == .networkConnectionLost {
                    throw urlError
                } catch {
                    // 文件可能已被从 115 网盘删除：清理缓存，无缝回退重提离线
                    MagnetCloudVideoCache.shared.remove(infoHash: link.infoHash, cookie: client.cookie)
                }
            }

            if cloudUserID == 0 {
                let userID = try await client.cachedUserID()
                guard !Task.isCancelled, cloudClient?.cookie == client.cookie else { return }
                cloudUserID = userID
            }
            guard !Task.isCancelled else { return }
            try await client.addOfflineTask(link.uri, userID: cloudUserID)
            guard !Task.isCancelled else { return }
            cloud = .downloading(0)
            let started = Date()
            // 热门秒离线通常 0.2~0.5 秒就绪：前几轮缩短等待，之后逐级退避至 6 秒
            let intervals: [UInt64] = [350_000_000, 600_000_000, 1_000_000_000, 1_800_000_000, 3_000_000_000, 4_500_000_000, 6_000_000_000]
            var pollIndex = 0
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
                        guard !Task.isCancelled, cloudClient?.cookie == client.cookie else { return }
                        cloudFinished(videos, task: task, link: link, client: client)
                        return
                    case .failed:
                        MagnetCloudVideoCache.shared.remove(infoHash: link.infoHash, cookie: client.cookie)
                        cloudFailed("115 也没能下载这个资源，可能已经没有来源了。")
                        return
                    case .waiting, .downloading:
                        cloud = .downloading(task.percent)
                    }
                }
                if Date().timeIntervalSince(started) > 30 * 60 {
                    cloudFailed("115 离线超过 30 分钟还没完成，可以稍后到 115 的云下载里查看。")
                    return
                }
                let sleepNs = intervals[min(pollIndex, intervals.count - 1)]
                pollIndex += 1
                try await Task.sleep(nanoseconds: sleepNs)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            cloudFailed(Self.describeCloud(error))
        }
    }

    private func preferredCloudVideo(
        from videos: [Direct115CloudVideo],
        infoHash: String,
        name: String,
        totalSize: Int
    ) -> Direct115CloudVideo? {
        guard !videos.isEmpty else { return nil }
        let probeCatalog = MagnetCatalog(cloudVideos: videos, name: name, totalSize: UInt64(max(totalSize, 0)))
        if let index = history.item(for: infoHash)?.lastFileIndex,
           let last = probeCatalog.allVideos.first(where: { $0.historyIndex == index }),
           last.isPlayable,
           let matched = videos.first(where: { $0.file.pickCode == last.pickCode }) {
            return matched
        }
        let candidates = (probeCatalog.main.isEmpty ? probeCatalog.allVideos : probeCatalog.main).filter(\.isPlayable)
        if let best = candidates.max(by: { $0.size < $1.size }),
           let matched = videos.first(where: { $0.file.pickCode == best.pickCode }) {
            return matched
        }
        return videos.first
    }

    /// 115 离线没成功。只用 115 解析时，整个解析就算失败，页面显示原因和重试
    private func cloudFailed(_ message: String) {
        if let link, let cookie = cloudClient?.cookie {
            MagnetCloudVideoCache.shared.remove(infoHash: link.infoHash, cookie: cookie)
        }
        cloud = .failed(message)
        guard cloudEnabled, catalog == nil, resolveTask == nil else { return }
        error = message
        phase = .failed
        resolveStarted = nil
    }

    private func cloudFinished(_ videos: [Direct115CloudVideo], task: Direct115OfflineTask, link: MagnetLink, client: Direct115Client) {
        guard self.link?.infoHash == link.infoHash else { return }
        guard !videos.isEmpty else {
            cloudFailed("115 离线完成了，但里面没有找到能播放的视频。")
            return
        }
        let name = task.name.isEmpty ? (catalog?.name ?? link.displayName ?? link.shortHash) : task.name
        MagnetCloudVideoCache.shared.save(
            infoHash: link.infoHash,
            cookie: client.cookie,
            name: name,
            totalSize: task.size,
            videos: videos
        )
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
            case .quotaExhausted: return "115 离线额度用完了。可以关掉「使用 115 解析」，改用软件自带的解析。"
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


// MARK: - 可以取消的等待

/// 等一个共享的任务，但自己被取消（比如超时、关掉页面）时立刻返回，不等那个任务结束。
/// 共享的任务继续在后台跑，下次再来等的人还能用上它的结果。
func awaitCancellable<T: Sendable>(_ task: Task<T, Error>) async throws -> T {
    let waiter = SharedWaiter<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            guard waiter.install(continuation) else {
                continuation.resume(throwing: CancellationError())
                return
            }
            Task {
                do { waiter.finish(.success(try await task.value)) } catch { waiter.finish(.failure(error)) }
            }
        }
    } onCancel: {
        waiter.cancel()
    }
}

private final class SharedWaiter<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var cancelled = false

    /// 已经被取消时返回 false
    func install(_ continuation: CheckedContinuation<T, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return false }
        self.continuation = continuation
        return true
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: CancellationError())
    }
}
