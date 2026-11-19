import SwiftUI
import WebKit

struct MissAVRoute: Hashable {
    let id: String
    let title: String
    let cover: String
    var url: String = ""
}

// MARK: - 列表数据缓存

@MainActor
final class MissAVFeed: ObservableObject {
    /// 频道首页的货架和「全部」列表页共用一份
    static let shared = MissAVFeed()

    struct Shelf {
        var items: [MissAVVideoCard] = []
        var page = 0
        var hasMore = true
        var loading = false
        var error = ""
    }

    @Published private(set) var shelves: [MissAVCategory: Shelf] = [:]

    func shelf(_ category: MissAVCategory) -> Shelf { shelves[category] ?? Shelf() }

    /// 第一次打开这个分类：先把上次缓存的第一页摆出来，再去取最新的（取到后整页替换）
    func loadFirstIfNeeded(_ category: MissAVCategory) async {
        guard shelf(category).page == 0 else { return }
        if shelf(category).items.isEmpty,
           let cached = await ChannelListCache.loadWithAgeAsync(Self.cacheKey(category), as: MissAVVideoCard.self) {
            guard shelf(category).page == 0, shelf(category).items.isEmpty else { return }
            var state = Shelf()
            state.items = cached.items
            // 二十分钟内取过的直接当第一页用，不再排队重取；往下翻页时接着取第二页
            if cached.age < ChannelListCache.freshAge { state.page = 1 }
            shelves[category] = state
            if state.page == 1 { return }
        }
        await loadMore(category)
    }

    /// 频道首页下拉刷新：已经打开过的分类都重新取第一页
    func reloadLoaded() async {
        let loaded = shelves.keys.filter { !shelf($0).items.isEmpty || shelf($0).page > 0 || !shelf($0).error.isEmpty }
        for category in MissAVCategory.allCases where loaded.contains(category) {
            await reload(category)
        }
    }

    /// 下拉刷新：列表先留着，取到新的第一页再整页替换，不会先清空成转圈
    func reload(_ category: MissAVCategory) async {
        var state = shelf(category)
        state.page = 0
        state.hasMore = true
        state.error = ""
        shelves[category] = state
        await loadMore(category)
    }

    private static func cacheKey(_ category: MissAVCategory) -> String { "missav." + category.rawValue }

    func loadMore(_ category: MissAVCategory) async {
        var state = shelf(category)
        guard !state.loading, state.hasMore, !InterfacePreview.active else { return }
        state.loading = true
        state.error = ""
        shelves[category] = state

        do {
            let nextPage = state.page + 1
            let fresh = try await MissAVClient.shared.list(category: category, page: nextPage)
            var updated = shelf(category)
            if nextPage == 1 {
                // 第一页：整页替换（顶掉缓存里旧的那一页），并存成新的缓存
                updated.items = fresh
                updated.page = 1
                updated.hasMore = !fresh.isEmpty
                updated.loading = false
                shelves[category] = updated
                ChannelListCache.saveAsync(fresh, key: Self.cacheKey(category))
                return
            }
            let known = Set(updated.items.map(\.id))
            let filtered = fresh.filter { !known.contains($0.id) }
            updated.items += filtered
            updated.page = nextPage
            updated.hasMore = !filtered.isEmpty
            updated.loading = false
            shelves[category] = updated
        } catch {
            var updated = shelf(category)
            updated.loading = false
            if !(error is CancellationError) {
                updated.error = error.localizedDescription
            }
            shelves[category] = updated
        }
    }
}

// MARK: - 视频卡片

struct MissAVPosterCard: View {
    let item: MissAVVideoCard

    private var hasChineseSubtitle: Bool {
        let lower = item.title.lowercased()
        return lower.contains("-c") || lower.contains("中文字幕") || lower.contains("中字")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        if let url = URL(string: item.coverUrl) {
                            PipelineImage(url: url, maxPixel: ArtworkSize.card) { phase in
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
                                        .overlay {
                                            Image(appIconNamed: AppIcon.video.name)
                                                .foregroundStyle(Theme.textTertiary)
                                        }
                                }
                            }
                        } else {
                            Rectangle()
                                .fill(Theme.surfaceRaised)
                                .overlay {
                                    Image(appIconNamed: AppIcon.video.name)
                                        .foregroundStyle(Theme.textTertiary)
                                }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

                // 中字角标
                if hasChineseSubtitle {
                    VStack {
                        HStack {
                            Text("中字")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.onPrimary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.prismGradient, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .padding(5)
                            Spacer()
                        }
                        Spacer()
                    }
                }

                // 时长角标
                if !item.duration.isEmpty {
                    // 角标底是深色半透明，字固定用白色：以前用主文字色，浅色模式下是深灰，压在深色底上看不清
                    Text(item.duration)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(5)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if !item.views.isEmpty {
                    Text(item.views)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - MissAV 频道主页面

/// 某个分类的完整列表（两列网格，滑到底自动翻页）。从频道首页的快捷入口、货架「全部」推进来。
struct MissAVBrowseRoute: Hashable {
    let category: MissAVCategory
}

/// MissAV 频道首页：和动漫频道一样，顶部是今日热门轮播（铺氛围层），下面一排快捷入口，再往下每个分类一排横滑货架，
/// 货架右边「全部」进这个分类的完整列表。列表都先显示本地缓存，只有前两排一进来就取，其余滑到才取。
struct MissAVTab: View {
    @ObservedObject private var feed = MissAVFeed.shared
    @Environment(\.channelPageInsets) private var insets

    /// 轮播用的分类
    private static let heroCategory: MissAVCategory = .todayHot
    /// 一进来就取的分类（轮播 + 第一排货架），其余货架滑到可见时再取
    private static let eagerCategories: [MissAVCategory] = [.todayHot, .new]

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    AmbientHeroSection(slides: HomeSlide.missav(feed.shelf(Self.heroCategory).items), reservesCarousel: true,
                                       carouselLabel: "今日热门轮播", carouselIdentifier: "missav.bannerPosition",
                                       safeTop: insets.top, width: proxy.size.width) {
                        EmptyView()
                    } hitArea: { slide in
                        bannerHitArea(slide)
                    }

                    shortcuts
                        .padding(.top, 16)

                    shelves(width: proxy.size.width)
                }
                .tracksPageScroll()
            }
            .pageScrollContainer()
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .refreshable { await feed.reloadLoaded() }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .designScreen("missav")
        .task {
            for category in Self.eagerCategories {
                await feed.loadFirstIfNeeded(category)
            }
        }
        // 安全验证由 MissAVClient 自己弹在最上层，这里不再绑 sheet
    }

    // MARK: 轮播与快捷入口

    /// 点轮播进视频详情
    @ViewBuilder
    private func bannerHitArea(_ slide: HomeSlide) -> some View {
        if case .missav(let item) = slide.content {
            NavigationLink(value: MissAVRoute(id: item.id, title: item.title, cover: item.coverUrl, url: item.url)) {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.title)
            .accessibilityIdentifier("missav.banner.\(item.id)")
        }
    }

    private var shortcuts: some View {
        HStack(spacing: 4) {
            shortcut(.todayHot, title: "今日热门",
                     icon: .hot)
            shortcut(.new, title: "新片",
                     icon: .sparkles)
            shortcut(.chineseSubtitle, title: "中字",
                     icon: .subtitle)
            shortcut(.uncensoredLeak, title: "无码",
                     icon: .unlock)
        }
        .padding(.horizontal, 10)
    }

    private func shortcut(_ category: MissAVCategory, title: String, icon: AppIcon) -> some View {
        NavigationLink(value: MissAVBrowseRoute(category: category)) {
            ChannelShortcutLabel(title: title, icon: icon)
        }
        .buttonStyle(.pressable(scale: 0.92))
        .accessibilityIdentifier("missav.shortcut.\(category.id)")
    }

    // MARK: 货架

    private func shelves(width: CGFloat) -> some View {
        // 16:9 卡片：一屏露出一张多，看得出能往右滑
        let cardWidth = min(260, ((width - Theme.contentInset - 24) / 1.7).rounded(.down))
        // 懒加载：滑到才建这一排，没滑到的分类不会排队去取网页
        return LazyVStack(alignment: .leading, spacing: Theme.Space.shelf) {
            ForEach(MissAVCategory.allCases) { category in
                shelf(category, cardWidth: cardWidth)
            }
        }
        .padding(.horizontal, Theme.contentInset)
        .padding(.top, 20)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 单个分类的货架：还没取过就在滑到时取；取失败给出重试入口
    @ViewBuilder
    private func shelf(_ category: MissAVCategory, cardWidth: CGFloat) -> some View {
        let state = feed.shelf(category)
        let identifier = "missav.shelf.\(category.id)"
        if !state.items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                shelfHeader(category, identifier: identifier)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        let visible = Array(state.items.prefix(12))
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                            NavigationLink(value: MissAVRoute(id: item.id, title: item.title, cover: item.coverUrl, url: item.url)) {
                                MissAVPosterCard(item: item)
                                    .frame(width: cardWidth)
                            }
                            .buttonStyle(PosterButtonStyle())
                            .accessibilityIdentifier("missav.poster.\(item.id)")
                            .reveal(index, id: "\(identifier).\(item.id)")
                            .shelfCard()
                            .prefetchArtwork(after: index, in: visible, count: 4, maxPixel: ArtworkSize.card) { $0.coverUrl }
                        }
                    }
                    .shelfContent()
                    .padding(.vertical, 4)
                }
                .shelfScrolling()
                .padding(.horizontal, -Theme.contentInset)
                .scrollIndicators(.hidden)
            }
        } else if !state.error.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                shelfHeader(category, identifier: identifier)
                Button {
                    Task { await feed.reload(category) }
                } label: {
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
        } else if state.loading || state.page > 0 {
            if state.page > 0 {
                // 取到了但这个分类是空的：不占版面
                EmptyView()
            } else {
                shelfSkeleton(category, cardWidth: cardWidth)
            }
        } else {
            shelfSkeleton(category, cardWidth: cardWidth)
                .onAppear { Task { await feed.loadFirstIfNeeded(category) } }
        }
    }

    private func shelfHeader(_ category: MissAVCategory, identifier: String) -> some View {
        ShelfHeader(title: category.title, identifier: identifier, inset: 0) {
            NavigationLink(value: MissAVBrowseRoute(category: category)) {
                ShelfLinkLabel(text: "全部")
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
            }
            .buttonStyle(.pressable(scale: 0.92))
            .accessibilityIdentifier("\(identifier).all")
        }
    }

    private func shelfSkeleton(_ category: MissAVCategory, cardWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ShelfHeader(title: category.title, inset: 0) { EmptyView() }
                .frame(minHeight: 44, alignment: .leading)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(0..<3, id: \.self) { _ in
                        ClipCardSkeleton(width: cardWidth)
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

// MARK: - MissAV 分类列表页

struct MissAVBrowseView: View {
    let route: MissAVBrowseRoute
    @ObservedObject private var feed = MissAVFeed.shared

    private let columns = [
        GridItem(.flexible(), spacing: 12, alignment: .top),
        GridItem(.flexible(), spacing: 12, alignment: .top)
    ]

    private var category: MissAVCategory { route.category }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.top, 12)
        }
        .scrollIndicators(.hidden)
        .refreshable { await feed.reload(category) }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .designScreen("missav-browse")
        .task { await feed.loadFirstIfNeeded(category) }
    }

    @ViewBuilder
    private var content: some View {
        let shelf = feed.shelf(category)
        if shelf.items.isEmpty {
            Group {
                if !shelf.error.isEmpty {
                    EmptyStateView(
                        icon: AppIcon.alert.name,
                        title: "视频列表加载失败",
                        message: shelf.error,
                        actionTitle: "重新加载"
                    ) {
                        Task { await feed.reload(category) }
                    }
                } else if shelf.loading || shelf.page == 0 {
                    ProgressView()
                        .tint(Theme.textSecondary)
                } else {
                    EmptyStateView(
                        icon: AppIcon.video.name,
                        title: "暂无内容",
                        message: "当前分类暂无视频，稍后再来看看。"
                    )
                }
            }
            .frame(maxWidth: .infinity, minHeight: 360)
        } else {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(Array(shelf.items.enumerated()), id: \.element.id) { index, item in
                    NavigationLink(value: MissAVRoute(id: item.id, title: item.title, cover: item.coverUrl, url: item.url)) {
                        MissAVPosterCard(item: item)
                    }
                    .buttonStyle(PosterButtonStyle())
                    .accessibilityIdentifier("missav.poster.\(item.id)")
                    .gridCardEntrance()
                    .onAppear {
                        if index >= shelf.items.count - 4 {
                            Task { await feed.loadMore(category) }
                        }
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
}

// MARK: - MissAV 视频详情页

struct MissAVDetailView: View {
    let route: MissAVRoute
    @ObservedObject private var recents = RecentStore.shared

    @State private var detail: MissAVVideoDetail?
    @State private var loading = true
    @State private var error = ""
    @State private var playingQueue: PlaybackQueue?

    private let columns = [
        GridItem(.flexible(), spacing: 12, alignment: .top),
        GridItem(.flexible(), spacing: 12, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                previewHero
                infoSection
                if let detail, !detail.related.isEmpty {
                    relatedSection(detail.related)
                }
            }
            .padding(.horizontal, Theme.contentInset)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle(route.id.uppercased())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .designScreen("missav-detail")
        .task { await load() }
        .playerWindow(item: $playingQueue) { queue in
            PlayerView(source: queue.source, playlist: queue.items)
        }
    }

    private var previewHero: some View {
        Button {
            play()
        } label: {
            ZStack {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        let coverUrlString = detail?.coverUrl.isEmpty == false ? detail!.coverUrl : route.cover
                        if let url = URL(string: coverUrlString) {
                            PipelineImage(url: url, maxPixel: ArtworkSize.hero) { phase in
                                switch phase {
                                case let .loaded(image):
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                case .loading, .failed:
                                    Rectangle().fill(Theme.surfaceRaised)
                                }
                            }
                        } else {
                            Rectangle().fill(Theme.surfaceRaised)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

                // 播放遮罩与图标
                Circle()
                    .fill(Color.black.opacity(0.6))
                    .frame(width: 56, height: 56)
                    .overlay {
                        Image(appIconNamed: AppIcon.play.name)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .offset(x: 2)
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("立即播放")
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(detail?.title.isEmpty == false ? detail!.title : route.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // 番号与复制
            HStack(spacing: 10) {
                Text(route.id.uppercased())
                    .font(.subheadline.weight(.semibold).monospaced())
                    .foregroundStyle(Theme.accent)

                // 统一的复制反馈（HUD.swift）
                CopyCodeChip(code: route.id.uppercased())

                Spacer()
            }

            // 播放按钮
            Button {
                play()
            } label: {
                HStack(spacing: 8) {
                    Image(appIconNamed: AppIcon.play.name)
                    Text("立即播放")
                }
            }
            .buttonStyle(PrimaryActionStyle())
            .accessibilityIdentifier("missav.play")

            // 女优/演员
            if let detail, !detail.models.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("出演女优")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(detail.models, id: \.self) { model in
                                Text(model)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.textPrimary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Theme.surface, in: Capsule())
                            }
                        }
                    }
                }
            }

            // 标签
            if let detail, !detail.tags.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("相关标签")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)

                    MissAVFlowLayout(spacing: 8) {
                        ForEach(detail.tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                    }
                }
            }

            if loading {
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.textSecondary)
                    Text("正在获取视频播放流及详细信息…")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 8)
            } else if !error.isEmpty {
                EmptyStateView(
                    icon: AppIcon.alert.name,
                    title: "详情加载失败",
                    message: error,
                    actionTitle: "重新加载"
                ) {
                    Task { await load() }
                }
            }
        }
    }

    private func relatedSection(_ related: [MissAVVideoCard]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("相关推荐")
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 8)

            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(related) { item in
                    NavigationLink(value: MissAVRoute(id: item.id, title: item.title, cover: item.coverUrl, url: item.url)) {
                        MissAVPosterCard(item: item)
                    }
                    .buttonStyle(PosterButtonStyle())
                }
            }
        }
    }

    private func play() {
        Haptics.tap()
        let ref = MissAVVideoRef(videoId: route.id, title: detail?.title.isEmpty == false ? detail!.title : route.title, coverUrl: detail?.coverUrl.isEmpty == false ? detail!.coverUrl : route.cover)
        let source = PlaybackSource.missav(ref)
        playingQueue = PlaybackQueue(source: source, items: [source])
    }

    private func load() async {
        guard detail == nil, !InterfacePreview.active else { loading = false; return }
        loading = true
        error = ""
        do {
            detail = try await MissAVClient.shared.detail(videoId: route.id, pageUrl: route.url)
        } catch {
            if !(error is CancellationError) {
                self.error = error.localizedDescription
            }
        }
        loading = false
    }
}

// MARK: - 流式标签布局

private struct MissAVFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var maxHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width, currentX > 0 {
                currentX = 0
                currentY += maxHeight + spacing
                maxHeight = 0
            }
            maxHeight = max(maxHeight, size.height)
            currentX += size.width + spacing
            widest = max(widest, currentX - spacing)
        }

        return CGSize(width: proposal.width ?? widest, height: currentY + maxHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var maxHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX, currentX > bounds.minX {
                currentX = bounds.minX
                currentY += maxHeight + spacing
                maxHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
            maxHeight = max(maxHeight, size.height)
            currentX += size.width + spacing
        }
    }
}
