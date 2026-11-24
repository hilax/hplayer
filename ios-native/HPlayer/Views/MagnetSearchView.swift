import SwiftUI
import UIKit

// MARK: - 分页辅助

/// 分页加载的状态。
struct PagingState {
    var page = 1
    var hasMore = true
    var isLoadingMore = false
    var loadMoreFailed = false
}

/// 列表底部的「加载中 / 加载失败」提示。
struct PagingFooter: View {
    let isLoading: Bool
    let failed: Bool
    let retry: () -> Void

    var body: some View {
        if isLoading {
            ProgressView()
                .tint(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        } else if failed {
            Button("加载失败，点击重试", action: retry)
                .font(.footnote)
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
    }
}

/// 把新一页并入已有列表，按 id 去重；`added` 为 0 说明没有更多内容了。
func mergeUnique<T: Identifiable>(_ existing: [T], with new: [T]) -> (merged: [T], added: Int) where T.ID: Hashable {
    var seen = Set(existing.map(\.id))
    var merged = existing
    var added = 0
    for item in new where seen.insert(item.id).inserted {
        merged.append(item)
        added += 1
    }
    return (merged, added)
}

// MARK: - 磁力聚合主页

/// 磁力聚合页面：按番号/女优搜索，按「最新 / 专题 / 女优」分类浏览。
/// 三个分类左右滑动切换（PagedHeaderContainer）：分类条和搜索框是固定头部，往上滑时分类条淡出、搜索框固定在顶端。
/// 每个分类的数据各存各的，滑过去不用重新加载。搜索或粘贴了链接时，结果盖在分页上面。
/// 影片、女优、片商都是普通的逐层跳转（左上角返回上一层）；在磁力详情页点播放，
/// 播放页盖在详情页上面，关掉就回到详情页。版式见 docs/ui-design-system.md「磁力聚合」。
struct MagnetSearchView: View {
    /// 作为「磁力」Tab 的根页面：隐藏系统导航栏，右上角提供「播放记录」。
    var isTabRoot = false

    init(isTabRoot: Bool = false) {
        self.isTabRoot = isTabRoot
    }

    @EnvironmentObject private var appState: AppState
    @State private var playLaunch: MagnetPlaybackRequest?
    @ObservedObject private var favoriteStars = FavoriteStarStore.shared

    @State private var keyword = ""
    @State private var selectedCategory: MagnetCategory = .latest

    // 分类浏览数据：每个分类各存一份
    @State private var movies: [MagnetCategory: [MagnetSearchItem]] = [:]
    @State private var freshMovies: [MagnetSearchItem] = []
    @State private var freshLoading = false
    @State private var freshTask: Task<Void, Never>?
    @State private var stars: [MagnetStarItem] = []
    @State private var paging: [MagnetCategory: PagingState] = [:]
    @State private var loading: Set<MagnetCategory> = []
    @State private var errors: [MagnetCategory: String] = [:]
    @State private var tasks: [MagnetCategory: Task<Void, Never>] = [:]

    // 搜索数据：只有提交（键盘上的「搜索」键）才进入搜索结果视图，输入过程中不切换。
    @State private var searchActive = false
    @State private var activeQuery = ""
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var searchMovies: [MagnetSearchItem] = []
    @State private var matchedStars: [MagnetStarItem] = []
    @State private var searchPaging = PagingState()
    @State private var searchTask: Task<Void, Never>?

    private var trimmedKeyword: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 输入框里是磁力链接 / 信息哈希 / 迅雷链接时，不去站点搜索，直接给出解析面板。
    private var detectedLink: MagnetLink? {
        MagnetLink.parse(trimmedKeyword)
    }

    private var inSearchMode: Bool {
        searchActive && !trimmedKeyword.isEmpty && detectedLink == nil
    }

    /// 点分类：正在看搜索结果时先退出搜索
    private var categorySelection: Binding<MagnetCategory> {
        Binding(get: { selectedCategory }, set: { value in
            if searchActive { clearSearch() }
            selectedCategory = value
        })
    }

    var body: some View {
        PagedHeaderContainer(pages: MagnetCategory.allCases, selection: categorySelection, overlay: searchOverlay) {
            topRow
        } secondRow: {
            MagnetSearchField(text: $keyword, onSubmit: triggerSearch, onClear: clearSearch)
                .padding(.horizontal, Theme.contentInset)
        } content: { category in
            MagnetCategoryPage(category: category) { insets, width in
                pageContent(category, insets: insets, width: width)
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        // 一级页面的系统导航栏是隐形的（HomeView 统一处理），不能带标题
        .navigationTitle(isTabRoot ? "" : "磁力聚合")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .magnetPlayer(item: $playLaunch)
        // 链接面板上点了 115 播放 / 磁力播放：准备好后直接打开播放器
        .magnetCloudReady(hashes: detectedLink.map { [$0.infoHash] } ?? []) { _, mode in
            guard let link = detectedLink else { return }
            playLaunch = MagnetPlaybackRequest(magnet: link.uri, title: link.displayName ?? "", mode: mode)
        }
        .animation(Motion.smooth, value: detectedLink != nil)
        .animation(Motion.smooth, value: inSearchMode)
        .task { loadIfNeeded(selectedCategory) }
        .onChange(of: selectedCategory) { category in loadIfNeeded(category) }
        .onChange(of: keyword) { _ in
            // 把输入框清空（包括手动删光）等于退出搜索，回到分类浏览。
            if trimmedKeyword.isEmpty && searchActive {
                clearSearch()
            }
        }
    }

    private var displayedFreshMovies: [MagnetSearchItem] {
        MagnetAggregator.enrichSukebeiShelf(freshMovies, with: movies[.latest] ?? [])
    }

    // MARK: - 头部

    /// 第一行：分类（最新 / 专题 / 女优，和首页频道条同一个样子），右边「播放记录」。
    /// 粘贴链接不再单独占一个入口：搜索框认出磁力链接 / 哈希就直接给出解析面板（右边自带粘贴按钮）。
    private var topRow: some View {
        HStack(spacing: 4) {
            MagnetCategoryTabs(selection: categorySelection)
            Spacer(minLength: 8)
            if isTabRoot {
                NavigationLink {
                    MagnetHistoryView()
                } label: {
                    topIcon(.history)
                }
                .buttonStyle(.pressable(scale: 0.88))
                .accessibilityLabel("磁力播放记录")
                .accessibilityIdentifier("magnet.history")
            }
        }
        .padding(.leading, Theme.contentInset)
        .padding(.trailing, 6)
    }

    private func topIcon(_ icon: AppIcon) -> some View {
        Image(appIconNamed: icon.name)
            .font(.scaled(19, weight: Theme.iconWeight))
            .heroForeground()
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    // MARK: - 搜索结果 / 链接解析（盖在分页上面）

    private var searchOverlay: AnyView? {
        guard inSearchMode || detectedLink != nil else { return nil }
        return AnyView(MagnetCategoryPage(category: nil) { insets, _ in
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: insets.top)
                if let link = detectedLink {
                    MagnetLinkPanel(link: link) { mode in playLaunch = MagnetPlaybackRequest(magnet: link.uri, title: link.displayName ?? "", mode: mode) }
                        .padding(.horizontal, Theme.contentInset)
                        .padding(.top, 8)
                } else if isSearching {
                    MagnetLoadingView(style: .list)
                        .padding(.horizontal, Theme.contentInset)
                        .padding(.top, 16)
                } else if let error = searchError {
                    MagnetErrorState(message: error, retry: retrySearch)
                        .padding(.horizontal, Theme.contentInset)
                        .padding(.top, 16)
                } else {
                    searchResultContent
                        .padding(.horizontal, Theme.contentInset)
                        .padding(.top, 16)
                }
            }
            .padding(.bottom, 40)
        })
    }

    // MARK: - 每个分类的页面

    @ViewBuilder
    private func pageContent(_ category: MagnetCategory, insets: ChannelPageInsets, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if category == .latest {
                // 最新：顶部「最新上架」轮播（大封面），没到之前留出灰色占位
                let latest = movies[.latest] ?? []
                AmbientHeroSection(slides: HomeSlide.magnet(latest), reservesCarousel: latest.isEmpty && loading.contains(.latest),
                                   carouselLabel: "最新上架", carouselIdentifier: "magnet.carouselPosition",
                                   safeTop: insets.top, width: width) {
                    EmptyView()
                } hitArea: { slide in
                    heroHitArea(slide)
                }
            } else {
                Color.clear.frame(height: insets.top)
            }

            categoryContent(category)
                .padding(.horizontal, Theme.contentInset)
                .padding(.top, category == .latest ? 20 : 12)
                .padding(.bottom, 40)
        }
    }

    @ViewBuilder
    private func categoryContent(_ category: MagnetCategory) -> some View {
        switch category {
        case .topics:
            topicsContent
        case .latest:
            latestContent
        case .actresses:
            if loading.contains(.actresses) && stars.isEmpty {
                MagnetLoadingView(style: .avatars)
            } else if let error = errors[.actresses], stars.isEmpty {
                MagnetErrorState(message: error, retry: { loadCategory(.actresses) })
            } else {
                actressesContent
            }
        }
    }

    private func isEmpty(_ category: MagnetCategory) -> Bool {
        category == .actresses ? stars.isEmpty : (movies[category] ?? []).isEmpty
    }

    /// 点轮播进磁力详情
    @ViewBuilder
    private func heroHitArea(_ slide: HomeSlide) -> some View {
        if case .magnet(let movie) = slide.content {
            NavigationLink {
                MagnetDetailView(item: movie)
            } label: {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(movie.code.isEmpty ? movie.title : movie.code)
            .accessibilityIdentifier("magnet.hero.\(movie.id)")
        }
    }

    // MARK: - 搜索结果

    private var searchResultContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !matchedStars.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    MagnetSectionHeader(title: "匹配女优")

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(matchedStars) { star in
                                NavigationLink {
                                    StarMoviesView(star: star)
                                } label: {
                                    MagnetStarChip(star: star)
                                }
                                .buttonStyle(.pressable(scale: 0.97))
                            }
                        }
                    }
                }
            }

            if !searchMovies.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    MagnetSectionHeader(
                        title: "相关影片 · \(searchMovies.count)\(searchPaging.hasMore ? "+" : "")",
                        trailing: "点按查看磁力"
                    )

                    LazyVStack(spacing: 14) {
                        ForEach(searchMovies) { movie in
                            MagnetListRow(movie: movie)
                                .onAppear {
                                    if movie.id == searchMovies.last?.id {
                                        loadMoreSearch()
                                    }
                                }
                        }
                    }

                    PagingFooter(
                        isLoading: searchPaging.isLoadingMore,
                        failed: searchPaging.loadMoreFailed,
                        retry: loadMoreSearch
                    )
                }
            } else if matchedStars.isEmpty {
                MagnetEmptyState(
                    icon: .search,
                    title: "未找到相关资源",
                    message: "建议尝试直接输入标准番号（如 SSIS-888）或女优全名。"
                )
            }
        }
    }

    // MARK: - 三个分类

    /// 最新：「最新出种」横滑货架（Sukebei RSS）+「最新上架」三列海报网格，分页加载。
    private var latestContent: some View {
        let fresh = displayedFreshMovies
        let list = movies[.latest] ?? []
        let state = paging[.latest] ?? PagingState()
        let isLatestLoading = loading.contains(.latest)
        let latestError = errors[.latest]

        return Group {
            if fresh.isEmpty && list.isEmpty {
                if isLatestLoading || freshLoading {
                    VStack(alignment: .leading, spacing: 24) {
                        if freshLoading {
                            MagnetFreshShelfSkeleton()
                        }
                        MagnetLoadingView(style: .grid)
                    }
                } else if let latestError {
                    MagnetErrorState(message: latestError, retry: { loadCategory(.latest) })
                } else {
                    emptyCategory
                }
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    if !fresh.isEmpty {
                        MagnetFreshShelf(movies: fresh)
                    } else if freshLoading {
                        MagnetFreshShelfSkeleton()
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        MagnetSectionHeader(title: "最新上架", trailing: "点按查看磁力")
                        if list.isEmpty {
                            if isLatestLoading {
                                MagnetLoadingView(style: .grid)
                            } else if let latestError {
                                MagnetErrorState(message: latestError, retry: { loadCategory(.latest) })
                            } else {
                                emptyCategory
                            }
                        } else {
                            MagnetPosterGrid(movies: list, loadMore: { loadMore(.latest) })
                            PagingFooter(isLoading: state.isLoadingMore, failed: state.loadMoreFailed, retry: { loadMore(.latest) })
                        }
                    }
                }
            }
        }
    }

    /// 专题：十家片商，点进去看这家的作品。
    private var topicsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            MagnetSectionHeader(title: "按片商浏览")

            VStack(spacing: 12) {
                ForEach(MagnetStudio.allCases) { studio in
                    NavigationLink {
                        StudioMoviesView(studio: studio)
                    } label: {
                        MagnetStudioCard(studio: studio)
                    }
                    .buttonStyle(.pressable(scale: 0.985))
                    .accessibilityIdentifier("magnet.studio.\(studio.rawValue)")
                }
            }
        }
    }

    /// 女优：顶部「我喜欢的」一行（有才显示），下面三列头像按人气排序，分页加载。
    private var actressesContent: some View {
        let state = paging[.actresses] ?? PagingState()
        return VStack(alignment: .leading, spacing: 14) {
            FavoriteStarsRow()
                .padding(.bottom, favoriteStars.items.isEmpty ? 0 : 10)
            MagnetSectionHeader(title: "热门女优", trailing: "按人气排序")

            if stars.isEmpty {
                emptyCategory
            } else {
                LazyVGrid(columns: MagnetLayout.avatarColumns, spacing: 20) {
                    ForEach(stars) { star in
                        NavigationLink {
                            StarMoviesView(star: star)
                        } label: {
                            MagnetStarGridCell(star: star, favorite: favoriteStars.contains(star))
                        }
                        .buttonStyle(.pressable(scale: 0.97))
                        .contextMenu {
                            // 长按头像：喜欢 / 取消喜欢
                            let liked = favoriteStars.contains(star)
                            Button {
                                Haptics.select()
                                withAnimation(Motion.smooth) { _ = favoriteStars.toggle(star) }
                            } label: {
                                Label(liked ? "取消喜欢" : "喜欢", image: liked ? AppIcon.heart.name : AppIcon.heartFill.name)
                            }
                        }
                        .onAppear {
                            if star.id == stars.last?.id { loadMore(.actresses) }
                        }
                    }
                }

                PagingFooter(isLoading: state.isLoadingMore, failed: state.loadMoreFailed, retry: { loadMore(.actresses) })
            }
        }
    }

    private var emptyCategory: some View {
        MagnetEmptyState(
            icon: .archive,
            title: "暂无内容",
            message: "站点没有返回内容，可以稍后重试。"
        )
    }

    // MARK: - 数据加载与网络交互

    private func loadIfNeeded(_ category: MagnetCategory) {
        guard category != .topics, isEmpty(category), !loading.contains(category), errors[category] == nil else { return }
        loadCategory(category)
    }

    /// 重新加载某个分类的第一页。新请求会取消这个分类还在进行的旧请求，旧请求的结果不会再写回界面。
    private func loadCategory(_ category: MagnetCategory) {
        guard category != .topics else { return }
        tasks[category]?.cancel()
        paging[category] = PagingState()
        errors[category] = nil
        loading.insert(category)
        if category == .latest {
            loadFreshLatest()
        }
        tasks[category] = Task { @MainActor in
            do {
                switch category {
                case .actresses:
                    let result = try await JavBusSource.shared.fetchActresses(page: 1)
                    guard !Task.isCancelled else { return }
                    stars = mergeUnique([], with: result).merged
                    paging[category]?.hasMore = !result.isEmpty
                case .latest:
                    let result = try await MagnetAggregator.shared.fetchLatest(page: 1)
                    guard !Task.isCancelled else { return }
                    movies[category] = MagnetAggregator.mergeUniqueMovies([], with: result).merged
                    paging[category]?.hasMore = !result.isEmpty
                case .topics:
                    break
                }
                loading.remove(category)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                errors[category] = error.localizedDescription
                loading.remove(category)
            }
        }
    }

    private func loadFreshLatest() {
        freshTask?.cancel()
        if freshMovies.isEmpty {
            let cached = MagnetAggregator.shared.cachedFreshLatest()
            if !cached.isEmpty {
                freshMovies = cached
            }
        }
        freshLoading = freshMovies.isEmpty
        freshTask = Task { @MainActor in
            do {
                let items = try await MagnetAggregator.shared.fetchFreshLatest()
                guard !Task.isCancelled else { return }
                freshMovies = items
                freshLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                freshLoading = false
            }
        }
    }

    private func loadMore(_ category: MagnetCategory) {
        var state = paging[category] ?? PagingState()
        guard !loading.contains(category), state.hasMore, !state.isLoadingMore else { return }
        state.isLoadingMore = true
        state.loadMoreFailed = false
        paging[category] = state
        let nextPage = state.page + 1
        tasks[category] = Task { @MainActor in
            do {
                switch category {
                case .actresses:
                    let result = try await JavBusSource.shared.fetchActresses(page: nextPage)
                    guard !Task.isCancelled else { return }
                    let merged = mergeUnique(stars, with: result)
                    stars = merged.merged
                    paging[category]?.hasMore = merged.added > 0
                case .latest:
                    let result = try await MagnetAggregator.shared.fetchLatest(page: nextPage)
                    guard !Task.isCancelled else { return }
                    let merged = MagnetAggregator.mergeUniqueMovies(movies[category] ?? [], with: result)
                    movies[category] = merged.merged
                    paging[category]?.hasMore = merged.added > 0
                case .topics:
                    paging[category]?.hasMore = false
                }
                paging[category]?.page = nextPage
                paging[category]?.isLoadingMore = false
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                paging[category]?.isLoadingMore = false
                paging[category]?.loadMoreFailed = true
            }
        }
    }

    private func triggerSearch() {
        let q = trimmedKeyword
        guard !q.isEmpty, detectedLink == nil else { return }
        runSearch(q)
    }

    private func retrySearch() {
        runSearch(activeQuery.isEmpty ? trimmedKeyword : activeQuery)
    }

    private func runSearch(_ q: String) {
        guard !q.isEmpty else { return }
        searchTask?.cancel()
        activeQuery = q
        searchActive = true
        isSearching = true
        searchError = nil
        searchMovies = []
        matchedStars = []
        searchPaging = PagingState()

        searchTask = Task { @MainActor in
            do {
                // 影片（JavBus + Sukebei）与女优并发搜索：先到先渲染，Sukebei 在软超时内到达后合并。
                let result = try await MagnetAggregator.shared.searchAllProgressive(keyword: q) { partial in
                    guard !Task.isCancelled else { return }
                    searchMovies = MagnetAggregator.mergeUniqueMovies([], with: partial.movies).merged
                    matchedStars = partial.stars
                    searchPaging.hasMore = !partial.movies.isEmpty
                    isSearching = false
                }
                guard !Task.isCancelled else { return }
                searchMovies = MagnetAggregator.mergeUniqueMovies([], with: result.movies).merged
                matchedStars = result.stars
                searchPaging.hasMore = !result.movies.isEmpty
                isSearching = false
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                searchError = error.localizedDescription
                isSearching = false
            }
        }
    }

    private func loadMoreSearch() {
        guard searchActive, !isSearching, searchPaging.hasMore, !searchPaging.isLoadingMore else { return }
        searchPaging.isLoadingMore = true
        searchPaging.loadMoreFailed = false

        let q = activeQuery
        let nextPage = searchPaging.page + 1
        searchTask = Task { @MainActor in
            do {
                let movies = try await JavBusSource.shared.search(keyword: q, page: nextPage)
                guard !Task.isCancelled else { return }
                let result = MagnetAggregator.mergeUniqueMovies(searchMovies, with: movies)
                searchMovies = result.merged
                searchPaging.hasMore = result.added > 0
                searchPaging.page = nextPage
                searchPaging.isLoadingMore = false
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                searchPaging.isLoadingMore = false
                searchPaging.loadMoreFailed = true
            }
        }
    }

    private func clearSearch() {
        searchTask?.cancel()
        keyword = ""
        searchActive = false
        activeQuery = ""
        isSearching = false
        searchError = nil
        searchMovies = []
        matchedStars = []
        searchPaging = PagingState()
    }
}

/// 磁力页的一页（某个分类，或搜索结果）：一个纵向滚动视图，内容从屏幕顶端开始，
/// 上面留出固定头部的位置（channelPageInsets.top），滚动位置报给头部。
private struct MagnetCategoryPage<Content: View>: View {
    let category: MagnetCategory?
    let content: (ChannelPageInsets, CGFloat) -> Content
    @Environment(\.channelPageInsets) private var insets

    init(category: MagnetCategory?, @ViewBuilder content: @escaping (ChannelPageInsets, CGFloat) -> Content) {
        self.category = category
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content(insets, proxy.size.width)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tracksPageScroll()
            }
            .pageScrollContainer()
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .ignoresSafeArea(edges: .top)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
    }
}
