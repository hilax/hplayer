import SwiftUI

struct AnimeCatalogView: View {
    var onSearch: () -> Void

    // MARK: 内容

    @State private var channels: [AnimeChannel] = []
    @State private var banners: [AnimeBanner] = []
    @State private var trendingItems: [AnimeVideoItem] = []
    /// 推荐页里每个频道的货架，按频道 id 存；滚到可见时才拉，首屏只并发前几个。
    @State private var shelves: [Int: [AnimeVideoItem]] = [:]
    @State private var loadingShelves: Set<Int> = []
    /// 拉失败的货架单独记，不能塞进 shelves 当空数组——那样会被当成「已加载」，
    /// 网络恢复后也永远不再重试，页面上只剩一排空标题。
    @State private var failedShelves: Set<Int> = []
    @State private var gridItems: [AnimeVideoItem] = []

    // MARK: 筛选与分页

    /// nil = 推荐页；非 nil = 该频道的完整网格。
    @State private var selectedChannelId: Int? = nil
    @State private var sort = "addtime"
    @State private var currentPage = 1
    @State private var totalCount = 0
    @State private var hasMore = true
    private let pageSize = 18
    private let shelfSize = 6
    /// 首屏并发拉取的货架数量，其余滚动到可见时再拉。
    private let eagerShelfCount = 3

    // MARK: 加载状态

    @State private var isReloading = false
    @State private var isLoadingMore = false
    @State private var initialLoaded = false
    @State private var errorMessage: String? = nil
    /// 每次重新拉取都 +1，迟到的旧请求（例如切换频道前发出的下一页）直接丢弃，
    /// 否则旧频道的数据会追加到新频道列表里，看起来就是「内容串了」。
    @State private var loadGeneration = 0
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            let metrics = gridMetrics(width: proxy.size.width)

            VStack(spacing: 0) {
                AnimeChannelBar(
                    channels: channels,
                    selectedChannelId: $selectedChannelId,
                    onSelect: { channelId in selectChannel(channelId) }
                )

                // 频道切换时重建滚动容器：回到顶部，不把旧频道滚到底的偏移带到新列表
                ScrollView {
                    if selectedChannelId == nil {
                        recommendContent
                    } else {
                        channelContent(metrics: metrics)
                    }
                }
                .id("anime-scroll-\(selectedChannelId ?? 0)")
                .scrollIndicators(.hidden)
                .refreshable {
                    await reload(channel: selectedChannelId)
                }
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationDestination(for: AnimeDetailRoute.self) { route in
            AnimeDetailView(animeId: route.animeId)
                .id(route.animeId)
        }
        .task {
            guard !initialLoaded else { return }
            initialLoaded = true
            beginLoad(channel: nil)
        }
    }

    // MARK: - 推荐页：轮播 + 热门新番 + 各频道货架

    private var recommendContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !banners.isEmpty {
                AnimeHeroBanner(banners: banners)
                    .padding(.top, 4)
            }

            if !trendingItems.isEmpty {
                shelf(title: "热门新番", items: trendingItems, detail: "共 \(trendingItems.count) 部", destination: nil)
            }

            ForEach(channels) { channel in
                channelShelf(channel)
            }

            if isReloading && banners.isEmpty && trendingItems.isEmpty && shelves.isEmpty {
                recommendSkeleton
            } else if !isReloading && banners.isEmpty && trendingItems.isEmpty && channels.isEmpty {
                // 全部板块都没拉到时必须给出说明和重试入口，否则整页一片空白，
                // 看起来就是「首页加载不出来」，用户也不知道该做什么。
                recommendFailedState
            }
        }
        .padding(.bottom, 80)
    }

    private var recommendFailedState: some View {
        VStack(spacing: 12) {
            Image(icon: .alert)
                .iconStyle(size: 36, color: Theme.textTertiary)
            Text("推荐内容没加载出来")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("接口没能连上。下拉可以刷新，或点下面的按钮重试。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("重新加载") {
                Task { await reload(channel: nil) }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.primaryAction)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.contentInset)
        .padding(.vertical, 48)
    }

    /// 单个频道的货架：没拉过就在出现时拉一次；拉失败给出重试入口。
    @ViewBuilder
    private func channelShelf(_ channel: AnimeChannel) -> some View {
        if failedShelves.contains(channel.id) {
            VStack(alignment: .leading, spacing: 8) {
                ShelfHeader("推荐 · \(channel.name)")
                Button {
                    Task { await loadShelf(channel.id, retry: true) }
                } label: {
                    HStack(spacing: 6) {
                        Image(icon: .refresh).iconStyle(size: 13, color: Theme.accent)
                        Text("加载失败，点按重试")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                }
                .buttonStyle(.pressable(scale: 0.98))
                .padding(.horizontal, Theme.contentInset)
            }
        } else if let items = shelves[channel.id] {
            // 成功但确实没内容就不占版面
            if !items.isEmpty {
                shelf(title: "推荐 · \(channel.name)", items: items, detail: nil, destination: channel.id)
            }
        } else if loadingShelves.contains(channel.id) {
            shelfSkeleton(title: "推荐 · \(channel.name)")
        } else {
            // 占位一行，滚到可见时触发加载；不占高度太多，避免首屏被空货架撑长
            ShelfHeader("推荐 · \(channel.name)")
                .onAppear { Task { await loadShelf(channel.id) } }
        }
    }

    /// 货架：标题走 ShelfHeader（18pt 粗体），右侧「查看更多」走 ShelfLinkLabel（12pt caption 次要灰），
    /// 和首页电影/剧集货架完全同一套规格。
    private func shelf(title: String, items: [AnimeVideoItem], detail: String?, destination: Int?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: title) {
                HStack(spacing: 10) {
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .tertiaryTextStyle()
                    }
                    if let destination {
                        Button {
                            selectChannel(destination)
                        } label: {
                            ShelfLinkLabel(text: "查看更多")
                                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                        }
                        .buttonStyle(.pressable(scale: 0.92))
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in
                        AnimeDetailLink(animeId: item.id) {
                            AnimePosterCard(item: item, width: 108)
                        }
                    }
                }
                .padding(.horizontal, Theme.contentInset)
            }
        }
    }

    private func shelfSkeleton(title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(0..<4, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
                                .fill(Theme.surfaceRaised)
                                .frame(width: 108, height: 162)
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Theme.surfaceRaised)
                                .frame(width: 78, height: 11)
                        }
                    }
                }
                .padding(.horizontal, Theme.contentInset)
            }
        }
    }

    private var recommendSkeleton: some View {
        VStack(spacing: 12) {
            ProgressView().tint(Theme.accent)
            Text("正在加载推荐…")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - 频道页：排序 + 完整分页网格

    private func channelContent(metrics: GridMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 接口只支持 channel / sort / limit / page，没有年份与类型筛选，所以这里只放排序。
            HStack(spacing: 6) {
                sortPill(title: "最新上架", value: "addtime")
                sortPill(title: "推荐权重", value: "weight")
                Spacer(minLength: 8)
                if totalCount > 0 {
                    Text("共 \(totalCount) 部")
                        .font(.system(size: 12))
                        .tertiaryTextStyle()
                }
            }
            .padding(.horizontal, Theme.contentInset)
            .padding(.top, 4)

            if isReloading && gridItems.isEmpty {
                loadingGrid(metrics: metrics)
            } else if gridItems.isEmpty {
                emptyOrErrorState
            } else {
                LazyVGrid(columns: gridColumns(metrics), alignment: .leading, spacing: 16) {
                    ForEach(gridItems) { item in
                        AnimeDetailLink(animeId: item.id) {
                            AnimePosterCard(item: item, width: metrics.cell)
                        }
                        .onAppear {
                            if item.id == gridItems.last?.id {
                                Task { await loadNextPage() }
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.contentInset)
                // 不让 SwiftUI 对整组 id 做插入动画：插入动画会和分页加载叠在一起，行会跳
                .transaction { $0.animation = nil }
                .id("anime-grid-\(selectedChannelId ?? 0)-\(sort)")

                if isLoadingMore {
                    loadMoreIndicator
                }
            }
        }
        .padding(.bottom, 80)
    }

    private func sortPill(title: String, value: String) -> some View {
        let selected = (sort == value)
        return Button {
            guard sort != value else { return }
            Haptics.select()
            sort = value
            beginLoad(channel: selectedChannelId)
        } label: {
            Text(title)
                .font(.system(size: 12, weight: selected ? .bold : .medium))
                .foregroundStyle(selected ? Theme.onPrimary : Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    selected ? Theme.primaryAction : Theme.surfaceRaised,
                    in: Capsule()
                )
        }
        .buttonStyle(.pressable)
    }

    // MARK: - 网格尺寸

    private struct GridMetrics {
        let columns: Int
        let cell: CGFloat
        let spacing: CGFloat
    }

    /// 和原生片库一致：按屏宽算出固定列宽，不用 .flexible()。
    /// flexible 列嵌套在外层 ScrollView 里时，图片异步返回后列宽会被重新协商，
    /// 海报忽宽忽窄、行高参差，就是列表「显示混乱」的主因。
    private func gridMetrics(width: CGFloat) -> GridMetrics {
        let spacing: CGFloat = 12
        let available = max(width - Theme.contentInset * 2, 240)
        let columns = max(2, min(4, Int((available + spacing) / (140 + spacing))))
        let cell = floor((available - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        return GridMetrics(columns: columns, cell: cell, spacing: spacing)
    }

    private func gridColumns(_ metrics: GridMetrics) -> [GridItem] {
        Array(repeating: GridItem(.fixed(metrics.cell), spacing: metrics.spacing, alignment: .top),
              count: metrics.columns)
    }

    private func loadingGrid(metrics: GridMetrics) -> some View {
        LazyVGrid(columns: gridColumns(metrics), alignment: .leading, spacing: 16) {
            ForEach(0..<6, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
                        .fill(Theme.surfaceRaised)
                        .frame(width: metrics.cell, height: metrics.cell * 1.5)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Theme.surfaceRaised)
                        .frame(width: metrics.cell * 0.72, height: 11)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Theme.surfaceRaised)
                        .frame(width: metrics.cell * 0.48, height: 9)
                }
                .frame(width: metrics.cell, alignment: .top)
            }
        }
        .padding(.horizontal, Theme.contentInset)
    }

    @ViewBuilder private var emptyOrErrorState: some View {
        VStack(spacing: 12) {
            Image(icon: errorMessage == nil ? .video : .alert)
                .iconStyle(size: 36, color: Theme.textTertiary)
            Text(errorMessage ?? "暂无番剧内容")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if errorMessage != nil {
                Button("重新加载") {
                    beginLoad(channel: selectedChannelId)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.primaryAction)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.contentInset)
        .padding(.vertical, 40)
    }

    private var loadMoreIndicator: some View {
        HStack {
            Spacer()
            ProgressView()
                .tint(Theme.accent)
            Spacer()
        }
        .padding(.vertical, 16)
    }

    // MARK: - 数据加载流水线

    @MainActor private func selectChannel(_ channelId: Int?) {
        guard channelId != selectedChannelId else { return }
        selectedChannelId = channelId
        beginLoad(channel: channelId)
    }

    @MainActor private func beginLoad(channel: Int?) {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration

        isReloading = true
        isLoadingMore = false
        hasMore = true
        errorMessage = nil
        currentPage = 1
        if channel != nil { gridItems = [] }

        loadTask = Task {
            await performLoad(generation: generation, channel: channel)
        }
    }

    @MainActor private func reload(channel: Int?) async {
        if channel == nil {
            // 下拉刷新推荐页：清掉货架缓存和失败标记重新拉
            shelves = [:]
            failedShelves = []
            channels = []
            trendingItems = []
            banners = []
        }
        beginLoad(channel: channel)
        await loadTask?.value
    }

    @MainActor private func performLoad(generation: Int, channel: Int?) async {
        if channel == nil {
            await loadRecommend(generation: generation)
        } else {
            await loadGrid(generation: generation, channel: channel)
        }
        guard isCurrent(generation) else { return }
        isReloading = false
    }

    /// 推荐页：频道列表、轮播、热门新番独立拉取，任一失败不影响其他板块。
    @MainActor private func loadRecommend(generation: Int) async {
        if channels.isEmpty, let c = try? await AnimeClient.shared.fetchChannels() {
            guard isCurrent(generation) else { return }
            channels = c
        }
        async let bannerTask = try? AnimeClient.shared.fetchBanners()
        async let trendingTask = try? AnimeClient.shared.fetchVideoList(sort: "weight", limit: 12, page: 1)
        let (b, t) = await (bannerTask, trendingTask)
        guard isCurrent(generation) else { return }
        if let b { banners = b }
        if let t { trendingItems = unique(t.items) }

        // 首屏只并发前几个频道货架，其余滚到可见时再拉
        for channel in channels.prefix(eagerShelfCount) {
            Task { await loadShelf(channel.id) }
        }
    }

    @MainActor private func loadShelf(_ channelId: Int, retry: Bool = false) async {
        guard !loadingShelves.contains(channelId) else { return }
        if retry {
            failedShelves.remove(channelId)
            shelves.removeValue(forKey: channelId)
        } else {
            // 已经成功拉过就不再重复拉；失败的走重试按钮，不在滚动时反复打接口
            guard shelves[channelId] == nil, !failedShelves.contains(channelId) else { return }
        }
        loadingShelves.insert(channelId)
        defer { loadingShelves.remove(channelId) }
        if let res = try? await AnimeClient.shared.fetchVideoList(
            channel: channelId, sort: "weight", limit: shelfSize, page: 1
        ) {
            shelves[channelId] = unique(res.items)
            failedShelves.remove(channelId)
        } else {
            failedShelves.insert(channelId)
        }
    }

    @MainActor private func loadGrid(generation: Int, channel: Int?) async {
        do {
            let res = try await AnimeClient.shared.fetchVideoList(
                channel: channel, sort: sort, limit: pageSize, page: 1
            )
            guard isCurrent(generation) else { return }
            let items = unique(res.items)
            gridItems = items
            totalCount = res.total
            currentPage = 1
            hasMore = !items.isEmpty && items.count < totalCount && res.items.count >= pageSize
            errorMessage = nil
        } catch {
            guard isCurrent(generation) else { return }
            errorMessage = error.localizedDescription
            hasMore = false
        }
    }

    @MainActor private func loadNextPage() async {
        guard selectedChannelId != nil, !isReloading, !isLoadingMore, hasMore else { return }
        let generation = loadGeneration
        let nextPage = currentPage + 1
        isLoadingMore = true
        defer {
            if generation == loadGeneration { isLoadingMore = false }
        }

        do {
            let res = try await AnimeClient.shared.fetchVideoList(
                channel: selectedChannelId, sort: sort, limit: pageSize, page: nextPage
            )
            guard generation == loadGeneration, !Task.isCancelled else { return }

            // 按上线时间排序时，翻页过程中新番插入会让下一页重复返回上一页的条目；
            // 过滤掉重复 id，否则同一个 id 在 ForEach 里出现两次，SwiftUI 会错位复用卡片。
            let existing = Set(gridItems.map(\.id))
            let additions = unique(res.items).filter { !existing.contains($0.id) }

            if additions.isEmpty || res.items.isEmpty {
                hasMore = false
                return
            }

            gridItems.append(contentsOf: additions)
            currentPage = nextPage
            if gridItems.count >= totalCount || res.items.count < pageSize {
                hasMore = false
            }
        } catch {
            guard generation == loadGeneration else { return }
            hasMore = false
        }
    }

    @MainActor private func isCurrent(_ generation: Int) -> Bool {
        generation == loadGeneration && !Task.isCancelled
    }

    private func unique(_ items: [AnimeVideoItem]) -> [AnimeVideoItem] {
        var seen = Set<Int>()
        return items.filter { seen.insert($0.id).inserted }
    }
}
