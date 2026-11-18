import SwiftUI
import Combine

/// 番剧列表页的数据：排序、筛选条件、已加载的条目和翻页。
///
/// 筛选参数照样发给服务端，再用 AnimeFilterSupport 核对：服务端认的项直接信，不认的项在 App 里筛，
/// 一次多翻几页凑够一屏。总数只有在每一项都被服务端认了时才显示「共 N 部」，否则显示「已找到 N 部」。
@MainActor
final class AnimeBrowseModel: ObservableObject {
    @Published private(set) var sort: String
    @Published private(set) var filter = AnimeBrowseFilter()
    @Published private(set) var items: [AnimeVideoItem] = []
    /// 服务端给的、可信的总数；不可信时为 nil
    @Published private(set) var trustedTotal: Int?
    @Published private(set) var hasMore = true
    @Published private(set) var isReloading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?
    /// 本次查询已经翻过的页数（App 自己筛时用来提示「已经翻了几页」）
    @Published private(set) var scannedPages = 0
    /// 上一轮翻页一条都没筛到（还有下一页时给出「继续查找」）
    @Published private(set) var lastRoundEmpty = false
    /// 最近改的一项：没有结果时建议先去掉它
    private(set) var lastChanged: AnimeFilterField?

    /// 列表页本身的频道（日漫页就是日漫）；nil 是「全部」类列表
    let baseChannelId: Int?
    /// 年份选项，判断「更早」这类年份时用；由页面在选项变化时传进来
    var knownYears: [String] = []

    let pageSize = 18
    private let scanLimit = 36
    private var limit = 18
    private var nextPage = 1
    private var seenIds = Set<Int>()
    /// 每次重新拉取都 +1，迟到的旧请求直接丢弃，免得内容串了
    private var generation = 0

    init(route: AnimeBrowseRoute) {
        baseChannelId = route.channelId
        sort = route.sort
    }

    var channelId: Int? { filter.channelId ?? baseChannelId }

    // MARK: 改条件

    func setSort(_ value: String) {
        guard sort != value else { return }
        sort = value
        Task { await reload() }
    }

    func set(_ field: AnimeFilterField, _ change: (inout AnimeBrowseFilter) -> Void) {
        var next = filter
        change(&next)
        guard next != filter else { return }
        // 换频道后，原来选的类型 / 地区不一定还有，留着由页面判断是否显示；年份和状态通用
        lastChanged = next.isSet(field) ? field : nil
        filter = next
        Task { await reload() }
    }

    /// 筛选面板一次改完
    func apply(filter newFilter: AnimeBrowseFilter, sort newSort: String) {
        guard newFilter != filter || newSort != sort else { return }
        lastChanged = newFilter.activeFields.last { newFilter.isSet($0) && !filter.isSet($0) } ?? lastChanged
        filter = newFilter
        sort = newSort
        Task { await reload() }
    }

    func clearAll() {
        guard !filter.isEmpty else { return }
        filter = AnimeBrowseFilter()
        lastChanged = nil
        Task { await reload() }
    }

    /// 没有结果时建议去掉的那一项
    var suggestedRelax: AnimeFilterField? {
        if let lastChanged, filter.isSet(lastChanged) { return lastChanged }
        return filter.activeFields.last
    }

    func relax(_ field: AnimeFilterField) {
        set(field) { $0.clear(field) }
        lastChanged = nil
    }

    // MARK: 加载

    func loadIfNeeded() async {
        if items.isEmpty && !isReloading && errorMessage == nil { await reload() }
    }

    func reload() async {
        generation += 1
        let current = generation
        isReloading = true
        isLoadingMore = false
        hasMore = true
        errorMessage = nil
        lastRoundEmpty = false
        items = []
        trustedTotal = nil
        seenIds = []
        nextPage = 1
        scannedPages = 0
        limit = AnimeFilterSupport.shared.needsLocalScan(for: filter) ? scanLimit : pageSize
        defer { if current == generation { isReloading = false } }
        await fill(generation: current, maxPages: 8)
    }

    func loadMore() async {
        guard !isReloading, !isLoadingMore, hasMore else { return }
        let current = generation
        isLoadingMore = true
        defer { if current == generation { isLoadingMore = false } }
        let scanning = !AnimeFilterSupport.shared.trustsTotal(for: filter)
        await fill(generation: current, maxPages: scanning ? 6 : 1)
    }

    /// 一页页往下拉，直到凑够一屏（pageSize 条）、到底、或这一轮翻够 maxPages 页。
    private func fill(generation current: Int, maxPages: Int) async {
        var added = 0
        var pages = 0
        while hasMore && added < pageSize && pages < maxPages {
            let page = nextPage
            let query = filter
            do {
                let result = try await AnimeClient.shared.fetchVideoList(
                    channel: channelId, sort: sort, limit: limit, page: page, filters: query.serverParameters)
                guard current == generation else { return }
                if page == 1 {
                    AnimeFilterSupport.shared.record(items: result.items, filter: query, knownYears: knownYears)
                }
                pages += 1
                scannedPages += 1
                nextPage = page + 1
                // 按上线时间排序时，翻页过程中新番插入会让下一页重复返回上一页的条目；过滤掉重复 id
                let fresh = result.items.filter { seenIds.insert($0.id).inserted }
                let kept = fresh.filter { query.admits($0, knownYears: knownYears) }
                items.append(contentsOf: kept)
                added += kept.count
                trustedTotal = AnimeFilterSupport.shared.trustsTotal(for: query) ? result.total : nil
                if fresh.isEmpty || result.items.count < limit || page * limit >= result.total {
                    hasMore = false
                }
            } catch {
                guard current == generation else { return }
                if items.isEmpty { errorMessage = error.localizedDescription }
                hasMore = false
                return
            }
        }
        lastRoundEmpty = added == 0 && hasMore
    }

    /// 筛选面板里「查看 N 部」的数：拉第一页看服务端认不认，认就给总数，不认返回 nil。
    func previewCount(filter draft: AnimeBrowseFilter, sort draftSort: String) async -> Int? {
        let channel = draft.channelId ?? baseChannelId
        guard let result = try? await AnimeClient.shared.fetchVideoList(
            channel: channel, sort: draftSort, limit: pageSize, page: 1, filters: draft.serverParameters) else { return nil }
        AnimeFilterSupport.shared.record(items: result.items, filter: draft, knownYears: knownYears)
        guard AnimeFilterSupport.shared.trustsTotal(for: draft) else { return nil }
        return result.total
    }
}
