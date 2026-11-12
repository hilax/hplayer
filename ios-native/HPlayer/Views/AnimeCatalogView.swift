import SwiftUI
import Combine

// MARK: - 动漫频道的数据

/// 动漫频道推荐页的数据：频道列表和每个频道的货架。放在 App 级别的单例里，
/// 切频道（推荐 ⇄ 动漫）时页面会重建，但数据还在，回来直接显示，不再重新转圈。
/// 轮播（热播横图）和热门新番和首页共用 HomeOnlineFeed。
@MainActor
final class AnimeHomeStore: ObservableObject {
    static let shared = AnimeHomeStore()

    @Published private(set) var channels: [AnimeChannel] = []
    /// 每个频道的货架，按频道 id 存；滚到可见时才拉，首屏只并发前几个
    @Published private(set) var shelves: [Int: [AnimeVideoItem]] = [:]
    @Published private(set) var loadingShelves: Set<Int> = []
    /// 拉失败的货架单独记，不能塞进 shelves 当空数组——那样会被当成「已加载」，网络恢复后也不再重试
    @Published private(set) var failedShelves: Set<Int> = []
    @Published private(set) var loadingChannels = false
    @Published private(set) var channelsFailed = false
    private var loadedAt: Date?

    private let shelfSize = 6
    private let eagerShelfCount = 3

    private init() {}

    /// 进动漫频道时调用；十分钟内不重复拉。
    func loadIfNeeded() async {
        guard !InterfacePreview.active, !loadingChannels else { return }
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 600, !channels.isEmpty { return }
        await loadChannels()
    }

    /// 下拉刷新：频道和货架全部重拉（轮播、热门新番由 HomeOnlineFeed 刷新）
    func reload() async {
        shelves = [:]
        failedShelves = []
        loadedAt = nil
        await loadChannels()
    }

    private func loadChannels() async {
        loadingChannels = true
        defer { loadingChannels = false }
        if let result = try? await AnimeClient.shared.fetchChannels() {
            channels = result
            channelsFailed = false
            loadedAt = Date()
            for channel in result.prefix(eagerShelfCount) {
                Task { await loadShelf(channel.id) }
            }
        } else if channels.isEmpty {
            channelsFailed = true
        }
    }

    func loadShelf(_ channelId: Int, retry: Bool = false) async {
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
        if let result = try? await AnimeClient.shared.fetchVideoList(channel: channelId, sort: "weight", limit: shelfSize, page: 1) {
            var seen = Set<Int>()
            shelves[channelId] = result.items.filter { seen.insert($0.id).inserted }
            failedShelves.remove(channelId)
        } else {
            failedShelves.insert(channelId)
        }
    }
}

// MARK: - 动漫频道

/// 打开一个动漫列表页：某个频道、或全部（channelId 为 nil），带初始排序。
struct AnimeBrowseRoute: Hashable {
    var channelId: Int?
    var title: String
    var sort = "addtime"
}

/// 动漫频道：顶部是热播轮播（频道条、搜索框在频道容器的固定头部里；轮播位置一直留着，数据到了再填），
/// 下面一排快捷入口（最新上架 / 最多播放 / 我的追番 / 剧场版），再下面是热门新番（三列竖海报）和各频道货架。
/// 「全部」「更多」、快捷入口、「筛选」都推进新的列表页（AnimeBrowseView），不在本页切换内容。
struct AnimeCatalogView: View {
    /// 内容从哪里开始（频道容器的固定头部盖在上面）
    @Environment(\.channelPageInsets) private var insets

    @ObservedObject private var store = AnimeHomeStore.shared
    @ObservedObject private var online = HomeOnlineFeed.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    AmbientHeroSection(slides: HomeSlide.anime(online.banners), reservesCarousel: true,
                                       carouselLabel: "热播轮播", carouselIdentifier: "anime.bannerPosition",
                                       safeTop: insets.top, width: proxy.size.width) {
                        EmptyView()
                    } hitArea: { slide in
                        bannerHitArea(slide)
                    }

                    shortcuts
                        .padding(.top, 16)

                    recommendContent(width: proxy.size.width)
                }
                .tracksPageScroll()
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .refreshable {
                async let feed: Void = online.refresh()
                async let channels: Void = store.reload()
                _ = await (feed, channels)
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .task { await online.loadIfNeeded() }
        .task { await store.loadIfNeeded() }
    }

    // MARK: 轮播与快捷入口

    /// 点轮播进动漫详情
    @ViewBuilder
    private func bannerHitArea(_ slide: HomeSlide) -> some View {
        if case .anime(let banner) = slide.content {
            NavigationLink(value: AnimeDetailRoute(animeId: banner.vid ?? banner.id)) {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(banner.displayTitle)
            .accessibilityIdentifier("anime.banner.\(banner.id)")
        }
    }

    /// 剧场版 / 动漫电影频道（接口里有就放一个快捷入口）
    private var movieChannel: AnimeChannel? {
        store.channels.first { $0.name.contains("剧场") || $0.name.contains("电影") }
    }

    private var shortcuts: some View {
        HStack(spacing: 4) {
            NavigationLink(value: AnimeBrowseRoute(channelId: nil, title: "最新上架", sort: "addtime")) {
                ChannelShortcutLabel(title: "最新上架", icon: .sparkles, tint: ShortcutTint.blue)
            }
            .buttonStyle(.pressable(scale: 0.92))
            .accessibilityIdentifier("anime.shortcut.latest")

            NavigationLink(value: AnimeBrowseRoute(channelId: nil, title: "最多播放", sort: "hits")) {
                ChannelShortcutLabel(title: "最多播放", icon: .hot, tint: ShortcutTint.orange)
            }
            .buttonStyle(.pressable(scale: 0.92))
            .accessibilityIdentifier("anime.shortcut.hot")

            NavigationLink {
                AnimeWatchlistView()
            } label: {
                ChannelShortcutLabel(title: "我的追番", icon: .heart, tint: ShortcutTint.purple)
            }
            .buttonStyle(.pressable(scale: 0.92))
            .accessibilityIdentifier("anime.shortcut.watchlist")

            if let movieChannel {
                NavigationLink(value: AnimeBrowseRoute(channelId: movieChannel.id, title: movieChannel.name)) {
                    ChannelShortcutLabel(title: movieChannel.name, icon: .video, tint: ShortcutTint.green)
                }
                .buttonStyle(.pressable(scale: 0.92))
                .accessibilityIdentifier("anime.shortcut.movie")
            }
        }
        .padding(.horizontal, 10)
    }

    // MARK: 热门新番 + 各频道货架

    private func recommendContent(width: CGFloat) -> some View {
        let spacing: CGFloat = 10
        let cardWidth = ((width - Theme.contentInset * 2 - spacing * 2) / 3).rounded(.down)
        let trending = Array(online.trending.prefix(6))
        return VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                ShelfHeader(title: "热门新番", identifier: "anime.shelf.trending", inset: 0) {
                    NavigationLink(value: AnimeBrowseRoute(channelId: nil, title: "热门新番", sort: "hits")) {
                        ShelfLinkLabel(text: "更多")
                            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    }
                    .buttonStyle(.pressable(scale: 0.92))
                }
                if trending.isEmpty {
                    gridSkeleton(cardWidth: cardWidth)
                } else {
                    FixedGrid(items: trending, columns: 3, spacing: spacing) { index, item in
                        HomeAnimeGridCard(item: item, rank: index + 1, width: cardWidth)
                            .reveal(index)
                    }
                }
            }

            if store.channels.isEmpty && store.loadingChannels {
                shelfSkeleton(title: " ")
            } else if store.channels.isEmpty && store.channelsFailed {
                // 频道没拉到时必须给出说明和重试入口
                EmptyStateView(icon: AppIcon.alert.name, title: "分类没加载出来",
                               message: "接口没有连上。下拉可以刷新，或点下面的按钮重试。",
                               actionTitle: "重新加载") {
                    Task { await store.reload() }
                }
                .frame(maxWidth: .infinity, minHeight: 240)
            }

            ForEach(store.channels) { channel in
                channelShelf(channel)
            }
        }
        .padding(.horizontal, Theme.contentInset)
        .padding(.top, 20)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 单个频道的货架：没拉过就在出现时拉一次；拉失败给出重试入口。「全部」推进这个频道的列表页。
    @ViewBuilder
    private func channelShelf(_ channel: AnimeChannel) -> some View {
        let identifier = "anime.shelf.\(channel.id)"
        if store.failedShelves.contains(channel.id) {
            VStack(alignment: .leading, spacing: 8) {
                shelfHeader(channel, identifier: identifier)
                Button {
                    Task { await store.loadShelf(channel.id, retry: true) }
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
        } else if let items = store.shelves[channel.id] {
            // 成功但确实没内容就不占版面
            if !items.isEmpty {
                shelf(channel, identifier: identifier, items: items)
            }
        } else if store.loadingShelves.contains(channel.id) {
            shelfSkeleton(title: channel.name)
        } else {
            // 占位一行，滚到可见时触发加载
            shelfSkeleton(title: channel.name)
                .onAppear { Task { await store.loadShelf(channel.id) } }
        }
    }

    private func shelfHeader(_ channel: AnimeChannel, identifier: String) -> some View {
        ShelfHeader(title: channel.name, identifier: identifier, inset: 0) {
            NavigationLink(value: AnimeBrowseRoute(channelId: channel.id, title: channel.name)) {
                ShelfLinkLabel(text: "全部")
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
            }
            .buttonStyle(.pressable(scale: 0.92))
            .accessibilityIdentifier("\(identifier).all")
        }
    }

    /// 货架：18pt 标题、右侧「全部 ›」、108pt 海报横滑。
    private func shelf(_ channel: AnimeChannel, identifier: String, items: [AnimeVideoItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            shelfHeader(channel, identifier: identifier)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        AnimeDetailLink(animeId: item.id) {
                            AnimePosterCard(item: item, width: 108)
                        }
                        .reveal(index, id: "\(identifier).\(item.id)")
                        .shelfCard()
                        .prefetchArtwork(after: index, in: items, count: 4) { $0.safePicURLString }
                    }
                }
                .shelfContent()
                .padding(.vertical, 4)
            }
            .shelfScrolling()
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
                        AnimePosterSkeleton(width: 108)
                    }
                }
                .shelfContent()
                .padding(.vertical, 4)
            }
            .shelfScrolling()
            .padding(.horizontal, -Theme.contentInset)
            .scrollIndicators(.hidden)
            .allowsHitTesting(false)
        }
        .accessibilityLabel("正在加载")
    }

    private func gridSkeleton(cardWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(0..<3, id: \.self) { _ in
                AnimePosterSkeleton(width: cardWidth)
            }
        }
        .accessibilityLabel("正在加载")
    }
}

/// 海报骨架：和 AnimePosterCard 同尺寸的灰块，加载完不跳。
struct AnimePosterSkeleton: View {
    let width: CGFloat

    var body: some View {
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
}

// MARK: - 动漫列表页

/// 一个频道（或全部）的完整列表：顶部排序胶囊（最新上架 / 最多播放）+ 至少三列的海报网格，滑到底自动翻页。
/// 从动漫频道货架的「全部」、快捷入口，首页热门新番的「更多」推进来。
struct AnimeBrowseView: View {
    let route: AnimeBrowseRoute

    @State private var sort: String
    @State private var items: [AnimeVideoItem] = []
    @State private var currentPage = 1
    @State private var totalCount = 0
    @State private var hasMore = true
    @State private var isReloading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    /// 每次重新拉取都 +1，迟到的旧请求（换排序前发出的下一页）直接丢弃，免得内容串了
    @State private var generation = 0
    @Namespace private var sortSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pageSize = 18

    init(route: AnimeBrowseRoute) {
        self.route = route
        _sort = State(initialValue: route.sort)
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = Self.metrics(width: proxy.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // 接口只支持 channel / sort / limit / page。sort 实测 addtime 与 weight 顺序一样，
                    // 所以第二个选项用 hits（按播放量）；其他值服务端不认，退回按 id 排。
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

                    if isReloading && items.isEmpty {
                        LazyVGrid(columns: columns(metrics), alignment: .leading, spacing: 16) {
                            ForEach(0..<9, id: \.self) { _ in AnimePosterSkeleton(width: metrics.cell) }
                        }
                        .padding(.horizontal, Theme.contentInset)
                        .accessibilityLabel("正在加载")
                    } else if items.isEmpty {
                        emptyOrError
                    } else {
                        LazyVGrid(columns: columns(metrics), alignment: .leading, spacing: 16) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                AnimeDetailLink(animeId: item.id) {
                                    AnimePosterCard(item: item, width: metrics.cell)
                                }
                                .prefetchArtwork(after: index, in: items, count: metrics.columns * 3) { $0.safePicURLString }
                                .gridCardEntrance()
                                .onAppear {
                                    if item.id == items.last?.id { Task { await loadNextPage() } }
                                }
                            }
                        }
                        .padding(.horizontal, Theme.contentInset)
                        // 不对整组 id 做插入动画：会和分页加载叠在一起，行会跳
                        .transaction { $0.animation = nil }
                        .id("anime-browse-\(sort)")

                        footer
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .refreshable { await reload() }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .task { if items.isEmpty { await reload() } }
    }

    private func sortPill(title: String, value: String) -> some View {
        SelectionPill(title: title, selected: sort == value, namespace: sortSpace) {
            guard sort != value else { return }
            withAnimation(reduceMotion ? nil : Motion.snappy) { sort = value }
            Task { await reload() }
        }
        .accessibilityIdentifier("anime.sort.\(value)")
    }

    @ViewBuilder private var emptyOrError: some View {
        Group {
            if let errorMessage {
                EmptyStateView(icon: AppIcon.alert.name, title: "没有加载出来", message: errorMessage,
                               actionTitle: "重新加载") {
                    Task { await reload() }
                }
            } else {
                EmptyStateView(icon: AppIcon.video.name, title: "暂时没有番剧",
                               message: "这里还没有内容，换个分类看看。")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    @ViewBuilder private var footer: some View {
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

    // MARK: 网格尺寸

    private struct Metrics {
        let columns: Int
        let cell: CGFloat
        let spacing: CGFloat
    }

    /// 和片库同一套算法：至少三列、按屏宽算出固定列宽（flexible 列在外层 ScrollView 里会被图片撑得忽宽忽窄）
    private static func metrics(width: CGFloat) -> Metrics {
        let spacing: CGFloat = 10
        let available = max(width - Theme.contentInset * 2, 200)
        let columns = max(3, Int((available + spacing) / (118 + spacing)))
        let cell = floor((available - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        return Metrics(columns: columns, cell: cell, spacing: spacing)
    }

    private func columns(_ metrics: Metrics) -> [GridItem] {
        Array(repeating: GridItem(.fixed(metrics.cell), spacing: metrics.spacing, alignment: .top), count: metrics.columns)
    }

    // MARK: 加载

    @MainActor private func reload() async {
        generation += 1
        let current = generation
        isReloading = true
        isLoadingMore = false
        hasMore = true
        errorMessage = nil
        items = []
        defer { if current == generation { isReloading = false } }
        do {
            let result = try await AnimeClient.shared.fetchVideoList(channel: route.channelId, sort: sort, limit: pageSize, page: 1)
            guard current == generation else { return }
            items = Self.unique(result.items)
            totalCount = result.total
            currentPage = 1
            hasMore = !items.isEmpty && items.count < totalCount && result.items.count >= pageSize
        } catch {
            guard current == generation else { return }
            errorMessage = error.localizedDescription
            hasMore = false
        }
    }

    @MainActor private func loadNextPage() async {
        guard !isReloading, !isLoadingMore, hasMore else { return }
        let current = generation
        let nextPage = currentPage + 1
        isLoadingMore = true
        defer { if current == generation { isLoadingMore = false } }
        do {
            let result = try await AnimeClient.shared.fetchVideoList(channel: route.channelId, sort: sort, limit: pageSize, page: nextPage)
            guard current == generation else { return }
            // 按上线时间排序时，翻页过程中新番插入会让下一页重复返回上一页的条目；过滤掉重复 id
            let existing = Set(items.map(\.id))
            let additions = Self.unique(result.items).filter { !existing.contains($0.id) }
            if additions.isEmpty || result.items.isEmpty {
                hasMore = false
                return
            }
            items.append(contentsOf: additions)
            currentPage = nextPage
            if items.count >= totalCount || result.items.count < pageSize { hasMore = false }
        } catch {
            guard current == generation else { return }
            hasMore = false
        }
    }

    private static func unique(_ items: [AnimeVideoItem]) -> [AnimeVideoItem] {
        var seen = Set<Int>()
        return items.filter { seen.insert($0.id).inserted }
    }
}
