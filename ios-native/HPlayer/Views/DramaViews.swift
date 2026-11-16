import SwiftUI

struct DramaRoute: Hashable {
    let id: Int
    let title: String
    let cover: String
}

// MARK: - 封面

/// 短剧封面：密文取回后本机解密（见 DramaCoverStore），2:3 竖版。
struct DramaCover: View {
    let urlString: String
    let title: String
    @State private var image: UIImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Theme.surfaceRaised
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(ArtworkReveal.insertion(reduceMotion: reduceMotion))
            } else {
                Text(String(title.prefix(1)))
                    .font(.scaled(28, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .task(id: urlString) {
            if let cached = DramaCoverStore.shared.cached(urlString) { image = cached; return }
            image = nil
            guard !urlString.isEmpty, !InterfacePreview.active else { return }
            let loaded = await DramaCoverStore.shared.image(for: urlString)
            guard !Task.isCancelled else { return }
            withAnimation(ArtworkReveal.animation) { image = loaded }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 列表数据

@MainActor
final class DramaFeed: ObservableObject {
    /// 频道首页的货架和完整列表页共用一份
    static let shared = DramaFeed()

    struct Shelf {
        var items: [DramaCard] = []
        var page = 0
        var hasMore = true
        var loading = false
        var error = ""
    }

    @Published private(set) var shelves: [DramaCategory: Shelf] = [:]

    func shelf(_ category: DramaCategory) -> Shelf { shelves[category] ?? Shelf() }

    func loadFirstIfNeeded(_ category: DramaCategory) async {
        guard shelf(category).page == 0 else { return }
        await loadMore(category)
    }

    /// 下拉刷新：列表先留着，取到新的第一页再整页替换，不会先清空成骨架
    func reload(_ category: DramaCategory) async {
        var state = shelf(category)
        guard !state.loading else { return }
        state.page = 0
        state.hasMore = true
        state.error = ""
        shelves[category] = state
        await loadMore(category)
    }

    func loadMore(_ category: DramaCategory) async {
        var state = shelf(category)
        guard !state.loading, state.hasMore, !InterfacePreview.active else { return }
        state.loading = true
        state.error = ""
        shelves[category] = state
        do {
            let result = try await DramaClient.shared.list(category, page: state.page + 1)
            var updated = shelf(category)
            if state.page == 0 {
                // 第一页（含下拉刷新）：整页替换
                updated.items = result.items
                updated.page = result.page
                updated.hasMore = result.hasMore && !result.items.isEmpty
                updated.loading = false
                shelves[category] = updated
                return
            }
            let known = Set(updated.items.map(\.id))
            let fresh = result.items.filter { !known.contains($0.id) }
            updated.items += fresh
            updated.page = result.page
            updated.hasMore = result.hasMore && !fresh.isEmpty
            updated.loading = false
            shelves[category] = updated
        } catch {
            var updated = shelf(category)
            updated.loading = false
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled { updated.error = error.localizedDescription }
            shelves[category] = updated
        }
    }
}

/// 热播榜：一次取整张榜，不分页；下拉刷新重新取。条目已在 DramaClient 里过滤过（不含换脸、魔改）。
@MainActor
final class DramaRankFeed: ObservableObject {
    static let shared = DramaRankFeed()

    @Published private(set) var items: [DramaRankItem] = []
    @Published private(set) var loading = false
    @Published private(set) var error = ""
    @Published private(set) var hasLoaded = false

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    func reload() async {
        guard !loading, !InterfacePreview.active else { return }
        loading = true
        error = ""
        do {
            items = try await DramaClient.shared.hotRanks()
            hasLoaded = true
        } catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                self.error = error.localizedDescription
            }
        }
        loading = false
    }
}

// MARK: - 首页「短剧」频道

/// 短剧的完整列表：一个内容分类（三列网格，滑到底翻页）或整张热播榜。从快捷入口、货架「全部」推进来。
enum DramaBrowseRoute: Hashable {
    case category(DramaCategory)
    case ranks

    var title: String {
        switch self {
        case .category(let category): return category.title
        case .ranks: return "热播榜"
        }
    }
}

/// 短剧频道首页：和动漫频道一样，顶部是热播榜前几名的轮播（铺氛围层），下面一排快捷入口，
/// 再往下是热播榜、短剧、漫剧三排横滑货架，右边「全部」进完整列表。
struct DramaTab: View {
    @ObservedObject private var feed = DramaFeed.shared
    @ObservedObject private var rankFeed = DramaRankFeed.shared
    /// 内容从哪里开始（频道容器的固定头部盖在上面）
    @Environment(\.channelPageInsets) private var insets

    private let cardWidth: CGFloat = 108

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    AmbientHeroSection(slides: HomeSlide.drama(rankFeed.items), reservesCarousel: true,
                                       carouselLabel: "热播榜轮播", carouselIdentifier: "drama.bannerPosition",
                                       safeTop: insets.top, width: proxy.size.width) {
                        EmptyView()
                    } hitArea: { slide in
                        bannerHitArea(slide)
                    }

                    shortcuts
                        .padding(.top, 16)

                    VStack(alignment: .leading, spacing: Theme.Space.shelf) {
                        rankShelf
                        ForEach(DramaCategory.allCases) { category in
                            categoryShelf(category)
                        }
                    }
                    .padding(.horizontal, Theme.contentInset)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tracksPageScroll()
            }
            .pageScrollContainer()
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .refreshable {
                async let ranks: Void = rankFeed.reload()
                async let series: Void = feed.reload(.series)
                async let animated: Void = feed.reload(.animated)
                _ = await (ranks, series, animated)
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .designScreen("drama")
        .task {
            async let ranks: Void = rankFeed.loadIfNeeded()
            async let series: Void = feed.loadFirstIfNeeded(.series)
            async let animated: Void = feed.loadFirstIfNeeded(.animated)
            _ = await (ranks, series, animated)
        }
    }

    // MARK: 轮播与快捷入口

    /// 点轮播进短剧详情
    @ViewBuilder
    private func bannerHitArea(_ slide: HomeSlide) -> some View {
        if case .drama(let drama) = slide.content {
            NavigationLink(value: DramaRoute(id: drama.id, title: drama.title, cover: drama.cover)) {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(drama.title)
            .accessibilityIdentifier("drama.banner.\(drama.id)")
        }
    }

    private var shortcuts: some View {
        HStack(spacing: 4) {
            shortcut(.category(.series), title: "短剧",
                     icon: .series)
            shortcut(.category(.animated), title: "漫剧",
                     icon: .tv)
            shortcut(.ranks, title: "热播榜",
                     icon: .hot)
        }
        .padding(.horizontal, 10)
    }

    private func shortcut(_ route: DramaBrowseRoute, title: String, icon: AppIcon) -> some View {
        NavigationLink(value: route) {
            ChannelShortcutLabel(title: title, icon: icon)
        }
        .buttonStyle(.pressable(scale: 0.92))
        .accessibilityIdentifier("drama.shortcut.\(title)")
    }

    // MARK: 货架

    @ViewBuilder
    private var rankShelf: some View {
        if !rankFeed.items.isEmpty {
            shelf(.ranks, identifier: "drama.shelf.ranks") {
                ForEach(Array(rankFeed.items.prefix(12).enumerated()), id: \.element.id) { index, item in
                    NavigationLink(value: DramaRoute(id: item.videoId, title: item.title, cover: item.cover)) {
                        DramaRankPosterCard(item: item, width: cardWidth)
                    }
                    .buttonStyle(PosterButtonStyle())
                    .accessibilityIdentifier("drama.rank.\(item.videoId)")
                    .reveal(index, id: "ranks.\(item.videoId)")
                    .shelfCard()
                }
            }
            .onAppear {
                if !InterfacePreview.active { DramaCoverStore.shared.prefetch(rankFeed.items.prefix(12).map(\.cover)) }
            }
        } else if !rankFeed.error.isEmpty {
            retryShelf(.ranks) { Task { await rankFeed.reload() } }
        } else if rankFeed.loading || !rankFeed.hasLoaded {
            shelfSkeleton(DramaBrowseRoute.ranks.title)
        }
    }

    @ViewBuilder
    private func categoryShelf(_ category: DramaCategory) -> some View {
        let state = feed.shelf(category)
        if !state.items.isEmpty {
            shelf(.category(category), identifier: "drama.shelf.\(category.rawValue)") {
                ForEach(Array(state.items.prefix(12).enumerated()), id: \.element.id) { index, item in
                    NavigationLink(value: DramaRoute(id: item.id, title: item.title, cover: item.cover)) {
                        DramaPosterCard(item: item)
                            .frame(width: cardWidth)
                    }
                    .buttonStyle(PosterButtonStyle())
                    .accessibilityIdentifier("drama.poster.\(item.id)")
                    .reveal(index, id: "\(category.rawValue).\(item.id)")
                    .shelfCard()
                }
            }
            .onAppear {
                if !InterfacePreview.active { DramaCoverStore.shared.prefetch(state.items.prefix(12).map(\.cover)) }
            }
        } else if !state.error.isEmpty {
            retryShelf(.category(category)) { Task { await feed.reload(category) } }
        } else if state.loading || state.page == 0 {
            shelfSkeleton(category.title)
        }
    }

    private func shelf<Cards: View>(_ route: DramaBrowseRoute, identifier: String,
                                    @ViewBuilder cards: () -> Cards) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            shelfHeader(route, identifier: identifier)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    cards()
                }
                .shelfContent()
                .padding(.vertical, 4)
            }
            .shelfScrolling()
            .padding(.horizontal, -Theme.contentInset)
            .scrollIndicators(.hidden)
        }
    }

    private func shelfHeader(_ route: DramaBrowseRoute, identifier: String) -> some View {
        ShelfHeader(title: route.title, identifier: identifier, inset: 0) {
            NavigationLink(value: route) {
                ShelfLinkLabel(text: "全部")
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
            }
            .buttonStyle(.pressable(scale: 0.92))
            .accessibilityIdentifier("\(identifier).all")
        }
    }

    private func retryShelf(_ route: DramaBrowseRoute, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ShelfHeader(title: route.title, inset: 0) { EmptyView() }
                .frame(minHeight: 44, alignment: .leading)
            Button(action: retry) {
                HStack(spacing: 8) {
                    Image(icon: .refresh).iconStyle(size: 13, color: Theme.accent)
                    Text("没有加载出来，点按重试")
                        .font(.scaled(13))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            }
            .buttonStyle(.pressable(scale: 0.98))
        }
    }

    private func shelfSkeleton(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ShelfHeader(title: title, inset: 0) { EmptyView() }
                .frame(minHeight: 44, alignment: .leading)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(0..<4, id: \.self) { _ in
                        AnimePosterSkeleton(width: cardWidth)
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
}

/// 热播榜货架的一张：竖封面，左上角压名次（前三名琥珀色），下面片名和分类集数。
private struct DramaRankPosterCard: View {
    let item: DramaRankItem
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .frame(width: width, height: width * 1.5)
                .overlay { DramaCover(urlString: item.cover, title: item.title) }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Text("\(item.rank)")
                        .font(Font.numeral(15))
                        .foregroundStyle(item.rank <= 3 ? Theme.onPrimary : .white)
                        .frame(minWidth: 24, minHeight: 22)
                        .padding(.horizontal, 4)
                        .background(item.rank <= 3 ? Theme.rating : Color.black.opacity(Theme.Opacity.strong),
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
                        .padding(6)
                }
            Text(item.title)
                .font(.scaled(13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Text(item.subtitle)
                .font(.scaled(11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第 \(item.rank) 名，\(item.title)")
    }
}

// MARK: - 短剧完整列表

struct DramaBrowseView: View {
    let route: DramaBrowseRoute
    @ObservedObject private var feed = DramaFeed.shared
    @ObservedObject private var rankFeed = DramaRankFeed.shared

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch route {
                case .category(let category): categoryContent(category)
                case .ranks: ranksContent
                }
            }
            .padding(.top, 12)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            switch route {
            case .category(let category): await feed.reload(category)
            case .ranks: await rankFeed.reload()
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .designScreen("drama-browse")
        .task {
            switch route {
            case .category(let category): await feed.loadFirstIfNeeded(category)
            case .ranks: await rankFeed.loadIfNeeded()
            }
        }
    }

    @ViewBuilder
    private func categoryContent(_ category: DramaCategory) -> some View {
        let shelf = feed.shelf(category)
        if shelf.items.isEmpty {
            Group {
                if !shelf.error.isEmpty {
                    EmptyStateView(icon: AppIcon.alert.name, title: "短剧没有加载出来", message: shelf.error,
                                   actionTitle: "重新加载") { Task { await feed.reload(category) } }
                } else if shelf.loading || shelf.page == 0 {
                    ProgressView().tint(Theme.textSecondary)
                } else {
                    EmptyStateView(icon: AppIcon.video.name, title: "暂时没有内容", message: "这个分类下还没有短剧，稍后再来看看。")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 360)
        } else {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(Array(shelf.items.enumerated()), id: \.element.id) { index, item in
                    NavigationLink(value: DramaRoute(id: item.id, title: item.title, cover: item.cover)) {
                        DramaPosterCard(item: item)
                    }
                    .buttonStyle(PosterButtonStyle())
                    .accessibilityIdentifier("drama.poster.\(item.id)")
                    .gridCardEntrance()
                    .onAppear {
                        if item.id == shelf.items.last?.id { Task { await feed.loadMore(category) } }
                        // 提前取后面三行的封面
                        let next = shelf.items.dropFirst(index + 1).prefix(9).map(\.cover)
                        if !InterfacePreview.active { DramaCoverStore.shared.prefetch(Array(next)) }
                    }
                }
            }
            .padding(.horizontal, Theme.contentInset)

            Group {
                if shelf.loading {
                    ProgressView().tint(Theme.textSecondary)
                } else if !shelf.error.isEmpty {
                    Button("加载失败，点这里重试") { Task { await feed.loadMore(category) } }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                } else if !shelf.hasMore {
                    Text("已经到底了")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private var ranksContent: some View {
        if rankFeed.items.isEmpty {
            Group {
                if !rankFeed.error.isEmpty {
                    EmptyStateView(icon: AppIcon.alert.name, title: "榜单没有加载出来", message: rankFeed.error,
                                   actionTitle: "重新加载") { Task { await rankFeed.reload() } }
                } else if rankFeed.loading || !rankFeed.hasLoaded {
                    ProgressView().tint(Theme.textSecondary)
                } else {
                    EmptyStateView(icon: AppIcon.hot.name, title: "榜单暂时是空的", message: "稍后再来看看。")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 360)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(rankFeed.items.enumerated()), id: \.element.id) { index, item in
                    NavigationLink(value: DramaRoute(id: item.videoId, title: item.title, cover: item.cover)) {
                        DramaRankRow(item: item)
                    }
                    .buttonStyle(PosterButtonStyle())
                    .accessibilityIdentifier("drama.rank.\(item.videoId)")
                    .onAppear {
                        // 提前取后四名的封面
                        let next = rankFeed.items.dropFirst(index + 1).prefix(4).map(\.cover)
                        if !InterfacePreview.active { DramaCoverStore.shared.prefetch(Array(next)) }
                    }
                }
            }
            .padding(.horizontal, Theme.contentInset)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
    }
}

/// 「榜单」一行：名次、封面、片名 / 分类集数 / 热力指数，点进详情（和分类里点海报进的是同一个详情页）。
private struct DramaRankRow: View {
    let item: DramaRankItem

    var body: some View {
        HStack(spacing: 12) {
            Text("\(item.rank)")
                .font(Font.numeral(20))
                .foregroundStyle(item.rank <= 3 ? Theme.rating : Theme.textTertiary)
                .frame(minWidth: 30, alignment: .leading)

            Color.clear
                .frame(width: 64, height: 96)
                .overlay { DramaCover(urlString: item.cover, title: item.title) }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(Theme.Typo.row.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(Theme.Typo.meta)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                if item.metricValue > 0 {
                    HStack(spacing: 4) {
                        Image(appIconNamed: AppIcon.hot.name)
                        Text("\(item.metricLabel) \(compactCount(item.metricValue))")
                            .monospacedDigit()
                    }
                    .font(Theme.Typo.meta)
                    .foregroundStyle(Theme.rating)
                }
            }

            Spacer(minLength: 8)

            Image(appIconNamed: AppIcon.forward.name)
                .font(Theme.Typo.meta.weight(.semibold))
                .foregroundStyle(Theme.textMuted)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第 \(item.rank) 名，\(item.title)" + (item.subtitle.isEmpty ? "" : "，\(item.subtitle)"))
    }
}

private struct DramaPosterCard: View {
    let item: DramaCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay { DramaCover(urlString: item.cover, title: item.title) }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    if !item.statusText.isEmpty {
                        Text(item.statusText)
                            .font(.scaled(10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(Theme.Opacity.strong), in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
                            .padding(6)
                    }
                }
            Text(item.title)
                .font(.scaled(13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Text(item.tags.prefix(2).joined(separator: " · "))
                .font(.scaled(11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
    }
}

// MARK: - 详情

struct DramaDetailView: View {
    let route: DramaRoute
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var recents = RecentStore.shared
    @State private var detail: DramaDetail?
    @State private var loading = true
    @State private var error = ""
    @State private var lastWatched: Int?
    @State private var expanded = false
    /// 竖屏连播播放器（上滑下一集）
    @State private var feed: DramaFeedStart?

    private let episodeColumns = [GridItem(.adaptive(minimum: 56), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let detail {
                    playButton(detail)
                    if !detail.summary.isEmpty { summary(detail) }
                    episodes(detail)
                } else if loading {
                    ProgressView().tint(Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    EmptyStateView(icon: AppIcon.alert.name, title: "详情没有加载出来", message: error,
                                   actionTitle: "重新加载") { Task { await load() } }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .padding(.horizontal, Theme.contentInset)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .designScreen("drama-detail")
        .task { await load() }
        .onChange(of: feed == nil) { closed in
            if closed { lastWatched = DramaEpisodeRef.lastWatched(videoId: route.id) }
        }
        // 竖屏打开；横屏视频在播放器里点「全屏观看」再转横屏
        .playerWindow(item: $feed, landscape: false) { start in
            DramaFeedView(detail: start.detail, startIndex: start.index)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Color.clear
                .frame(width: 112, height: 168)
                .overlay { DramaCover(urlString: detail?.cover ?? route.cover, title: route.title) }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Text(detail?.title ?? route.title)
                    .font(.scaled(20, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(3)
                if let detail {
                    HStack(spacing: 10) {
                        if detail.score > 0 {
                            Label(String(format: "%.1f", detail.score), image: AppIcon.rating.name)
                                .foregroundStyle(Theme.rating)
                        }
                        Text(detail.isFinished ? "全 \(detail.episodes.count) 集" : "更新至 \(detail.episodes.count) 集")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .font(.scaled(13, weight: .semibold))
                    if !detail.author.isEmpty {
                        Text(detail.author)
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    if !detail.tags.isEmpty {
                        Text(detail.tags.prefix(4).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    Circle().fill(Theme.Source.online).frame(width: 6, height: 6)
                    Text("在线短剧")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        }
    }

    private func playButton(_ detail: DramaDetail) -> some View {
        let target = detail.episodes.first { $0.number == lastWatched } ?? detail.episodes.first
        return Button {
            if let target { play(target, in: detail) }
        } label: {
            HStack(spacing: 8) {
                Image(appIconNamed: AppIcon.play.name)
                Text(target == nil ? "暂无可播放的分集" : lastWatched == nil ? "播放第 1 集" : "继续看第 \(target?.number ?? 1) 集")
            }
        }
        .buttonStyle(PrimaryActionStyle())
        .disabled(target == nil)
        .accessibilityIdentifier("drama.play")
    }

    private func summary(_ detail: DramaDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("简介").font(.headline)
            Text(detail.summary)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(expanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
            if detail.summary.count > 70 {
                Button(expanded ? "收起" : "展开") {
                    withAnimation(Motion.smooth) { expanded.toggle() }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accent)
            }
        }
    }

    private func episodes(_ detail: DramaDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("选集").font(.headline)
                Spacer()
                Text("\(detail.episodes.count) 集")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            LazyVGrid(columns: episodeColumns, spacing: 8) {
                ForEach(detail.episodes) { episode in
                    let current = episode.number == lastWatched
                    let progress = recents.progress(for: source(episode, in: detail))
                    Button { play(episode, in: detail) } label: {
                        Text("\(episode.number)")
                            .font(.scaled(14, weight: current ? .bold : .medium).monospacedDigit())
                            .foregroundStyle(current ? Theme.onPrimary : Theme.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(current ? Theme.primaryAction : Theme.surface,
                                        in: RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
                            .overlay(alignment: .bottom) {
                                if let progress, progress > 0.02, !current {
                                    GlassProgressBar(value: progress)
                                        .padding(.horizontal, 8)
                                        .padding(.bottom, 4)
                                }
                            }
                    }
                    .buttonStyle(.pressable(scale: 0.94))
                    .accessibilityLabel("第 \(episode.number) 集")
                    .accessibilityIdentifier("drama.episode.\(episode.number)")
                }
            }
        }
    }

    private func source(_ episode: DramaEpisode, in detail: DramaDetail) -> PlaybackSource {
        .drama(DramaEpisodeRef(videoId: detail.id, seriesName: detail.title, episode: episode.number))
    }

    private func play(_ episode: DramaEpisode, in detail: DramaDetail) {
        Haptics.tap()
        feed = DramaFeedStart(detail: detail, index: detail.episodes.firstIndex(of: episode) ?? 0)
    }

    private func load() async {
        lastWatched = DramaEpisodeRef.lastWatched(videoId: route.id)
        guard detail == nil, !InterfacePreview.active else { loading = false; return }
        loading = true
        error = ""
        do {
            detail = try await DramaClient.shared.detail(id: route.id)
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
        loading = false
    }
}
