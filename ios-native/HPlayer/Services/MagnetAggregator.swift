import Foundation

/// 聚合 JavBus 与 Sukebei Nyaa RSS：
/// - Sukebei 提供刚出种的新作（先行配信/流出）与更多磁力/做种数；
/// - JavBus 提供封面、演员资料与分页浏览。
final class MagnetAggregator: @unchecked Sendable {
    static let shared = MagnetAggregator()

    private let javbus: JavBusSource
    private let sukebei: SukebeiSource

    init(javbus: JavBusSource = .shared, sukebei: SukebeiSource = .shared) {
        self.javbus = javbus
        self.sukebei = sukebei
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

    // MARK: - 聚合异步接口

    func fetchLatest(page: Int = 1) async throws -> [MagnetSearchItem] {
        try await javbus.fetchCategory(.latest, page: page)
    }

    func fetchFreshLatest() async throws -> [MagnetSearchItem] {
        try await sukebei.fetchLatest()
    }

    func fetchStudio(_ studio: MagnetStudio, page: Int = 1) async throws -> [MagnetSearchItem] {
        if page > 1 {
            return try await javbus.fetchStudio(studio, page: page)
        }

        async let jbResult: Result<[MagnetSearchItem], Error> = {
            do { return .success(try await javbus.fetchStudio(studio, page: 1)) }
            catch { return .failure(error) }
        }()
        async let sbResult: Result<[MagnetSearchItem], Error> = {
            do { return .success(try await sukebei.fetchStudio(studio)) }
            catch { return .failure(error) }
        }()

        let (jb, sb) = await (jbResult, sbResult)
        if case let .failure(err) = jb, err is CancellationError { throw err }
        if case let .failure(err) = sb, err is CancellationError { throw err }
        try Task.checkCancellation()

        switch (jb, sb) {
        case let (.success(jbItems), .success(sbItems)):
            return Self.mergeStudioPage1(javbus: jbItems, sukebei: sbItems)
        case let (.success(jbItems), .failure):
            return jbItems
        case let (.failure(jbError), .success(sbItems)):
            if !sbItems.isEmpty { return sbItems }
            throw jbError
        case let (.failure(jbError), .failure):
            throw jbError
        }
    }

    func searchAll(keyword: String, page: Int = 1) async throws -> (movies: [MagnetSearchItem], stars: [MagnetStarItem]) {
        if page > 1 {
            return (try await javbus.search(keyword: keyword, page: page), [])
        }

        async let jbResult: Result<(movies: [MagnetSearchItem], stars: [MagnetStarItem]), Error> = {
            do { return .success(try await javbus.searchAll(keyword: keyword, page: 1)) }
            catch { return .failure(error) }
        }()
        async let sbResult: Result<[MagnetSearchItem], Error> = {
            do { return .success(try await sukebei.search(keyword: keyword)) }
            catch { return .failure(error) }
        }()

        let (jb, sb) = await (jbResult, sbResult)
        if case let .failure(err) = jb, err is CancellationError { throw err }
        if case let .failure(err) = sb, err is CancellationError { throw err }
        try Task.checkCancellation()

        switch (jb, sb) {
        case let (.success(jbValue), .success(sbMovies)):
            return (Self.mergeSearchPage1(keyword: keyword, javbus: jbValue.movies, sukebei: sbMovies), jbValue.stars)
        case let (.success(jbValue), .failure):
            return jbValue
        case let (.failure(jbError), .success(sbMovies)):
            if !sbMovies.isEmpty { return (sbMovies, []) }
            throw jbError
        case let (.failure(jbError), .failure):
            throw jbError
        }
    }

    func fetchDetailInfo(for item: MagnetSearchItem) async throws -> (stars: [MagnetStarItem], magnets: [MagnetTorrentItem]) {
        async let jbResult: Result<(stars: [MagnetStarItem], magnets: [MagnetTorrentItem]), Error> = {
            do { return .success(try await javbus.fetchDetailInfo(for: item)) }
            catch { return .failure(error) }
        }()
        async let sbResult: Result<[MagnetTorrentItem], Error> = {
            guard !item.code.isEmpty else { return .success([]) }
            do { return .success(try await sukebei.fetchMagnets(code: item.code)) }
            catch { return .failure(error) }
        }()

        let (jb, sb) = await (jbResult, sbResult)
        if case let .failure(err) = jb, err is CancellationError { throw err }
        if case let .failure(err) = sb, err is CancellationError { throw err }
        try Task.checkCancellation()

        let jbValue = try? jb.get()
        let sbMagnets = (try? sb.get()) ?? []
        let merged = Self.mergeMagnets(
            javbus: jbValue?.magnets ?? [],
            sukebei: sbMagnets,
            prefetched: item.prefetchedMagnets
        )

        if let jbValue {
            return (stars: jbValue.stars, magnets: merged)
        }
        if !merged.isEmpty {
            return (stars: [], magnets: merged)
        }
        if case let .failure(jbError) = jb,
           case JavBusError.notFound = jbError,
           case .success = sb {
            return (stars: [], magnets: [])
        }
        if case let .failure(jbError) = jb {
            throw jbError
        }
        return (stars: [], magnets: merged)
    }
}
