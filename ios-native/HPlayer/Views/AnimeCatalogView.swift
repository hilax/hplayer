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

    @Namespace private var channelSpace
    @Namespace private var sortSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let metrics = gridMetrics(width: proxy.size.width)

            VStack(spacing: 0) {
                // 二级筛选和片库、短剧一样用 SelectionPill，不再单独做一套下划线标签
                channelPills

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

    // MARK: - 频道胶囊

    private var channelPills: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                channelPill("推荐", id: nil)
                ForEach(channels) { channel in
                    channelPill(channel.name, id: channel.id)
                }
            }
            .padding(.horizontal, Theme.contentInset - 4)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 6)
    }

    private func channelPill(_ title: String, id: Int?) -> some View {
        SelectionPill(title: title, selected: selectedChannelId == id, namespace: channelSpace) {
            withAnimation(reduceMotion ? nil : Motion.snappy) { selectChannel(id) }
        }
        .accessibilityIdentifier("anime.channel.\(id.map(String.init) ?? "recommend")")
    }

    // MARK: - 推荐页：轮播 + 热门新番 + 各频道货架（版式与首页推荐的货架一致）

    private var recommendContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !banners.isEmpty {
                AnimeHeroBanner(banners: banners)
            }

            if !trendingItems.isEmpty {
                shelf(title: "热门新番", identifier: "anime.shelf.trending", items: trendingItems,
                      detail: "\(trendingItems.count) 部", destination: nil)
            }

            ForEach(channels) { channel in
                channelShelf(channel)
            }

            if isReloading && banners.isEmpty && trendingItems.isEmpty && shelves.isEmpty {
                recommendSkeleton
            } else if !isReloading && banners.isEmpty && trendingItems.isEmpty && channels.isEmpty {
                // 全部板块都没拉到时必须给出说明和重试入口，否则整页一片空白。
                EmptyStateView(icon: AppIcon.alert.name, title: "推荐内容没加载出来",
                               message: "接口没有连上。下拉可以刷新，或点下面的按钮重试。",
                               actionTitle: "重新加载") {
                    Task { await reload(channel: nil) }
                }
                .frame(maxWidth: .infinity, minHeight: 320)
            }
        }
        .padding(.horizontal, Theme.contentInset)
        .padding(.top, 4)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 单个频道的货架：没拉过就在出现时拉一次；拉失败给出重试入口。
    @ViewBuilder
    private func channelShelf(_ channel: AnimeChannel) -> some View {
        let identifier = "anime.shelf.\(channel.id)"
        if failedShelves.contains(channel.id) {
            VStack(alignment: .leading, spacing: 8) {
                ShelfHeader(title: channel.name, identifier: identifier, inset: 0) { EmptyView() }
                Button {
                    Task { await loadShelf(channel.id, retry: true) }
                } label: {
                    HStack(spacing: 8) {
                        Image(icon: .refresh).iconStyle(size: 13, color: Theme.accent)
                        Text("没有加载出来，点按重试")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                }
                .buttonStyle(.pressable(scale: 0.98))
            }
        } else if let items = shelves[channel.id] {
            // 成功但确实没内容就不占版面
            if !items.isEmpty {
                shelf(title: channel.name, identifier: identifier, items: items, detail: nil, destination: channel.id)
            }
        } else if loadingShelves.contains(channel.id) {
            shelfSkeleton(title: channel.name)
        } else {
            // 占位一行，滚到可见时触发加载；不占太多高度，避免首屏被空货架撑长
            ShelfHeader(title: channel.name, identifier: identifier, inset: 0) { EmptyView() }
                .onAppear { Task { await loadShelf(channel.id) } }
        }
    }

    /// 货架：和首页「在线 · 热门新番」同一套规格——18pt 标题、右侧「全部 ›」、108pt 海报横滑。
    private func shelf(title: String, identifier: String, items: [AnimeVideoItem],
                       detail: String?, destination: Int?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ShelfHeader(title: title, identifier: identifier, inset: 0) {
                HStack(spacing: 10) {
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .tertiaryTextStyle()
                    }
                    if let destination {
                        Button {
                            withAnimation(reduceMotion ? nil : Motion.snappy) { selectChannel(destination) }
                        } label: {
                            ShelfLinkLabel(text: "全部")
                                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                        }
                        .buttonStyle(.pressable(scale: 0.92))
                    }
                }
                .frame(minHeight: 44)
            }

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        AnimeDetailLink(animeId: item.id) {
                            AnimePosterCard(item: item, width: 108)
                        }
                        .reveal(index, id: "\(identifier).\(item.id)")
                    }
                }
                .padding(.horizontal, Theme.contentInset)
                .padding(.vertical, 4)
            }
            .padding(.horizontal, -Theme.contentInset)
            .scrollIndicators(.hidden)
        }
    }

    private func shelfSkeleton(title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ShelfHeader(title: title, inset: 0) { EmptyView() }
                .frame(minHeight: 44, alignment: .leading)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(0..<4, id: \.self) { _ in
                        posterSkeleton(width: 108)
                    }
                }
                .padding(.horizontal, Theme.contentInset)
                .padding(.vertical, 4)
            }
            .padding(.horizontal, -Theme.contentInset)
            .scrollIndicators(.hidden)
            .allowsHitTesting(false)
        }
    }

    /// 首次进入：用轮播和两排货架的骨架占位，和最终版式一致，加载完不会整页跳动。
    private var recommendSkeleton: some View {
        VStack(alignment: .leading, spacing: 28) {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.surfaceRaised)
                .frame(height: AnimeHeroBanner.height)
            shelfSkeleton(title: "热门新番")
            shelfSkeleton(title: " ")
        }
        .accessibilityLabel("正在加载推荐")
    }

    private func posterSkeleton(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
                .fill(Theme.surfaceRaised)
                .frame(width: width, height: width * 1.5)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.surfaceRaised)
                .frame(width: width * 0.72, height: 12)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.surfaceRaised)
                .frame(width: width * 0.48, height: 10)
        }
        .frame(width: width, alignment: .topLeading)
    }

    // MARK: - 频道页：排序 + 完整分页网格（网格规格与片库一致）

    private func channelContent(metrics: GridMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 接口只支持 channel / sort / limit / page，没有年份与类型筛选，所以这里只放排序。
            // sort 实测（2026-11-12）：addtime 与 weight 在多数频道返回的顺序完全一样，
            // 所以第二个选项用 hits（按播放量），这才是一组明显不同的结果；其他值服务端不认，退回按 id 排。
            HStack(spacing: 2) {
                sortPill(title: "最新上架", value: "addtime")
                sortPill(title: "最多播放", value: "hits")
                Spacer(minLength: 8)
                if totalCount > 0 {
                    Text("共 \(totalCount) 部")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.trailing, 4)
                }
            }
            .padding(.horizontal, Theme.contentInset - 4)

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

                listFooter
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 40)
    }

    private func sortPill(title: String, value: String) -> some View {
        SelectionPill(title: title, selected: sort == value, namespace: sortSpace) {
            guard sort != value else { return }
            withAnimation(reduceMotion ? nil : Motion.snappy) { sort = value }
            beginLoad(channel: selectedChannelId)
        }
        .accessibilityIdentifier("anime.sort.\(value)")
    }

    // MARK: - 网格尺寸

    private struct GridMetrics {
        let columns: Int
        let cell: CGFloat
        let spacing: CGFloat
    }

    /// 和片库同一套算法：至少三列、按屏宽算出固定列宽，不用 .flexible()。
    /// flexible 列嵌套在外层 ScrollView 里时，图片异步返回后列宽会被重新协商，海报忽宽忽窄。
    private func gridMetrics(width: CGFloat) -> GridMetrics {
        let spacing: CGFloat = 10
        let available = max(width - Theme.contentInset * 2, 200)
        let columns = max(3, Int((available + spacing) / (118 + spacing)))
        let cell = floor((available - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        return GridMetrics(columns: columns, cell: cell, spacing: spacing)
    }

    private func gridColumns(_ metrics: GridMetrics) -> [GridItem] {
        Array(repeating: GridItem(.fixed(metrics.cell), spacing: metrics.spacing, alignment: .top),
              count: metrics.columns)
    }

    private func loadingGrid(metrics: GridMetrics) -> some View {
        LazyVGrid(columns: gridColumns(metrics), alignment: .leading, spacing: 16) {
            ForEach(0..<9, id: \.self) { _ in
                posterSkeleton(width: metrics.cell)
            }
        }
        .padding(.horizontal, Theme.contentInset)
        .accessibilityLabel("正在加载")
    }

    @ViewBuilder private var emptyOrErrorState: some View {
        Group {
            if let errorMessage {
                EmptyStateView(icon: AppIcon.alert.name, title: "这个频道没有加载出来", message: errorMessage,
                               actionTitle: "重新加载") {
                    beginLoad(channel: selectedChannelId)
                }
            } else {
                EmptyStateView(icon: AppIcon.video.name, title: "暂时没有番剧",
                               message: "这个频道下还没有内容，换个频道看看。")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    @ViewBuilder private var listFooter: some View {
        Group {
            if isLoadingMore {
                ProgressView().tint(Theme.textSecondary)
            } else if !hasMore {
                Text("已经到底了")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56)
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
