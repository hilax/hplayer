import Foundation

/// 磁力卡片上的女优名。
///
/// JavBus 的列表页（最新、片商、搜索）和 Sukebei RSS 都不带演员，只有影片详情页里有。
/// 卡片一出现就按番号取一次详情页（只取页面，不取磁力）解析出参演女优，并顺手预取后面几张；
/// JavBus 还没收录（404，刚出种的新片常见）时再问 r18.dev。
///
/// - 结果按番号缓存在内存和磁盘：查到的长期保存（演员不会变）；确认没有演员的（素人、合集、刚登记还没补）
///   记一天；网络出错只记两分钟。
/// - 同时最多三个请求，两次开始之间隔一小段。屏幕上正在等的卡片先查（按出现顺序，从上往下），
///   再查预取的；卡片滑走后它的等待撤掉，预取只留最近的一批，滑过去的旧预取没轮到就丢掉。
/// - JavBus 回 Cloudflare 拦截时整体停几分钟，不连累页面本身的浏览。
actor MagnetStarNames {
    static let shared = MagnetStarNames(cacheFile: defaultCacheFile)

    enum Outcome: Equatable, Sendable {
        /// 查到了演员名
        case found([String])
        /// 来源里有这部片，但没有演员（或者来源里没有这个番号）
        case none
        /// 网络出错、限流：稍后再试
        case unavailable
        /// 被 Cloudflare 拦了：暂停一段时间
        case blocked
    }

    typealias Lookup = @Sendable (MagnetSearchItem) async -> Outcome

    static let maxConcurrent = 3
    static let defaultStartInterval: TimeInterval = 0.25
    /// 没有卡片在等的预取最多排这么多个，多了先丢最早排进来的（多半已经滑过去了）
    static let maxIdlePrefetch = 12
    static let noneLifetime: TimeInterval = 24 * 60 * 60
    static let failureLifetime: TimeInterval = 2 * 60
    static let blockedPause: TimeInterval = 3 * 60
    static let maxEntries = 2000

    static var defaultCacheFile: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("HPlayerMagnetStarNames.json")
    }

    /// 默认查法：JavBus 详情页 → 没收录时 r18.dev。
    static let defaultLookup: Lookup = { item in
        if !item.detailPath.isEmpty {
            do {
                let names = try await JavBusSource.shared.fetchStars(detailPath: item.detailPath).map(\.name)
                return names.isEmpty ? .none : .found(names)
            } catch JavBusError.notFound {
                // JavBus 还没收录：往下问 r18.dev
            } catch JavBusError.cloudflareBlocked {
                return .blocked
            } catch {
                return .unavailable
            }
        }
        guard let code = AVCatalogCode.extract(item.code), code == item.code.uppercased() else { return .none }
        switch await R18DevClient.shared.performers(for: code) {
        case .found(let names):
            return .found(names)
        case .none:
            return .none
        case .unavailable:
            return .unavailable
        }
    }

    private struct DiskPayload: Codable {
        var order: [String]
        var names: [String: [String]]
        var empty: [String: Date]
    }

    /// 同步可读的一份：卡片首帧就能显示已知的名字，不先空一下再跳出来。
    private final class SyncStore: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: [String]] = [:]

        func names(for key: String) -> [String]? {
            lock.lock()
            defer { lock.unlock() }
            return entries[key]
        }

        func set(_ names: [String]?, for key: String) {
            lock.lock()
            entries[key] = names
            lock.unlock()
        }

        func replaceAll(_ map: [String: [String]]) {
            lock.lock()
            entries = map
            lock.unlock()
        }
    }

    private let lookup: Lookup
    private let now: @Sendable () -> Date
    private let cacheFile: URL?
    private let startInterval: TimeInterval
    private let syncStore = SyncStore()

    private var found: [String: [String]] = [:]
    private var foundOrder: [String] = []
    private var empty: [String: Date] = [:]
    private var failed: [String: Date] = [:]
    private var pausedUntil = Date.distantPast

    /// 等着查的番号，按排进来的先后；有卡片在等的优先
    private var pending: [String] = []
    private var running: Set<String> = []
    /// 预取排进来的：没有卡片在等也照查
    private var prefetchKeys: Set<String> = []
    private var queuedItems: [String: MagnetSearchItem] = [:]
    private var waiters: [String: [UUID: CheckedContinuation<[String]?, Never>]] = [:]
    private var workers = 0
    private var nextStartAt = Date.distantPast
    private var persistTask: Task<Void, Never>?

    init(
        now: @escaping @Sendable () -> Date = { Date() },
        cacheFile: URL? = nil,
        startInterval: TimeInterval = MagnetStarNames.defaultStartInterval,
        lookup: @escaping Lookup = MagnetStarNames.defaultLookup
    ) {
        self.now = now
        self.cacheFile = cacheFile
        self.startInterval = startInterval
        self.lookup = lookup

        if let cacheFile,
           let data = try? Data(contentsOf: cacheFile),
           let payload = try? JSONDecoder().decode(DiskPayload.self, from: data) {
            let current = now()
            var restored: [String: [String]] = [:]
            var restoredOrder: [String] = []
            for key in payload.order {
                if let names = payload.names[key], !names.isEmpty, restored[key] == nil {
                    restored[key] = names
                    restoredOrder.append(key)
                }
            }
            let stillEmpty = payload.empty.filter { current.timeIntervalSince($0.value) < MagnetStarNames.noneLifetime }
            var snapshot = restored
            for key in stillEmpty.keys where snapshot[key] == nil {
                snapshot[key] = []
            }
            self.found = restored
            self.foundOrder = restoredOrder
            self.empty = stillEmpty
            self.syncStore.replaceAll(snapshot)
        }
    }

    // MARK: - 对外

    nonisolated static func key(for item: MagnetSearchItem) -> String {
        MagnetAggregator.normalizedCodeKey(for: item)
    }

    /// 卡片上显示的写法：「A、B 等」。最多列 limit 位，去掉括号里的别名（「森沢かな（飯岡かなこ）」→「森沢かな」）。
    nonisolated static func display(_ names: [String], limit: Int = 2) -> String? {
        let list = PerformerName.unique(names.map { JavBusSource.searchName(for: $0) })
        guard !list.isEmpty else { return nil }
        let count = max(limit, 1)
        let shown = list.prefix(count).joined(separator: "、")
        return list.count > count ? shown + " 等" : shown
    }

    /// 同步读缓存：查到的名字；确认没有演员时是空数组；还不知道是 nil。
    nonisolated func cachedNames(for item: MagnetSearchItem) -> [String]? {
        let key = Self.key(for: item)
        guard !key.isEmpty else { return nil }
        return syncStore.names(for: key)
    }

    /// 已经有答案（或者刚失败过、正被拦着）就直接给出，不用排队；外层 nil 表示要去查。
    private func settled(_ key: String) -> [String]?? {
        if let hit = found[key] { return .some(hit) }
        let current = now()
        if let time = empty[key], current.timeIntervalSince(time) < Self.noneLifetime { return .some([]) }
        if let time = failed[key], current.timeIntervalSince(time) < Self.failureLifetime { return .some(nil) }
        if current < pausedUntil { return .some(nil) }
        return nil
    }

    /// 查一部片的女优名：查到返回名字，确认没有返回空数组，查不了（出错、被拦、任务取消）返回 nil。
    func names(for item: MagnetSearchItem) async -> [String]? {
        let key = Self.key(for: item)
        guard !key.isEmpty, !Task.isCancelled else { return nil }
        if let answer = settled(key) { return answer }

        let id = UUID()
        return await withTaskCancellationHandler {
            await self.wait(key, item: item, id: id)
        } onCancel: {
            Task { await self.cancelWaiter(id, key: key) }
        }
    }

    /// 详情页拿到了参演女优：顺手记下，回到列表时卡片直接有名字。
    func record(_ names: [String], for item: MagnetSearchItem) {
        let key = Self.key(for: item)
        let cleaned = PerformerName.unique(names)
        guard !key.isEmpty, !cleaned.isEmpty else { return }
        if found[key] != cleaned {
            store(cleaned, for: key)
        }
        resume(key, with: cleaned)
        if !running.contains(key) {
            pending.removeAll { $0 == key }
            queuedItems[key] = nil
            prefetchKeys.remove(key)
        }
    }

    /// 预取：卡片一出现（或者快要滑到）就排上，不等有卡片来要。按传进来的顺序查，
    /// 排在屏幕上正在等的卡片后面；没人等的预取最多留 maxIdlePrefetch 个，多了丢最早的。
    func prefetch(_ items: [MagnetSearchItem]) {
        for item in items {
            let key = Self.key(for: item)
            guard !key.isEmpty, settled(key) == nil, !running.contains(key) else { continue }
            prefetchKeys.insert(key)
            queuedItems[key] = item
            if !pending.contains(key) {
                pending.append(key)
            }
        }
        trimIdlePrefetch()
        startWorkers()
    }

    /// 立刻把缓存写到磁盘（平时是攒一下再写）。
    func flush() {
        persistTask?.cancel()
        persistNow()
    }

    // MARK: - 排队

    /// 排进队列，等这个番号查完（或者调用方取消）。
    private func wait(_ key: String, item: MagnetSearchItem, id: UUID) async -> [String]? {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String]?, Never>) in
            enqueue(key, item: item, id: id, continuation: continuation)
        }
    }

    private func enqueue(_ key: String, item: MagnetSearchItem, id: UUID,
                         continuation: CheckedContinuation<[String]?, Never>) {
        if Task.isCancelled {
            continuation.resume(returning: nil)
            return
        }
        waiters[key, default: [:]][id] = continuation
        guard !running.contains(key) else { return }
        // 已经在排的（预取排进来的）保持原来的位置：先出现的卡片先查
        if !pending.contains(key) {
            pending.append(key)
        }
        queuedItems[key] = item
        startWorkers()
    }

    private func cancelWaiter(_ id: UUID, key: String) {
        guard let continuation = waiters[key]?.removeValue(forKey: id) else { return }
        continuation.resume(returning: nil)
        guard waiters[key]?.isEmpty ?? true else { return }
        waiters[key] = nil
        guard !running.contains(key) else { return }
        if prefetchKeys.contains(key) {
            // 卡片滑走了，但这是预取的：留着当预取，太多时丢最早的
            trimIdlePrefetch()
        } else {
            // 还没轮到就没人要了：从队列里拿掉，不发请求
            pending.removeAll { $0 == key }
            queuedItems[key] = nil
        }
    }

    private func hasWaiters(_ key: String) -> Bool {
        !(waiters[key]?.isEmpty ?? true)
    }

    /// 没有卡片在等的预取超过上限时，丢掉最早排进来的（已经在查的不动）。
    private func trimIdlePrefetch() {
        let idle = pending.filter { !hasWaiters($0) }
        guard idle.count > Self.maxIdlePrefetch else { return }
        let dropped = Set(idle.prefix(idle.count - Self.maxIdlePrefetch))
        pending.removeAll { dropped.contains($0) }
        for key in dropped {
            queuedItems[key] = nil
            prefetchKeys.remove(key)
        }
    }

    private func startWorkers() {
        while workers < min(Self.maxConcurrent, pending.count + running.count) {
            workers += 1
            Task { await self.work() }
        }
    }

    /// 下一个要查的：屏幕上有卡片在等的里面最早排进来的；都没人等就按预取的先后。
    private func takeNext() -> String? {
        guard !pending.isEmpty else { return nil }
        let index = pending.firstIndex { hasWaiters($0) } ?? 0
        let key = pending.remove(at: index)
        running.insert(key)
        return key
    }

    /// 给下一次请求排一个开始时间，返回还要等多久。
    private func reserveStartSlot() -> TimeInterval {
        let current = now()
        let start = max(current, nextStartAt)
        nextStartAt = start.addingTimeInterval(startInterval)
        return start.timeIntervalSince(current)
    }

    private func work() async {
        while let key = takeNext() {
            let delay = reserveStartSlot()
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            // 等的这一会儿里卡片滑走了、又不是预取的：不查了
            guard let item = queuedItems[key], hasWaiters(key) || prefetchKeys.contains(key) else {
                running.remove(key)
                queuedItems[key] = nil
                prefetchKeys.remove(key)
                resume(key, with: nil)
                continue
            }
            if now() < pausedUntil {
                running.remove(key)
                queuedItems[key] = nil
                prefetchKeys.remove(key)
                resume(key, with: nil)
                continue
            }
            let outcome = await lookup(item)
            finish(key, outcome)
        }
        workers -= 1
    }

    private func finish(_ key: String, _ outcome: Outcome) {
        running.remove(key)
        queuedItems[key] = nil
        prefetchKeys.remove(key)
        let result: [String]?
        switch outcome {
        case .found(let raw):
            let names = PerformerName.unique(raw)
            if names.isEmpty {
                markEmpty(key)
                result = []
            } else {
                store(names, for: key)
                result = names
            }
        case .none:
            markEmpty(key)
            result = []
        case .unavailable:
            failed[key] = now()
            result = nil
        case .blocked:
            failed[key] = now()
            pausedUntil = now().addingTimeInterval(Self.blockedPause)
            result = nil
        }
        resume(key, with: result)
        if outcome == .blocked {
            dropPending()
        }
    }

    private func resume(_ key: String, with result: [String]?) {
        let list = waiters.removeValue(forKey: key) ?? [:]
        for continuation in list.values {
            continuation.resume(returning: result)
        }
    }

    /// 被拦了：还在排队的全部作罢，等暂停过去、卡片再出现时重新排。
    private func dropPending() {
        let keys = pending
        pending.removeAll()
        prefetchKeys.removeAll()
        for key in keys {
            queuedItems[key] = nil
            resume(key, with: nil)
        }
    }

    // MARK: - 缓存

    private func store(_ names: [String], for key: String) {
        found[key] = names
        empty[key] = nil
        failed[key] = nil
        foundOrder.removeAll { $0 == key }
        foundOrder.append(key)
        syncStore.set(names, for: key)
        if foundOrder.count > Self.maxEntries {
            let overflow = foundOrder.count - Self.maxEntries
            for old in foundOrder.prefix(overflow) {
                found[old] = nil
                syncStore.set(nil, for: old)
            }
            foundOrder.removeFirst(overflow)
        }
        schedulePersist()
    }

    private func markEmpty(_ key: String) {
        empty[key] = now()
        failed[key] = nil
        if found[key] == nil {
            syncStore.set([], for: key)
        }
        schedulePersist()
    }

    private func schedulePersist() {
        guard cacheFile != nil, persistTask == nil else { return }
        persistTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await self.persistNow()
        }
    }

    private func persistNow() {
        persistTask = nil
        guard let cacheFile else { return }
        let current = now()
        empty = empty.filter { current.timeIntervalSince($0.value) < Self.noneLifetime }
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let payload = DiskPayload(order: foundOrder, names: found, empty: empty)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: cacheFile, options: .atomic)
    }
}
