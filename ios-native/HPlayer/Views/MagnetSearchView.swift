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

/// 磁力聚合页面：按番号/女优搜索，按「最新 / 专题 / 女优 / 最热」分类浏览。
/// 四个分类左右滑动切换（PagedHeaderContainer）：分类条和搜索框是固定头部，往上滑时分类条淡出、搜索框固定在顶端。
/// 每个分类的数据各存各的，滑过去不用重新加载。搜索或粘贴了链接时，结果盖在分页上面。
/// 影片、女优、片商都是普通的逐层跳转（左上角返回上一层）；在磁力详情页点播放，
/// 播放页盖在详情页上面，关掉就回到详情页。版式见 docs/ui-design-system.md「磁力聚合」。
struct MagnetSearchView: View {
    /// 作为「磁力」Tab 的根页面：隐藏系统导航栏，右上角提供「粘贴链接播放」和「播放记录」。
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
        .navigationTitle(isTabRoot ? "磁力" : "磁力聚合")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isTabRoot ? .hidden : .automatic, for: .navigationBar)
        .magnetPlayer(item: $playLaunch)
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

    // MARK: - 头部

    /// 第一行：分类（最新 / 专题 / 女优 / 最热，和首页频道条同一个样子），右边「粘贴链接播放」和「播放记录」
    private var topRow: some View {
        HStack(spacing: 4) {
            MagnetCategoryTabs(selection: categorySelection)
            Spacer(minLength: 8)
            if isTabRoot {
                NavigationLink {
                    MagnetPlayerView()
                } label: {
                    topIcon(.link)
                }
                .buttonStyle(.pressable(scale: 0.88))
                .accessibilityLabel("粘贴磁力链接播放")
                .accessibilityIdentifier("magnet.linkPlayer")
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
        Image(systemName: icon.name)
            .font(.scaled(19, weight: Theme.iconWeight))
            .foregroundStyle(Theme.textPrimary)
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
                    MagnetLinkPanel(link: link) { playLaunch = MagnetPlaybackRequest(magnet: link.uri, title: link.displayName ?? "") }
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
        if category == .topics {
            topicsContent
        } else if loading.contains(category) && isEmpty(category) {
            MagnetLoadingView(style: loadingStyle(category))
        } else if let error = errors[category], isEmpty(category) {
            MagnetErrorState(message: error, retry: { loadCategory(category) })
        } else {
            switch category {
            case .actresses: actressesContent
            case .hot: hotContent
            case .latest, .topics: latestContent
            }
        }
    }

    private func isEmpty(_ category: MagnetCategory) -> Bool {
        category == .actresses ? stars.isEmpty : (movies[category] ?? []).isEmpty
    }

    private func loadingStyle(_ category: MagnetCategory) -> MagnetLoadingView.Style {
        switch category {
        case .actresses: return .avatars
        case .hot: return .list
        case .latest, .topics: return .grid
        }
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

    // MARK: - 四个分类

    /// 最新：「最新上架」标题 + 三列海报网格，分页加载。
    private var latestContent: some View {
        let list = movies[.latest] ?? []
        let state = paging[.latest] ?? PagingState()
        return Group {
            if list.isEmpty {
                emptyCategory
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    MagnetSectionHeader(title: "最新上架", trailing: "点按查看磁力")
                    MagnetPosterGrid(movies: list, loadMore: { loadMore(.latest) })
                    PagingFooter(isLoading: state.isLoadingMore, failed: state.loadMoreFailed, retry: { loadMore(.latest) })
                }
            }
        }
    }

    /// 专题：五家片商，点进去看这家的作品。
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
                                Label(liked ? "取消喜欢" : "喜欢", systemImage: liked ? AppIcon.heart.name : AppIcon.heartFill.name)
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

    /// 最热：一次算好的榜单（没有下一页），顶部说明口径，前三名序号是强调色。
    private var hotContent: some View {
        let list = movies[.hot] ?? []
        return VStack(alignment: .leading, spacing: 18) {
            // 口径：站点没有榜单页，这里是按女优人气排的近期主演新作。
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: AppIcon.info.name)
                    .font(.scaled(15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 1)
                Text("站点没有月榜。这里取人气靠前的女优，合并她们近 \(JavBusSource.hotWindowDays) 天已发行的主演新作（不含合集），按女优人气排序。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))

            if list.isEmpty {
                emptyCategory
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, movie in
                        MagnetListRow(movie: movie, rank: index + 1)
                    }
                }

                Text("已显示全部")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
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
        tasks[category] = Task { @MainActor in
            do {
                switch category {
                case .actresses:
                    let result = try await JavBusSource.shared.fetchActresses(page: 1)
                    guard !Task.isCancelled else { return }
                    stars = mergeUnique([], with: result).merged
                    paging[category]?.hasMore = !result.isEmpty
                case .latest, .hot:
                    let result = try await JavBusSource.shared.fetchCategory(category, page: 1)
                    guard !Task.isCancelled else { return }
                    movies[category] = mergeUnique([], with: result).merged
                    // 最热是一次算好的榜单，没有下一页。
                    paging[category]?.hasMore = category == .latest && !result.isEmpty
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
                    let result = try await JavBusSource.shared.fetchCategory(category, page: nextPage)
                    guard !Task.isCancelled else { return }
                    let merged = mergeUnique(movies[category] ?? [], with: result)
                    movies[category] = merged.merged
                    paging[category]?.hasMore = merged.added > 0
                case .topics, .hot:
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
                // 影片与女优并发搜索；女优搜索失败不影响影片结果。
                let result = try await JavBusSource.shared.searchAll(keyword: q)
                guard !Task.isCancelled else { return }
                searchMovies = mergeUnique([], with: result.movies).merged
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
                let result = mergeUnique(searchMovies, with: movies)
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
