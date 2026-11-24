import Foundation

/// 聚合 JavBus 与 Sukebei Nyaa RSS：
/// - Sukebei 提供刚出种的新作（先行配信/流出）与更多磁力/做种数；
/// - JavBus 提供封面、演员资料与分页浏览。
final class MagnetAggregator: @unchecked Sendable {
    static let shared = MagnetAggregator()

    private let javbus: JavBusSource
    private let sukebei: SukebeiSource
    private let sukebeiSoftTimeout: TimeInterval

    init(
        javbus: JavBusSource = .shared,
        sukebei: SukebeiSource = .shared,
        sukebeiSoftTimeout: TimeInterval = 3.5
    ) {
        self.javbus = javbus
        self.sukebei = sukebei
        self.sukebeiSoftTimeout = sukebeiSoftTimeout
    }

    // MARK: - 合并与排序辅助

    static func normalizedCodeKey(for item: MagnetSearchItem) -> String {
        if !item.code.isEmpty {
            return item.code.uppercased()
        }
        return item.id.lowercased()
    }

    static func splitCode(_ code: String) -> (prefix: String, number: Int)? {
        let parts = code.uppercased().split(separator: "-", maxSplits: 1)
        guard parts.count == 2, let number = Int(parts[1]) else { return nil }
        return (String(parts[0]), number)
    }

    /// 跨页/跨源去重：同一番号（无论路径是 JavBus 的还是 `/SONE-456`）只保留一次。
    static func mergeUniqueMovies(
        _ existing: [MagnetSearchItem],
        with new: [MagnetSearchItem]
    ) -> (merged: [MagnetSearchItem], added: Int) {
        var seen = Set(existing.map(normalizedCodeKey))
        var merged = existing
        var added = 0
        for item in new where seen.insert(normalizedCodeKey(for: item)).inserted {
            merged.append(item)
            added += 1
        }
        return (merged, added)
    }

    /// 片商第 1 页：把 Sukebei 刚出种但 JavBus 还没上架的新片置顶，过滤明显古老的重传。
    static func mergeStudioPage1(
        javbus: [MagnetSearchItem],
        sukebei: [MagnetSearchItem],
        staleMargin: Int = 60
    ) -> [MagnetSearchItem] {
        guard !javbus.isEmpty else { return sukebei }

        let javbusKeys = Set(javbus.map(normalizedCodeKey))
        var maxNumberByPrefix: [String: Int] = [:]
        for item in javbus {
            if let (prefix, number) = splitCode(item.code) {
                maxNumberByPrefix[prefix] = max(maxNumberByPrefix[prefix] ?? 0, number)
            }
        }

        var seen = javbusKeys
        var freshOnly: [MagnetSearchItem] = []
        for item in sukebei {
            let key = normalizedCodeKey(for: item)
            guard seen.insert(key).inserted else { continue }
            if let (prefix, number) = splitCode(item.code),
               let maxNum = maxNumberByPrefix[prefix],
               number < maxNum - staleMargin {
                continue
            }
            freshOnly.append(item)
        }
        return freshOnly + javbus
    }

    /// 用 JavBus 第 1 页已知的封面/标题/女优补齐 Sukebei「最新出种」横架，保留 `isFresh` 与预取磁力。
    static func enrichSukebeiShelf(
        _ sukebei: [MagnetSearchItem],
        with javbus: [MagnetSearchItem]
    ) -> [MagnetSearchItem] {
        var javbusByKey: [String: MagnetSearchItem] = [:]
        for item in javbus {
            let key = normalizedCodeKey(for: item)
            if javbusByKey[key] == nil {
                javbusByKey[key] = item
            }
        }
        return sukebei.map { item in
            let key = normalizedCodeKey(for: item)
            guard let rich = javbusByKey[key] else { return item }
            return MagnetSearchItem(
                id: rich.id,
                code: rich.code.isEmpty ? item.code : rich.code,
                title: rich.title,
                coverURL: rich.coverURL ?? item.coverURL,
                releaseDate: item.releaseDate ?? rich.releaseDate,
                detailPath: rich.detailPath,
                stars: rich.stars,
                isFresh: true,
                prefetchedMagnets: item.prefetchedMagnets
            )
        }
    }

    /// 搜索第 1 页：合并 JavBus 与 Sukebei 去重，精确命中搜索番号的条目排到最前面。
    static func mergeSearchPage1(
        keyword: String,
        javbus: [MagnetSearchItem],
        sukebei: [MagnetSearchItem]
    ) -> [MagnetSearchItem] {
        let combined = mergeUniqueMovies(javbus, with: sukebei).merged
        guard let targetCode = AVCatalogCode.extract(keyword) else {
            return combined
        }
        let exact = combined.filter { normalizedCodeKey(for: $0) == targetCode }
        let rest = combined.filter { normalizedCodeKey(for: $0) != targetCode }
        return exact + rest
    }

    /// 合并多来源磁力并按 infoHash 去重、补齐标签/做种数/大小/日期后排序。
    static func mergeMagnets(
        javbus: [MagnetTorrentItem],
        sukebei: [MagnetTorrentItem],
        prefetched: [MagnetTorrentItem] = []
    ) -> [MagnetTorrentItem] {
        var orderedKeys: [String] = []
        var byKey: [String: MagnetTorrentItem] = [:]

        for torrent in javbus + sukebei + prefetched {
            let key = MagnetLink.parse(torrent.magnetURL)?.infoHash.lowercased()
                ?? torrent.magnetURL.lowercased()
            if let existing = byKey[key] {
                byKey[key] = MagnetTorrentItem(
                    id: existing.id,
                    magnetURL: existing.magnetURL,
                    name: existing.name,
                    size: existing.size == "未知大小" ? torrent.size : existing.size,
                    date: existing.date ?? torrent.date,
                    isHD: existing.isHD || torrent.isHD,
                    hasSubtitles: existing.hasSubtitles || torrent.hasSubtitles,
                    seeders: existing.seeders ?? torrent.seeders,
                    source: existing.source ?? torrent.source
                )
            } else {
                orderedKeys.append(key)
                byKey[key] = torrent
            }
        }

        return sortMagnets(orderedKeys.compactMap { byKey[$0] })
    }

    /// 严格弱序：中文字幕 > 高清 > 日期新 > 做种多，同分保持原序。
    static func sortMagnets(_ magnets: [MagnetTorrentItem]) -> [MagnetTorrentItem] {
        magnets.enumerated().sorted { lhs, rhs in
            let a = lhs.element
            let b = rhs.element
            let aKey = (a.hasSubtitles ? 1 : 0, a.isHD ? 1 : 0, a.date ?? "", a.seeders ?? -1)
            let bKey = (b.hasSubtitles ? 1 : 0, b.isHD ? 1 : 0, b.date ?? "", b.seeders ?? -1)
            if aKey != bKey {
                return aKey > bKey
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    // MARK: - 聚合异步接口（非阻塞渐进返回 + Sukebei 软超时）

    func fetchLatest(page: Int = 1) async throws -> [MagnetSearchItem] {
        try await javbus.fetchCategory(.latest, page: page)
    }

    /// 同步读取磁盘/内存缓存的 Sukebei 最新出种列表，用于首屏秒开后再后台更新。
    func cachedFreshLatest() -> [MagnetSearchItem] {
        sukebei.cachedLatest()
    }

    func fetchFreshLatest() async throws -> [MagnetSearchItem] {
        try await sukebei.fetchLatest()
    }

    /// 片商第 1 页渐进加载：JavBus 先返回即先通过 `onUpdate` 渲染，Sukebei 在后台软超时内到达后合并新种。
    func loadStudioPage1(
        _ studio: MagnetStudio,
        onUpdate: @MainActor @escaping ([MagnetSearchItem]) -> Void
    ) async throws -> [MagnetSearchItem] {
        try await loadStudioPage1Internal(studio, onUpdate: onUpdate)
    }

    private func loadStudioPage1Internal(
        _ studio: MagnetStudio,
        onUpdate: @MainActor @escaping ([MagnetSearchItem]) -> Void
    ) async throws -> [MagnetSearchItem] {
        let jbTask = Task<Result<[MagnetSearchItem], Error>, Never> {
            do { return .success(try await self.javbus.fetchStudio(studio, page: 1)) }
            catch { return .failure(error) }
        }
        let sbTask = Task<Result<[MagnetSearchItem], Error>, Never> {
            do { return .success(try await self.sukebei.fetchStudio(studio)) }
            catch { return .failure(error) }
        }

        return try await withTaskCancellationHandler {
            let jb = await jbTask.value
            try Task.checkCancellation()

            switch jb {
            case .success(let jbItems):
                if !jbItems.isEmpty {
                    await onUpdate(jbItems)
                }
                if let sb = await awaitWithSoftTimeout(sbTask, timeout: sukebeiSoftTimeout),
                   case .success(let sbItems) = sb {
                    let merged = Self.mergeStudioPage1(javbus: jbItems, sukebei: sbItems)
                    if merged != jbItems || jbItems.isEmpty {
                        await onUpdate(merged)
                    }
                    return merged
                }
                if jbItems.isEmpty {
                    await onUpdate(jbItems)
                }
                return jbItems

            case .failure(let jbError):
                if jbError is CancellationError {
                    sbTask.cancel()
                    throw jbError
                }
                let sb = await sbTask.value
                try Task.checkCancellation()
                if case .success(let sbItems) = sb, !sbItems.isEmpty {
                    await onUpdate(sbItems)
                    return sbItems
                }
                throw jbError
            }
        } onCancel: {
            jbTask.cancel()
            sbTask.cancel()
        }
    }

    func fetchStudio(_ studio: MagnetStudio, page: Int = 1) async throws -> [MagnetSearchItem] {
        if page > 1 {
            return try await javbus.fetchStudio(studio, page: page)
        }
        return try await loadStudioPage1Internal(studio) { _ in }
    }

    /// 搜索第 1 页渐进加载：JavBus 与女优先到先显示，Sukebei 在软超时内抵达后再增量合并。
    func searchAllProgressive(
        keyword: String,
        onUpdate: @MainActor @escaping ((movies: [MagnetSearchItem], stars: [MagnetStarItem])) -> Void
    ) async throws -> (movies: [MagnetSearchItem], stars: [MagnetStarItem]) {
        let jbTask = Task<Result<(movies: [MagnetSearchItem], stars: [MagnetStarItem]), Error>, Never> {
            do { return .success(try await self.javbus.searchAll(keyword: keyword, page: 1)) }
            catch { return .failure(error) }
        }
        let sbTask = Task<Result<[MagnetSearchItem], Error>, Never> {
            do { return .success(try await self.sukebei.search(keyword: keyword)) }
            catch { return .failure(error) }
        }

        return try await withTaskCancellationHandler {
            let jb = await jbTask.value
            try Task.checkCancellation()

            switch jb {
            case .success(let jbValue):
                if !jbValue.movies.isEmpty || !jbValue.stars.isEmpty {
                    await onUpdate(jbValue)
                }
                if let sb = await awaitWithSoftTimeout(sbTask, timeout: sukebeiSoftTimeout),
                   case .success(let sbMovies) = sb {
                    let merged = Self.mergeSearchPage1(keyword: keyword, javbus: jbValue.movies, sukebei: sbMovies)
                    let finalValue = (movies: merged, stars: jbValue.stars)
                    if merged != jbValue.movies || (jbValue.movies.isEmpty && jbValue.stars.isEmpty) {
                        await onUpdate(finalValue)
                    }
                    return finalValue
                }
                if jbValue.movies.isEmpty && jbValue.stars.isEmpty {
                    await onUpdate(jbValue)
                }
                return jbValue

            case .failure(let jbError):
                if jbError is CancellationError {
                    sbTask.cancel()
                    throw jbError
                }
                let sb = await sbTask.value
                try Task.checkCancellation()
                if case .success(let sbMovies) = sb, !sbMovies.isEmpty {
                    let fallback = (movies: sbMovies, stars: [MagnetStarItem]())
                    await onUpdate(fallback)
                    return fallback
                }
                throw jbError
            }
        } onCancel: {
            jbTask.cancel()
            sbTask.cancel()
        }
    }

    func searchAll(keyword: String, page: Int = 1) async throws -> (movies: [MagnetSearchItem], stars: [MagnetStarItem]) {
        if page > 1 {
            return (try await javbus.search(keyword: keyword, page: page), [])
        }
        return try await searchAllProgressive(keyword: keyword) { _ in }
    }

    /// 影片详情渐进加载：JavBus 拿到女优与磁力立即合并已有预取返回，Sukebei 到后再补充做种数与新资源。
    func loadDetailInfo(
        for item: MagnetSearchItem,
        onUpdate: @MainActor @escaping ((stars: [MagnetStarItem], magnets: [MagnetTorrentItem])) -> Void
    ) async throws -> (stars: [MagnetStarItem], magnets: [MagnetTorrentItem]) {
        let jbTask = Task<Result<(stars: [MagnetStarItem], magnets: [MagnetTorrentItem]), Error>, Never> {
            do { return .success(try await self.javbus.fetchDetailInfo(for: item)) }
            catch { return .failure(error) }
        }
        let sbTask = Task<Result<[MagnetTorrentItem], Error>, Never> {
            guard !item.code.isEmpty else { return .success([]) }
            do { return .success(try await self.sukebei.fetchMagnets(code: item.code)) }
            catch { return .failure(error) }
        }

        return try await withTaskCancellationHandler {
            let jb = await jbTask.value
            try Task.checkCancellation()

            switch jb {
            case .success(let jbValue):
                let initialMerged = Self.mergeMagnets(
                    javbus: jbValue.magnets,
                    sukebei: [],
                    prefetched: item.prefetchedMagnets
                )
                let initial = (stars: jbValue.stars, magnets: initialMerged)
                await onUpdate(initial)

                guard !item.code.isEmpty else { return initial }
                if let sb = await awaitWithSoftTimeout(sbTask, timeout: sukebeiSoftTimeout),
                   case .success(let sbMagnets) = sb,
                   !sbMagnets.isEmpty {
                    let finalMerged = Self.mergeMagnets(
                        javbus: jbValue.magnets,
                        sukebei: sbMagnets,
                        prefetched: item.prefetchedMagnets
                    )
                    if finalMerged != initialMerged {
                        let finalValue = (stars: jbValue.stars, magnets: finalMerged)
                        await onUpdate(finalValue)
                        return finalValue
                    }
                }
                return initial

            case .failure(let jbError):
                if jbError is CancellationError {
                    sbTask.cancel()
                    throw jbError
                }
                let sb = await sbTask.value
                try Task.checkCancellation()
                let sbMagnets = (try? sb.get()) ?? []
                let merged = Self.mergeMagnets(javbus: [], sukebei: sbMagnets, prefetched: item.prefetchedMagnets)
                if !merged.isEmpty {
                    let result = (stars: [MagnetStarItem](), magnets: merged)
                    await onUpdate(result)
                    return result
                }
                if case JavBusError.notFound = jbError, case .success = sb {
                    let empty = (stars: [MagnetStarItem](), magnets: [MagnetTorrentItem]())
                    await onUpdate(empty)
                    return empty
                }
                throw jbError
            }
        } onCancel: {
            jbTask.cancel()
            sbTask.cancel()
        }
    }

    func fetchDetailInfo(for item: MagnetSearchItem) async throws -> (stars: [MagnetStarItem], magnets: [MagnetTorrentItem]) {
        try await loadDetailInfo(for: item) { _ in }
    }

    private func awaitWithSoftTimeout<T: Sendable>(
        _ task: Task<Result<T, Error>, Never>,
        timeout: TimeInterval
    ) async -> Result<T, Error>? {
        guard timeout > 0 else {
            task.cancel()
            return nil
        }
        let race = SoftTimeoutRace<Result<T, Error>>()
        let sleeper = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if race.complete(with: nil) {
                task.cancel()
            }
        }
        let waiter = Task {
            let value = await task.value
            if race.complete(with: value) {
                sleeper.cancel()
            }
        }
        return await withTaskCancellationHandler {
            await race.awaitResult()
        } onCancel: {
            sleeper.cancel()
            waiter.cancel()
            task.cancel()
            race.complete(with: nil)
        }
    }
}

private final class SoftTimeoutRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?
    private var resolved = false
    private var resolvedValue: Value?

    func awaitResult() async -> Value? {
        await withCheckedContinuation { cont in
            lock.lock()
            if resolved {
                let value = resolvedValue
                lock.unlock()
                cont.resume(returning: value)
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }

    @discardableResult
    func complete(with value: Value?) -> Bool {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return false
        }
        resolved = true
        resolvedValue = value
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
        return true
    }
}
