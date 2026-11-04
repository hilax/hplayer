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
private func mergeUnique<T: Identifiable>(_ existing: [T], with new: [T]) -> (merged: [T], added: Int) where T.ID: Hashable {
    var seen = Set(existing.map(\.id))
    var merged = existing
    var added = 0
    for item in new where seen.insert(item.id).inserted {
        merged.append(item)
        added += 1
    }
    return (merged, added)
}

/// 封面/头像：走 ImagePipeline（带防盗链请求头、磁盘缓存、后台缩小解码）。
/// 加载中只显示底色，加载失败才显示占位图标。
private struct MagnetArtwork: View {
    let url: URL?
    let maxPixel: Int
    let placeholder: String

    var body: some View {
        PipelineImage(url: url, maxPixel: maxPixel) { phase in
            switch phase {
            case let .loaded(image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            case .loading:
                Rectangle().fill(Theme.surfaceRaised)
            case .failed:
                Rectangle()
                    .fill(Theme.surfaceRaised)
                    .overlay { Image(systemName: placeholder).foregroundStyle(.secondary) }
            }
        }
    }
}

/// 磁力聚合页面：按番号/女优搜索，按「最新 / 专题 / 女优 / 最热」分类浏览。
/// 影片、女优、片商都是普通的逐层跳转（左上角返回上一层）；在磁力详情页点播放，
/// 播放页盖在详情页上面，关掉就回到详情页。
struct MagnetSearchView: View {
    // 镜像域名变化时（在设置里保存后）自动重新加载。
    @AppStorage(JavBusSource.hostDefaultsKey) private var customHost = ""

    @State private var keyword = ""
    @State private var selectedCategory: MagnetCategory = .latest
    @State private var detectedClipboardCode: String?
    @State private var showingSettingsSheet = false
    @FocusState private var searchFocused: Bool

    // 分类浏览数据
    @State private var categoryMovies: [MagnetSearchItem] = []
    @State private var categoryStars: [MagnetStarItem] = []
    @State private var categoryPaging = PagingState()
    @State private var isLoadingCategory = false
    @State private var categoryError: String?
    @State private var categoryTask: Task<Void, Never>?

    // 搜索数据：只有点了搜索（或回车）才进入搜索结果视图，输入过程中不切换。
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

    private var inSearchMode: Bool {
        searchActive && !trimmedKeyword.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                searchHeaderCard

                if let clipboardCode = detectedClipboardCode, !clipboardCode.isEmpty, keyword != clipboardCode, !inSearchMode {
                    clipboardHint(code: clipboardCode)
                }

                if !inSearchMode {
                    categoryPickerSection
                }

                mainContent
            }
            .padding(.horizontal, Theme.contentInset)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("磁力聚合")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSettingsSheet = true
                } label: {
                    Image(systemName: AppIcon.settings.name)
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .sheet(isPresented: $showingSettingsSheet) {
            JavBusHostSettingsSheet()
        }
        .animation(Motion.smooth, value: inSearchMode)
        .animation(Motion.smooth, value: isSearching)
        .animation(Motion.smooth, value: isLoadingCategory)
        .animation(Motion.smooth, value: selectedCategory)
        .task {
            checkClipboard()
            if categoryMovies.isEmpty && categoryStars.isEmpty && !isLoadingCategory {
                loadCurrentCategory()
            }
        }
        .onChange(of: selectedCategory) { _ in
            loadCurrentCategory()
        }
        .onChange(of: customHost) { _ in
            reloadForHostChange()
        }
        .onChange(of: keyword) { _ in
            // 把输入框清空（包括手动删光）等于退出搜索，回到分类浏览。
            if trimmedKeyword.isEmpty && searchActive {
                clearSearch()
            }
        }
    }

    // MARK: - 主内容

    @ViewBuilder
    private var mainContent: some View {
        if inSearchMode {
            if isSearching {
                loadingView
            } else if let error = searchError {
                errorCard(message: error, retry: retrySearch)
            } else {
                searchResultContent
            }
        } else {
            if isLoadingCategory {
                loadingView
            } else if let error = categoryError {
                errorCard(message: error, retry: loadCurrentCategory)
            } else {
                categoryBrowseContent
            }
        }
    }

    // MARK: - 搜索输入卡片

    private var searchHeaderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: AppIcon.search.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField("搜索番号（如 SSIS-888）或女优名字", text: $keyword)
                    .font(.body)
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .onSubmit { triggerSearch() }

                if !keyword.isEmpty {
                    Button {
                        clearSearch()
                    } label: {
                        Image(systemName: AppIcon.clear.name)
                            .foregroundStyle(.secondary)
                    }
                }

                Button("搜索") {
                    searchFocused = false
                    triggerSearch()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .disabled(trimmedKeyword.isEmpty || isSearching)
            }
            .padding(14)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(16)
        .surfaceCard(cornerRadius: 22)
    }

    // MARK: - 分类选择 Pills

    private var categoryPickerSection: some View {
        HStack(spacing: 8) {
            ForEach(MagnetCategory.allCases) { cat in
                let isSelected = selectedCategory == cat
                Button {
                    selectedCategory = cat
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: icon(for: cat).name)
                            .font(.system(size: 12))
                        Text(cat.title)
                            .font(.subheadline.weight(isSelected ? .bold : .medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .foregroundStyle(isSelected ? Color.white : .secondary)
                    .background(isSelected ? Theme.accent : Theme.surfaceRaised, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private func icon(for category: MagnetCategory) -> AppIcon {
        switch category {
        case .latest: return .sparkles
        case .topics: return .topics
        case .actresses: return .people
        case .hot: return .hot
        }
    }

    // MARK: - 剪贴板快速提示

    private func clipboardHint(code: String) -> some View {
        Button {
            keyword = code
            triggerSearch()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: AppIcon.copy.name)
                    .font(.system(size: 13, weight: .semibold))
                Text("识别到剪贴板番号: \(code)，点击快速搜索")
                    .font(.footnote.weight(.medium))
                Spacer()
                Image(systemName: AppIcon.forward.name)
                    .font(.system(size: 14))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 搜索结果视图

    @ViewBuilder
    private var searchResultContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !matchedStars.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("匹配女优")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(matchedStars) { star in
                                NavigationLink {
                                    StarMoviesView(star: star)
                                } label: {
                                    starBadge(star: star)
                                }
                                .buttonStyle(.pressable(scale: 0.97))
                            }
                        }
                    }
                }
            }

            if !searchMovies.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("相关影片 (\(searchMovies.count)\(searchPaging.hasMore ? "+" : ""))")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("点击查看磁力")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    LazyVStack(spacing: 12) {
                        ForEach(searchMovies) { movie in
                            movieLink(movie)
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
                emptyResultView
            }
        }
    }

    // MARK: - 分类浏览视图

    @ViewBuilder
    private var categoryBrowseContent: some View {
        switch selectedCategory {
        case .topics:
            topicsContent
        case .actresses:
            actressesContent
        case .latest, .hot:
            movieCategoryContent
        }
    }

    /// 专题：五家片商，点进去看这家的作品。
    private var topicsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("按片商浏览")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                ForEach(MagnetStudio.allCases) { studio in
                    NavigationLink {
                        StudioMoviesView(studio: studio)
                    } label: {
                        studioCard(studio)
                    }
                    .buttonStyle(.pressable(scale: 0.985))
                }
            }
        }
    }

    private var actressesContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("热门女优演员")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            if categoryStars.isEmpty {
                emptyCategoryView
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 14)], spacing: 16) {
                    ForEach(categoryStars) { star in
                        NavigationLink {
                            StarMoviesView(star: star)
                        } label: {
                            starGridCard(star: star)
                        }
                        .buttonStyle(.pressable(scale: 0.97))
                        .onAppear {
                            if star.id == categoryStars.last?.id {
                                loadMoreCategory()
                            }
                        }
                    }
                }

                PagingFooter(
                    isLoading: categoryPaging.isLoadingMore,
                    failed: categoryPaging.loadMoreFailed,
                    retry: loadMoreCategory
                )
            }
        }
    }

    /// 最新（分页加载）和最热（一次算好、不分页）共用的影片列表。
    private var movieCategoryContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(selectedCategory == .hot ? "最热影片" : "最新发布影片")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(selectedCategory == .hot ? "近期新作" : "实时更新")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if selectedCategory == .hot {
                    // 说明口径：站点没有榜单页，这里是按女优人气排的近期新作。
                    Text("站点没有月榜：这里取人气靠前的女优，合并她们近 \(JavBusSource.hotWindowDays) 天已发行的主演新作（不含合集，作品太少时自动放宽），按女优人气排序。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if categoryMovies.isEmpty {
                emptyCategoryView
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(categoryMovies) { movie in
                        movieLink(movie)
                            .onAppear {
                                if movie.id == categoryMovies.last?.id {
                                    loadMoreCategory()
                                }
                            }
                    }
                }

                PagingFooter(
                    isLoading: categoryPaging.isLoadingMore,
                    failed: categoryPaging.loadMoreFailed,
                    retry: loadMoreCategory
                )
            }
        }
    }

    // MARK: - 片商卡片

    private func studioCard(_ studio: MagnetStudio) -> some View {
        HStack(spacing: 14) {
            Text(studio.monogram)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 52, height: 52)
                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(studio.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(studio.codeHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: AppIcon.forward.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(cornerRadius: 16)
    }

    // MARK: - 影片卡片组件

    /// 点击进入这部片的磁力详情页。
    private func movieLink(_ movie: MagnetSearchItem) -> some View {
        NavigationLink {
            MagnetDetailView(item: movie)
        } label: {
            movieCard(item: movie)
        }
        .buttonStyle(.pressable(scale: 0.985))
    }

    private func movieCard(item: MagnetSearchItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            MagnetArtwork(url: item.coverURL, maxPixel: 354, placeholder: AppIcon.poster.name)
                .frame(width: 86, height: 118)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                if !item.code.isEmpty {
                    Text(item.code)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.14), in: Capsule())
                }

                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let date = item.releaseDate {
                    HStack(spacing: 4) {
                        Image(systemName: AppIcon.clock.name)
                            .font(.system(size: 11))
                        Text(date)
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                HStack {
                    Spacer()
                    Label("获取磁力", systemImage: AppIcon.download.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .surfaceCard(cornerRadius: 16)
    }

    // MARK: - 女优卡片组件

    private func starBadge(star: MagnetStarItem) -> some View {
        HStack(spacing: 10) {
            MagnetArtwork(url: star.avatarURL, maxPixel: 132, placeholder: AppIcon.mine.name)
                .frame(width: 44, height: 44)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(star.name)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                Text("点击查看全部作品")
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
            }
            Image(systemName: AppIcon.forward.name)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .surfaceCard(cornerRadius: 14)
    }

    private func starGridCard(star: MagnetStarItem) -> some View {
        VStack(spacing: 8) {
            MagnetArtwork(url: star.avatarURL, maxPixel: 240, placeholder: AppIcon.mine.name)
                .frame(width: 80, height: 80)
                .clipShape(Circle())

            Text(star.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .surfaceCard(cornerRadius: 14)
    }

    // MARK: - 辅助状态视图

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(Theme.accent)
            Text("正在实时获取资源...")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private func errorCard(message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            Image(systemName: AppIcon.alert.name)
                .font(.system(size: 36))
                .foregroundStyle(Color.orange)

            Text("加载未完成")
                .font(.headline)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            HStack(spacing: 12) {
                Button("更换镜像域名") {
                    showingSettingsSheet = true
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)

                Button("重新尝试", action: retry)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .surfaceCard(cornerRadius: 20)
    }

    private var emptyResultView: some View {
        VStack(spacing: 12) {
            Image(systemName: AppIcon.search.name)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("未找到相关资源")
                .font(.headline)
            Text("建议尝试直接输入标准番号（如 SSIS-888）或女优全名。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var emptyCategoryView: some View {
        VStack(spacing: 12) {
            Image(systemName: AppIcon.archive.name)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("暂无内容")
                .font(.headline)
            Text("站点没有返回内容，可以稍后重试，或在右上角设置里更换镜像域名。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - 数据加载与网络交互

    /// 重新加载当前分类的第一页。新请求会取消还在进行的旧请求，旧请求的结果不会再写回界面。
    private func loadCurrentCategory() {
        categoryTask?.cancel()
        categoryPaging = PagingState()
        categoryError = nil

        let category = selectedCategory
        // 专题是固定的片商入口，没有要加载的内容。
        guard category != .topics else {
            categoryPaging.hasMore = false
            isLoadingCategory = false
            return
        }

        isLoadingCategory = true
        categoryTask = Task { @MainActor in
            do {
                switch category {
                case .actresses:
                    let stars = try await JavBusSource.shared.fetchActresses(page: 1)
                    guard !Task.isCancelled else { return }
                    categoryStars = mergeUnique([], with: stars).merged
                    categoryPaging.hasMore = !stars.isEmpty
                case .latest, .hot:
                    let movies = try await JavBusSource.shared.fetchCategory(category, page: 1)
                    guard !Task.isCancelled else { return }
                    categoryMovies = mergeUnique([], with: movies).merged
                    // 最热是一次算好的榜单，没有下一页。
                    categoryPaging.hasMore = category == .latest && !movies.isEmpty
                case .topics:
                    break
                }
                isLoadingCategory = false
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                categoryError = error.localizedDescription
                isLoadingCategory = false
            }
        }
    }

    private func loadMoreCategory() {
        guard !isLoadingCategory, categoryPaging.hasMore, !categoryPaging.isLoadingMore else { return }
        categoryPaging.isLoadingMore = true
        categoryPaging.loadMoreFailed = false

        let category = selectedCategory
        let nextPage = categoryPaging.page + 1
        categoryTask = Task { @MainActor in
            do {
                switch category {
                case .actresses:
                    let stars = try await JavBusSource.shared.fetchActresses(page: nextPage)
                    guard !Task.isCancelled else { return }
                    let result = mergeUnique(categoryStars, with: stars)
                    categoryStars = result.merged
                    categoryPaging.hasMore = result.added > 0
                case .latest:
                    let movies = try await JavBusSource.shared.fetchCategory(category, page: nextPage)
                    guard !Task.isCancelled else { return }
                    let result = mergeUnique(categoryMovies, with: movies)
                    categoryMovies = result.merged
                    categoryPaging.hasMore = result.added > 0
                case .topics, .hot:
                    categoryPaging.hasMore = false
                }
                categoryPaging.page = nextPage
                categoryPaging.isLoadingMore = false
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                categoryPaging.isLoadingMore = false
                categoryPaging.loadMoreFailed = true
            }
        }
    }

    private func triggerSearch() {
        let q = trimmedKeyword
        guard !q.isEmpty else { return }
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

    private func reloadForHostChange() {
        loadCurrentCategory()
        if inSearchMode {
            runSearch(activeQuery)
        }
    }

    private func checkClipboard() {
        guard let clip = UIPasteboard.general.string else { return }
        if let extracted = AVCatalogCode.extract(clip) {
            detectedClipboardCode = extracted
        }
    }
}

// MARK: - 影片行与分页列表（女优页、片商页共用）

/// 紧凑的影片行：封面、番号、标题、发行日期。点击进入这部片的磁力详情页。
private struct MagnetMovieRow: View {
    let movie: MagnetSearchItem

    var body: some View {
        NavigationLink {
            MagnetDetailView(item: movie)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                MagnetArtwork(url: movie.coverURL, maxPixel: 312, placeholder: AppIcon.poster.name)
                    .frame(width: 76, height: 104)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    if !movie.code.isEmpty {
                        Text(movie.code)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.14), in: Capsule())
                    }

                    Text(movie.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if let date = movie.releaseDate {
                        HStack(spacing: 4) {
                            Image(systemName: AppIcon.clock.name)
                                .font(.system(size: 10))
                            Text(date)
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 2)

                    HStack {
                        Spacer()
                        Label("查看磁力", systemImage: AppIcon.download.name)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .surfaceCard(cornerRadius: 14)
        }
        .buttonStyle(.pressable(scale: 0.985))
    }
}

/// 一页页加载的影片列表：加载中、失败重试、空列表、列表加底部翻页提示。
private struct MagnetMovieFeed: View {
    let title: String
    let emptyText: String
    let movies: [MagnetSearchItem]
    let isLoading: Bool
    let errorText: String?
    let paging: PagingState
    let retry: () -> Void
    let loadMore: () -> Void

    var body: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView().tint(Theme.accent)
                Text("正在加载作品列表...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        } else if let errorText {
            VStack(spacing: 12) {
                Image(systemName: AppIcon.alert.name)
                    .font(.system(size: 32))
                    .foregroundStyle(Color.orange)
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("重试", action: retry)
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        } else if movies.isEmpty {
            Text(emptyText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 180)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(title) (\(movies.count)\(paging.hasMore ? "+" : ""))")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.contentInset)

                LazyVStack(spacing: 12) {
                    ForEach(movies) { movie in
                        MagnetMovieRow(movie: movie)
                            .onAppear {
                                if movie.id == movies.last?.id {
                                    loadMore()
                                }
                            }
                    }
                }
                .padding(.horizontal, Theme.contentInset)

                PagingFooter(
                    isLoading: paging.isLoadingMore,
                    failed: paging.loadMoreFailed,
                    retry: loadMore
                )
            }
        }
    }
}

// MARK: - 女优作品列表页 (StarMoviesView)

/// 女优页的作品范围。
private enum StarWorksMode: String, CaseIterable, Identifiable {
    /// 她本人主演的片子（按名字搜索）。
    case lead
    /// 女优页列出的全部参演作品，包含她出镜的合集、BEST、多人作品。
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lead: return "主演作品"
        case .all: return "全部参演"
        }
    }
}

struct StarMoviesView: View {
    let star: MagnetStarItem

    @State private var mode: StarWorksMode = .lead
    @State private var movies: [MagnetSearchItem] = []
    @State private var detailedStar: MagnetStarItem?
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var paging = PagingState()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                starHeader

                Picker("作品范围", selection: $mode) {
                    ForEach(StarWorksMode.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Theme.contentInset)

                MagnetMovieFeed(
                    title: mode == .lead ? "主演作品" : "全部参演（含合集）",
                    emptyText: mode == .lead ? "没有找到她主演的作品，可以切换到「全部参演」查看" : "暂无参演作品",
                    movies: movies,
                    isLoading: isLoading,
                    errorText: errorText,
                    paging: paging,
                    retry: { Task { await loadFirstPage() } },
                    loadMore: { Task { await loadMore() } }
                )
            }
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle(star.name)
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .onChange(of: mode) { _ in
            Task { await loadFirstPage() }
        }
        .task {
            // 从下一层返回时页面会再次出现，已经加载好的内容不重新加载。
            guard movies.isEmpty, errorText == nil else { return }
            async let header: Void = loadHeader()
            await loadFirstPage()
            await header
        }
    }

    private var starHeader: some View {
        VStack(spacing: 12) {
            MagnetArtwork(url: (detailedStar ?? star).avatarURL, maxPixel: 270, placeholder: AppIcon.mine.name)
                .frame(width: 90, height: 90)
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.accent.opacity(0.3), lineWidth: 2))

            Text((detailedStar ?? star).name)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)

            if let bio = (detailedStar ?? star).bio, !bio.isEmpty {
                Text(bio)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .surfaceCard(cornerRadius: 18)
        .padding(.horizontal, Theme.contentInset)
    }

    /// 头部资料（身高、罩杯等）来自女优页；取不到不影响作品列表。
    @MainActor
    private func loadHeader() async {
        guard detailedStar == nil else { return }
        if let result = try? await JavBusSource.shared.fetchStarDetail(starPath: star.detailPath, page: 1) {
            detailedStar = result.star
        }
    }

    @MainActor
    private func loadFirstPage() async {
        let requested = mode
        isLoading = true
        errorText = nil
        paging = PagingState()
        movies = []
        do {
            let list = try await fetch(page: 1, mode: requested)
            // 加载期间切换了范围：结果作废，由新范围的加载来写。
            guard requested == mode else { return }
            movies = mergeUnique([], with: list).merged
            paging.hasMore = !list.isEmpty
            isLoading = false
        } catch {
            // 页面被关闭时任务会被取消，不用再更新界面。
            if error is CancellationError { return }
            guard requested == mode else { return }
            errorText = error.localizedDescription
            isLoading = false
        }
    }

    @MainActor
    private func loadMore() async {
        guard !isLoading, paging.hasMore, !paging.isLoadingMore else { return }
        let requested = mode
        paging.isLoadingMore = true
        paging.loadMoreFailed = false
        let nextPage = paging.page + 1
        do {
            let list = try await fetch(page: nextPage, mode: requested)
            guard requested == mode else { return }
            let result = mergeUnique(movies, with: list)
            movies = result.merged
            paging.hasMore = result.added > 0
            paging.page = nextPage
            paging.isLoadingMore = false
        } catch {
            if error is CancellationError { paging.isLoadingMore = false; return }
            guard requested == mode else { return }
            paging.isLoadingMore = false
            paging.loadMoreFailed = true
        }
    }

    @MainActor
    private func fetch(page: Int, mode: StarWorksMode) async throws -> [MagnetSearchItem] {
        switch mode {
        case .lead:
            return try await JavBusSource.shared.fetchLeadMovies(starName: star.name, page: page)
        case .all:
            let (info, list) = try await JavBusSource.shared.fetchStarDetail(starPath: star.detailPath, page: page)
            if detailedStar == nil, let info { detailedStar = info }
            return list
        }
    }
}

// MARK: - 片商作品列表页 (StudioMoviesView)

struct StudioMoviesView: View {
    let studio: MagnetStudio

    @State private var movies: [MagnetSearchItem] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var paging = PagingState()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                studioHeader

                MagnetMovieFeed(
                    title: "片商作品",
                    emptyText: "暂无作品",
                    movies: movies,
                    isLoading: isLoading,
                    errorText: errorText,
                    paging: paging,
                    retry: { Task { await loadFirstPage() } },
                    loadMore: { Task { await loadMore() } }
                )
            }
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle(studio.title)
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .task {
            guard movies.isEmpty, errorText == nil else { return }
            await loadFirstPage()
        }
    }

    private var studioHeader: some View {
        VStack(spacing: 10) {
            Text(studio.monogram)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 72, height: 72)
                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            Text(studio.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)

            Text(studio.codeHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .surfaceCard(cornerRadius: 18)
        .padding(.horizontal, Theme.contentInset)
    }

    @MainActor
    private func loadFirstPage() async {
        isLoading = true
        errorText = nil
        paging = PagingState()
        do {
            let list = try await JavBusSource.shared.fetchStudio(studio, page: 1)
            movies = mergeUnique([], with: list).merged
            paging.hasMore = !list.isEmpty
            isLoading = false
        } catch {
            if error is CancellationError { return }
            errorText = error.localizedDescription
            isLoading = false
        }
    }

    @MainActor
    private func loadMore() async {
        guard !isLoading, paging.hasMore, !paging.isLoadingMore else { return }
        paging.isLoadingMore = true
        paging.loadMoreFailed = false
        let nextPage = paging.page + 1
        do {
            let list = try await JavBusSource.shared.fetchStudio(studio, page: nextPage)
            let result = mergeUnique(movies, with: list)
            movies = result.merged
            paging.hasMore = result.added > 0
            paging.page = nextPage
            paging.isLoadingMore = false
        } catch {
            paging.isLoadingMore = false
            if error is CancellationError { return }
            paging.loadMoreFailed = true
        }
    }
}

// MARK: - 磁力详情页 (MagnetDetailView，带女优下钻)

struct MagnetDetailView: View {
    let item: MagnetSearchItem

    @EnvironmentObject private var appState: AppState
    @AppStorage("hplayer.magnet.cloudRelay") private var cloudRelay = true
    @State private var magnets: [MagnetTorrentItem] = []
    @State private var stars: [MagnetStarItem] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var copiedMagnetID: String?
    /// 点了播放：播放页盖在详情页上面，关掉后仍停留在这一页。
    @State private var playLaunch: MagnetLaunch?

    var body: some View {
        VStack(spacing: 0) {
            headerCard

            Divider()

            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(Theme.accent)
                    Text("正在拉取磁力链接与影片详情...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorText {
                VStack(spacing: 12) {
                    Image(systemName: AppIcon.alert.name)
                        .font(.system(size: 32))
                        .foregroundStyle(Color.orange)
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button("重新获取") {
                        Task { await fetchDetails() }
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if magnets.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: AppIcon.archive.name)
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("该影片暂无可用的磁力链接")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                magnetListView
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("资源与磁力详情")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .sheet(item: $playLaunch) { launch in
            NavigationStack { MagnetPlayerView(initialMagnet: launch.value, closesAfterPlayback: true) }
                .environmentObject(appState)
        }
        .task {
            // 从女优页返回时页面会再次出现，已经取到的磁力不重新拉取。
            guard magnets.isEmpty, stars.isEmpty, errorText == nil else { return }
            await fetchDetails()
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                MagnetArtwork(url: item.coverURL, maxPixel: 240, placeholder: AppIcon.poster.name)
                    .frame(width: 58, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    if !item.code.isEmpty {
                        Text(item.code)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.accent)
                    }
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if let date = item.releaseDate {
                        Text("发行日期: \(date)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            if !stars.isEmpty {
                HStack(spacing: 6) {
                    Text("参演女优:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(stars) { star in
                                NavigationLink {
                                    StarMoviesView(star: star)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: AppIcon.mine.name)
                                            .font(.system(size: 9))
                                        Text(star.name)
                                            .font(.caption2.weight(.medium))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .foregroundStyle(Theme.accent)
                                    .background(Theme.accent.opacity(0.12), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.surface)
    }

    private var magnetListView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(magnets) { torrent in
                    magnetRow(torrent: torrent)
                }
            }
            .padding(16)
        }
    }

    private func magnetRow(torrent: MagnetTorrentItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                if torrent.hasSubtitles {
                    Text("中文字幕")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }

                if torrent.isHD {
                    Text("高清")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }

                Text(torrent.size)
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)

                if let date = torrent.date {
                    Text(date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()
            }

            Text(torrent.name)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(2)

            HStack(spacing: 10) {
                Button {
                    playLaunch = MagnetLaunch(value: torrent.magnetURL)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: AppIcon.play.name)
                        Text(cloudRelay ? "115 云下载播放" : "磁力播放")
                    }
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)

                Button {
                    UIPasteboard.general.string = torrent.magnetURL
                    copiedMagnetID = torrent.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if copiedMagnetID == torrent.id { copiedMagnetID = nil }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copiedMagnetID == torrent.id ? AppIcon.check.name : AppIcon.copy.name)
                        Text(copiedMagnetID == torrent.id ? "已复制" : "复制磁力")
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)

                Spacer()
            }
        }
        .padding(14)
        .surfaceCard(cornerRadius: 14)
    }

    @MainActor
    private func fetchDetails() async {
        isLoading = true
        errorText = nil
        do {
            let (actresses, torrents) = try await JavBusSource.shared.fetchDetailInfo(for: item)
            stars = actresses
            magnets = torrents
            isLoading = false
        } catch {
            // 页面被关闭时任务会被取消，不用再更新界面。
            if error is CancellationError { return }
            errorText = error.localizedDescription
            isLoading = false
        }
    }
}

// MARK: - 镜像域名设置弹窗

struct JavBusHostSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(JavBusSource.hostDefaultsKey) private var customHost = ""
    @State private var inputHost = ""

    private let presets = [
        "https://www.javbus.com",
        "https://www.busdmm.work",
        "https://www.dmmsee.art"
    ]

    private var trimmedInput: String {
        inputHost.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 输入为空（恢复默认）或能整理成合法的 http(s) 域名才允许保存。
    private var isInputValid: Bool {
        trimmedInput.isEmpty || JavBusSource.normalizedHost(trimmedInput) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://www.javbus.com", text: $inputHost)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                } header: {
                    Text("JavBus 访问域名")
                } footer: {
                    if isInputValid {
                        Text("当默认域名 javbus.com 受到网络屏蔽或 Cloudflare 防护拦截时，可切换为备用或镜像域名。未写 https:// 时会自动补全。")
                    } else {
                        Text("域名格式不正确，请输入形如 https://www.javbus.com 的地址。")
                            .foregroundStyle(.red)
                    }
                }

                Section("常用预设域名") {
                    ForEach(presets, id: \.self) { preset in
                        Button {
                            inputHost = preset
                        } label: {
                            HStack {
                                Text(preset)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if inputHost == preset {
                                    Image(systemName: AppIcon.check.name)
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                }

                Section {
                    Button("恢复默认域名") {
                        inputHost = JavBusSource.defaultHost
                    }
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle("镜像域名配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        customHost = JavBusSource.normalizedHost(trimmedInput) ?? ""
                        dismiss()
                    }
                    .foregroundStyle(isInputValid ? Theme.accent : Color.secondary)
                    .disabled(!isInputValid)
                }
            }
            .onAppear {
                inputHost = customHost.isEmpty ? JavBusSource.defaultHost : customHost
            }
        }
    }
}
