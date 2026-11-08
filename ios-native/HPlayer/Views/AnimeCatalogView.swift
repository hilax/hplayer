import SwiftUI

struct AnimeCatalogView: View {
    var onSearch: () -> Void

    // MARK: 内容

    @State private var channels: [AnimeChannel] = []
    @State private var banners: [AnimeBanner] = []
    @State private var trendingItems: [AnimeVideoItem] = []
    @State private var waterfallItems: [AnimeVideoItem] = []

    // MARK: 筛选与分页

    @State private var selectedChannelId: Int? = nil
    @State private var currentPage = 1
    @State private var totalCount = 0
    @State private var hasMore = true
    private let pageSize = 18

    // MARK: 加载状态

    @State private var isReloading = false
    @State private var isLoadingMore = false
    @State private var initialLoaded = false
    @State private var errorMessage: String? = nil
    /// 每次重新拉取都 +1，迟到的旧请求（例如切换频道前发出的下一页）直接丢弃，
    /// 否则旧频道的数据会追加到新频道列表里，看起来就是「内容串了」。
    @State private var loadGeneration = 0
    @State private var loadTask: Task<Void, Never>?

    @State private var selectedAnimeId: Int? = nil

    var body: some View {
        GeometryReader { proxy in
            let metrics = gridMetrics(width: proxy.size.width)

            VStack(spacing: 0) {
                AnimeChannelBar(
                    channels: channels,
                    selectedChannelId: $selectedChannelId,
                    onSelect: { channelId in
                        selectedChannelId = channelId
                        beginLoad(channel: channelId, refreshAll: false)
                    }
                )

                // 频道切换时重建滚动容器：回到顶部，不把旧频道滚到底的偏移带到新列表
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if selectedChannelId == nil && !banners.isEmpty {
                            AnimeHeroBanner(banners: banners) { banner in
                                if let vid = banner.vid {
                                    selectedAnimeId = vid
                                }
                            }
                            .padding(.top, 4)
                        }

                        if selectedChannelId == nil && !trendingItems.isEmpty {
                            trendingSection
                        }

                        waterfallSection(metrics: metrics)
                    }
                    .padding(.bottom, 80)
                }
                .id("anime-scroll-\(selectedChannelId ?? 0)")
                .scrollIndicators(.hidden)
                .refreshable {
                    await reload(channel: selectedChannelId, refreshAll: true)
                }
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .task {
            guard !initialLoaded else { return }
            initialLoaded = true
            beginLoad(channel: nil, refreshAll: true)
        }
        .navigationDestination(isPresented: Binding(
            get: { selectedAnimeId != nil },
            set: { if !$0 { selectedAnimeId = nil } }
        )) {
            if let id = selectedAnimeId {
                AnimeDetailView(animeId: id)
            }
        }
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

    // MARK: - 热门新番横滑货架

    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("🔥 热门新番")
                    .font(.display(16))
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                Text("共 \(trendingItems.count) 部推荐")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, Theme.contentInset)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(trendingItems) { item in
                        AnimePosterCard(item: item, width: 108)
                            .onTapGesture {
                                Haptics.tap()
                                selectedAnimeId = item.id
                            }
                    }
                }
                .padding(.horizontal, Theme.contentInset)
            }
        }
    }

    // MARK: - 分类更新海报网格

    private func waterfallSection(metrics: GridMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                let title = channels.first(where: { $0.id == selectedChannelId })?.name ?? "全部番剧"
                Text(title)
                    .font(.display(16))
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                if totalCount > 0 {
                    Text("共 \(totalCount) 部")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, Theme.contentInset)

            if isReloading && waterfallItems.isEmpty {
                loadingGrid(metrics: metrics)
            } else if waterfallItems.isEmpty {
                emptyOrErrorState
            } else {
                LazyVGrid(columns: gridColumns(metrics), alignment: .leading, spacing: 16) {
                    ForEach(waterfallItems) { item in
                        AnimePosterCard(item: item, width: metrics.cell)
                            .onTapGesture {
                                Haptics.tap()
                                selectedAnimeId = item.id
                            }
                            .onAppear {
                                if item.id == waterfallItems.last?.id {
                                    Task { await loadNextPage() }
                                }
                            }
                    }
                }
                .padding(.horizontal, Theme.contentInset)
                // 不让 SwiftUI 对整组 id 做插入动画：插入动画会和分页加载叠在一起，行会跳
                .transaction { $0.animation = nil }
                .id("anime-grid-\(selectedChannelId ?? 0)")

                if isLoadingMore {
                    loadMoreIndicator
                }
            }
        }
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
                    beginLoad(channel: selectedChannelId, refreshAll: false)
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

    @MainActor private func beginLoad(channel: Int?, refreshAll: Bool) {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration

        isReloading = true
        isLoadingMore = false
        hasMore = true
        errorMessage = nil
        currentPage = 1
        waterfallItems = []

        loadTask = Task {
            await performLoad(generation: generation, channel: channel, refreshAll: refreshAll)
        }
    }

    @MainActor private func reload(channel: Int?, refreshAll: Bool) async {
        beginLoad(channel: channel, refreshAll: refreshAll)
        await loadTask?.value
    }

    @MainActor private func performLoad(generation: Int, channel: Int?, refreshAll: Bool) async {
        if refreshAll {
            if let c = try? await AnimeClient.shared.fetchChannels() {
                guard isCurrent(generation) else { return }
                channels = c
            }
            if let b = try? await AnimeClient.shared.fetchBanners() {
                guard isCurrent(generation) else { return }
                banners = b
            }
            if let t = try? await AnimeClient.shared.fetchVideoList(sort: "weight", limit: 12, page: 1) {
                guard isCurrent(generation) else { return }
                trendingItems = unique(t.items)
            }
        }

        do {
            let res = try await AnimeClient.shared.fetchVideoList(
                channel: channel, sort: "addtime", limit: pageSize, page: 1
            )
            guard isCurrent(generation) else { return }
            let items = unique(res.items)
            waterfallItems = items
            totalCount = res.total
            currentPage = 1
            hasMore = !items.isEmpty && items.count < totalCount && res.items.count >= pageSize
            errorMessage = nil
        } catch {
            guard isCurrent(generation) else { return }
            // 兜底重试：若全库 addtime 异常，改拉日漫频道的推荐列表
            if let fallback = try? await AnimeClient.shared.fetchVideoList(
                channel: channel ?? 20, sort: "weight", limit: pageSize, page: 1
            ) {
                guard isCurrent(generation) else { return }
                let items = unique(fallback.items)
                waterfallItems = items
                totalCount = fallback.total
                currentPage = 1
                hasMore = !items.isEmpty && items.count < totalCount && fallback.items.count >= pageSize
                errorMessage = nil
            } else {
                errorMessage = error.localizedDescription
                hasMore = false
            }
        }

        guard isCurrent(generation) else { return }
        isReloading = false
    }

    @MainActor private func loadNextPage() async {
        guard !isReloading, !isLoadingMore, hasMore else { return }
        let generation = loadGeneration
        let nextPage = currentPage + 1
        isLoadingMore = true
        defer {
            if generation == loadGeneration { isLoadingMore = false }
        }

        do {
            let res = try await AnimeClient.shared.fetchVideoList(
                channel: selectedChannelId, sort: "addtime", limit: pageSize, page: nextPage
            )
            guard generation == loadGeneration, !Task.isCancelled else { return }

            // 按上线时间排序时，翻页过程中新番插入会让下一页重复返回上一页的条目；
            // 过滤掉重复 id，否则同一个 id 在 ForEach 里出现两次，SwiftUI 会错位复用卡片。
            let existing = Set(waterfallItems.map(\.id))
            let additions = unique(res.items).filter { !existing.contains($0.id) }

            if additions.isEmpty || res.items.isEmpty {
                hasMore = false
                return
            }

            waterfallItems.append(contentsOf: additions)
            currentPage = nextPage
            if waterfallItems.count >= totalCount || res.items.count < pageSize {
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
