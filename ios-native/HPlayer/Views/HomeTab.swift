import SwiftUI
import Pow
import UniformTypeIdentifiers

struct HomeTab: View {
    var onBrowseLibrary: () -> Void = {}
    var onSearch: () -> Void = {}
    var onOpenCatalog: (CatalogKind, CatalogSort) -> Void = { _, _ in }
    /// 首页频道（推荐 / 片库 / 动漫）；这一页本身是「推荐」。
    var channel: Binding<HomeChannel> = .constant(.recommend)
    /// 顶部头部的「添加」按钮在频道容器里；按一次这个数就加一，这里打开添加面板
    var addRequest = 0
    /// 内容从哪里开始（顶部头部盖在上面）
    @Environment(\.channelPageInsets) private var insets
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 系统（或「外观」设置）的深浅色。首页内容强制按深色显示，从首页推出去的页面要恢复成这个。
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var recents: RecentStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mediaLibrary: MediaLibraryStore
    @EnvironmentObject private var localStore: LocalMediaStore
    @EnvironmentObject private var metadataStore: MediaMetadataStore
    @EnvironmentObject private var scanner: CloudLibraryScanner
    @ObservedObject private var magnetHistory = MagnetHistoryStore.shared
    /// 2.0：首页融合在线内容——我的追番、热门新番、最新更新
    @ObservedObject private var watchlist = AnimeWatchlistStore.shared
    @ObservedObject private var online = HomeOnlineFeed.shared

    @State private var showAdd = false
    @State private var addAction: AddMediaAction?
    @State private var actionItem: HomeMediaItem?
    @State private var pendingPlayback: PlaybackQueue?
    @State private var pendingMatch: HomeMediaItem?
    @State private var showImporter = false
    @State private var playing: PlaybackQueue?
    @State private var importError = ""
    @State private var playError = ""
    @State private var showCloudBrowser = false
    @State private var matching: MatchRequest?
    @State private var magnetLaunch: MagnetLaunch?
    /// 首页和片库共用的分组结果：HomeView 在后台算好（先等封面缓存恢复完，第一屏直接带封面），
    /// 匹配、扫描期间界面不会被整页重算拖住。见 LibrarySnapshotStore。
    @EnvironmentObject private var librarySnapshots: LibrarySnapshotStore
    private var snapshot: HomeSnapshot { librarySnapshots.home }
    /// 第一份首页分组算好之前不显示内容（也不先闪空状态），算好后淡入。
    private var snapshotReady: Bool { librarySnapshots.ready }

    /// 轮播每一张的大图和货架开头的海报提前下载好，滑到时直接有图（取色由 ChannelHeroSection 自己算）。
    private func prefetchArtwork(_ library: HomeSnapshot) {
        var requests = HomeArtwork.prefetchRequests(library)
        for banner in online.banners {
            if let url = URL(string: banner.safePicURLString) {
                requests.append(ImageRequest(url: url, maxPixel: ArtworkSize.hero))
            }
        }
        ImagePipeline.shared.prefetch(requests)
    }


    private var libraryFiles: [LibraryMedia] {
        HomeLibrary.media(local: localStore, cloud: mediaLibrary, appState: appState)
    }

    var body: some View {
        let library = snapshot
        let continueItems = continueEntries(library)

        Group {
            GeometryReader { viewport in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !snapshotReady || metadataStore.isRestoring {
                            // 数据还在准备：只留空白页面底色，不显示空状态
                            Color.clear.frame(height: viewport.size.height)
                        } else {
                            let slides = HomeSlide.interleave(featured: library.featured, banners: online.banners)
                            header(library, slides: slides, continueItems: continueItems,
                                   width: viewport.size.width, safeTop: insets.top)
                            sections(library, continueItems: continueItems, width: viewport.size.width)
                        }
                    }
                    .tracksPageScroll()
                }
                .pageScrollContainer()
                .scrollIndicators(.hidden)
                .ignoresSafeArea(edges: .top)
            }
            .overlay(alignment: .bottom) {
                if localStore.isImporting {
                    ProgressView("正在导入视频…").font(.subheadline)
                        .padding(16).background(Theme.surface, in: Capsule()).padding(.bottom, 12)
                }
            }
            .background(Theme.pageBackground.ignoresSafeArea())
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .data],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task { importError = await localStore.importFiles(urls).joined(separator: "\n") }
                case .failure(let error):
                    importError = error.localizedDescription
                }
            }
            .alert("导入失败", isPresented: Binding(
                get: { !importError.isEmpty },
                set: { if !$0 { importError = "" } }
            )) {
                Button("好", role: .cancel) { importError = "" }
            } message: {
                Text(importError)
            }
            .alert("无法播放", isPresented: Binding(
                get: { !playError.isEmpty },
                set: { if !$0 { playError = "" } }
            )) {
                Button("好", role: .cancel) { playError = "" }
            } message: {
                Text(playError)
            }
            .task { localStore.refresh() }
            .task { await online.loadIfNeeded() }
            .onChange(of: librarySnapshots.revision) { _ in prefetchArtwork(snapshot) }
            .onChange(of: online.banners.count) { _ in prefetchArtwork(snapshot) }
            .onAppear { if snapshotReady { prefetchArtwork(snapshot) } }
            .onChange(of: addRequest) { _ in showAdd = true }
        }
        .designScreen(library.featured.isEmpty ? "home-empty" : "home")
        .sheet(isPresented: $showAdd, onDismiss: performAddAction) {
            AddMediaSheet { action in addAction = action; showAdd = false }
                .presentationDetents([.height(460)])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $actionItem, onDismiss: {
            if let queue = pendingPlayback { pendingPlayback = nil; playing = queue }
            else if let item = pendingMatch { pendingMatch = nil; matching = MatchRequest(item: item) }
        }) { item in
            MediaActionSheet(item: item, position: recents.position(for: item.media.source), onPlay: {
                pendingPlayback = HomeLibrary.queue(for: item, in: snapshot.items); actionItem = nil
            }, onMatch: { pendingMatch = item; actionItem = nil }, onRemove: { delete(item); actionItem = nil },
            onHideFeatured: canHideFromFeatured(item) ? {
                if let id = item.metadata?.imdbID { FeaturedStore.shared.hide(id) }
                actionItem = nil
            } : nil)
            .presentationDetents([.height(canHideFromFeatured(item) ? 664 : 590)])
            .presentationDragIndicator(.visible)
        }
        .playerWindow(item: $playing) { queue in
            PlayerView(source: queue.source, playlist: queue.items)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showCloudBrowser) {
            HomeCloudBrowser()
                .environmentObject(appState)
                .environmentObject(mediaLibrary)
        }
        .sheet(item: $matching) { request in
            MetadataMatchView(file: request.file, current: request.current, onMatch: { metadata in
                for target in request.targets {
                    await metadataStore.match(metadata, to: target)
                }
            }, onClear: request.current == nil ? nil : { () async -> Void in
                for target in request.targets {
                    await metadataStore.unmatch(target)
                }
            })
        }
        .sheet(item: $magnetLaunch) { launch in
            NavigationStack {
                MagnetPlayerView(initialMagnet: launch.value)
                    .toolbar {
                        if launch.value.isEmpty {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("关闭") { magnetLaunch = nil }
                            }
                        }
                    }
            }
            .environmentObject(appState)
        }
    }

    // MARK: 顶栏、搜索、轮播

    /// 页面顶部：轮播（片库精选和热播动漫交替）。频道条、搜索框在频道容器的固定头部里，这里只留出它们的位置。
    private func header(_ library: HomeSnapshot, slides: [HomeSlide], continueItems: [ContinueEntry],
                        width: CGFloat, safeTop: CGFloat) -> some View {
        AmbientHeroSection(slides: slides, carouselLabel: "精选推荐", carouselIdentifier: "home.carouselPosition",
                           safeTop: safeTop, width: width) {
            EmptyView()
        } hitArea: { slide in
            slideHitArea(slide, library: library)
        }
    }

    /// 点卡片：片库精选直接播放，热播动漫进详情。长按片库精选弹出菜单：播放、匹配封面、不在精选中显示、更多选项。
    @ViewBuilder
    private func slideHitArea(_ slide: HomeSlide, library: HomeSnapshot) -> some View {
        switch slide.content {
        case .library(let item):
            Button {
                playing = HomeLibrary.queue(for: item, in: library.items)
            } label: {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(recents.position(for: item.media.source) == nil ? "播放" : "继续播放") \(item.title)")
            .accessibilityIdentifier("home.heroPlay")
            .contextMenu {
                Button("播放", systemImage: AppIcon.play.name) {
                    playing = HomeLibrary.queue(for: item, in: library.items)
                }
                Button("匹配封面", systemImage: AppIcon.poster.name) {
                    afterMenu { matching = MatchRequest(item: item) }
                }
                if canHideFromFeatured(item) {
                    Button("不在精选中显示", systemImage: AppIcon.hidden.name) {
                        if let id = item.metadata?.imdbID { FeaturedStore.shared.hide(id) }
                    }
                }
                Button("更多选项", systemImage: AppIcon.more.name) {
                    afterMenu { actionItem = item }
                }
            } preview: {
                HomeSlidePreview(slide: slide)
            }
        case .anime(let banner):
            NavigationLink(value: AnimeDetailRoute(animeId: banner.vid ?? banner.id)) {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(banner.displayTitle)
            .accessibilityIdentifier("home.slide.anime.\(banner.vid ?? banner.id)")
        case .magnet:
            EmptyView()
        }
    }

    /// 长按菜单收起的动画走完再弹页面，免得两个转场撞在一起弹不出来。
    private func afterMenu(_ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: action)
    }

    /// 这部正在精选里、而且不是精选里的最后一部，才给「不在精选中显示」（精选至少留一部）
    private func canHideFromFeatured(_ item: HomeMediaItem) -> Bool {
        guard let id = item.metadata?.imdbID, snapshot.featured.count > 1 else { return false }
        return snapshot.featured.contains { $0.metadata?.imdbID == id }
    }

    private func performAddAction() {
        defer { addAction = nil }
        switch addAction {
        case .local:
            if localStore.isImporting { importError = "已有视频正在导入，请稍后再试。" }
            else { showImporter = true }
        case .cloud: showCloudBrowser = true
        case .magnet: magnetLaunch = MagnetLaunch(value: "")
        case nil: break
        }
    }

    // MARK: 内容区

    /// 内容区从上到下：继续观看、我的追番、热门新番（三列竖海报）、我的片库·电影（两列横卡）、剧集、最新更新、演员合集。
    /// 片库还什么都没有时，在轮播下面放引导。
    private func sections(_ library: HomeSnapshot, continueItems: [ContinueEntry], width: CGFloat) -> some View {
        let contentWidth = max(width - Theme.contentInset * 2, 1)
        return VStack(alignment: .leading, spacing: Theme.Space.shelf) {
            if library.items.isEmpty {
                emptyState
            }
            if !continueItems.isEmpty {
                continueShelf(continueItems)
            }
            watchlistShelf
            if !online.trending.isEmpty {
                trendingGrid(width: contentWidth)
            }
            if !library.movies.isEmpty {
                movieGrid(library, width: contentWidth)
            }
            if !library.series.isEmpty {
                seriesShelf(library)
            }
            if !online.latest.isEmpty {
                animeShelf("最新更新", items: online.latest, identifier: "home.shelf.latest")
            }
            if !library.performers.isEmpty {
                performerShelf(library)
            }
        }
        .padding(.horizontal, Theme.contentInset)
        .padding(.top, 18)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 货架标题：左边标题，右边「数量 · 全部 ›」。标题行本身不带左右边距，由外层统一留白。
    private func shelfHeader<Destination: View>(
        _ title: String,
        detail: String,
        identifier: String = "",
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        ShelfHeader(title: title, identifier: identifier, inset: 0) {
            HStack(spacing: 10) {
                Text(detail)
                    .font(.scaled(12))
                    .tertiaryTextStyle()
                NavigationLink {
                    destination()
                        .restoringAppearance(colorScheme)
                } label: {
                    ShelfLinkLabel(text: "全部")
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                }
                .buttonStyle(.pressable(scale: 0.92))
            }
        }
    }

    /// 同上，但用值导航：目的页由 NavigationStack 统一解析。
    private func shelfHeader<Value: Hashable>(
        _ title: String,
        detail: String,
        identifier: String = "",
        value: Value
    ) -> some View {
        ShelfHeader(title: title, identifier: identifier, inset: 0) {
            HStack(spacing: 10) {
                Text(detail)
                    .font(.scaled(12))
                    .tertiaryTextStyle()
                NavigationLink(value: value) {
                    ShelfLinkLabel(text: "全部")
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                }
                .buttonStyle(.pressable(scale: 0.92))
            }
        }
    }

    // MARK: 继续观看

    private func continueShelf(_ entries: [ContinueEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            shelfHeader("继续观看", detail: "\(entries.count)", identifier: "home.shelf.continue") {
                ContinueHistoryView(entries: entries, onOpen: openEntry, onRemove: remove)
            }

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(entries.prefix(12).enumerated()), id: \.element.id) { index, entry in
                        Button {
                            openEntry(entry)
                        } label: {
                            ContinueCard(entry: entry, width: 168)
                        }
                        .buttonStyle(PosterButtonStyle())
                        .reveal(index, id: entry.id)
                        .shelfCard()
                        .contextMenu {
                            Button("从继续观看移除", systemImage: AppIcon.remove.name, role: .destructive) {
                                remove(entry)
                            }
                        }
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

    /// 普通播放记录和磁力记录合在一起，按时间倒序
    private func continueEntries(_ library: HomeSnapshot) -> [ContinueEntry] {
        let byID = Dictionary(library.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localByName = Dictionary(
            library.items.filter { !$0.isCloud }.map { ($0.media.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var entries: [ContinueEntry] = []

        for recent in recents.items {
            let match: HomeMediaItem?
            if let pickCode = recent.pickCode, !pickCode.isEmpty {
                match = byID["115|\(pickCode)"]
            } else if recent.isLocalFile, let url = URL(string: recent.url) {
                match = localByName[url.lastPathComponent]
            } else {
                match = nil
            }
            let parsed = MediaNameParser.parse(recent.title).title
            let sourceLabel = recent.isDrama ? "在线短剧" : recent.isAnime ? "在线动漫" : (recent.isCloud ? "115 网盘" : (recent.isLocalFile ? "本地视频" : "网络地址"))
            var detail: [String] = [sourceLabel]
            if let episode = match?.episodeLabel { detail.append(episode) }
            if let position = recent.position {
                detail.append("看到 \(playbackTimeText(position))")
            } else {
                detail.append(recent.playedAt.formatted(.relative(presentation: .named)))
            }
            let artwork: String
            if let match {
                artwork = match.backgroundURL.isEmpty ? match.posterURL : match.backgroundURL
            } else {
                artwork = ""
            }
            let tagLabel = recent.isDrama ? "短剧" : recent.isAnime ? "动漫" : (recent.isCloud ? "115" : (recent.isLocalFile ? "本地" : "网络"))
            entries.append(ContinueEntry(
                id: "recent|\(recent.id)",
                target: .recent(recent),
                title: match?.title ?? (parsed.isEmpty ? recent.title : parsed),
                subtitle: detail.joined(separator: " · "),
                tag: tagLabel,
                artworkURL: artwork,
                progress: recent.progress,
                date: recent.playedAt,
                libraryItem: match
            ))
        }

        for item in magnetHistory.items {
            let progress = item.lastProgress
            var detail: [String] = ["磁力"]
            if let title = item.lastFileTitle, item.videoCount > 1 { detail.append(title) }
            if let progress {
                detail.append("看到 \(playbackTimeText(progress.seconds))")
            } else {
                detail.append(item.updatedAt.formatted(.relative(presentation: .named)))
            }
            let parsed = MediaNameParser.parse(item.name).title
            entries.append(ContinueEntry(
                id: "magnet|\(item.infoHash)",
                target: .magnet(item),
                title: parsed.isEmpty ? item.name : parsed,
                subtitle: detail.joined(separator: " · "),
                tag: "磁力",
                artworkURL: "",
                progress: progress?.fraction,
                date: item.updatedAt,
                libraryItem: nil
            ))
        }

        return entries.sorted { $0.date > $1.date }
    }

    private func openEntry(_ entry: ContinueEntry) {
        switch entry.target {
        case .recent(let recent):
            if let item = entry.libraryItem {
                let items = HomeLibrary.items(libraryFiles, metadata: metadataStore.metadataByMediaID)
                playing = HomeLibrary.queue(for: item, in: items)
            } else if let source = recents.source(for: recent, localDirectory: localStore.mediaDirectory) {
                playing = PlaybackQueue(source: source, items: [source])
            } else {
                playError = "找不到这个视频，可能已经被删除。"
            }
        case .magnet(let item):
            magnetLaunch = MagnetLaunch(value: item.magnet)
        }
    }

    private func remove(_ entry: ContinueEntry) {
        switch entry.target {
        case .recent(let recent):
            recents.remove(recent)
        case .magnet(let item):
            magnetHistory.remove(item.infoHash)
        }
    }

    // MARK: 在线内容（追番、热门新番、最新更新）

    @ViewBuilder
    private var watchlistShelf: some View {
        if !watchlist.items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                let updates = watchlist.items.filter(\.hasUpdate).count
                ShelfHeader(title: "我的追番", identifier: "home.shelf.watchlist", inset: 0) {
                    Text(updates > 0 ? "\(updates) 部有更新" : "\(watchlist.items.count) 部")
                        .font(.scaled(12))
                        .tertiaryTextStyle()
                }
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(Array(watchlist.items.enumerated()), id: \.element.id) { index, item in
                            AnimeDetailLink(animeId: item.id) { watchCard(item) }
                                .reveal(index, id: "watch.\(item.id)")
                                .shelfCard()
                                .prefetchArtwork(after: index, in: watchlist.items, count: 4) { $0.pic ?? "" }
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
    }

    /// 热门新番：最多播放的前六部，三列竖版海报。「更多」去动漫频道。
    private func trendingGrid(width: CGFloat) -> some View {
        let spacing: CGFloat = 10
        let cardWidth = ((width - spacing * 2) / 3).rounded(.down)
        let items = Array(online.trending.prefix(6))
        return VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: "热门新番", identifier: "home.shelf.trending", inset: 0) {
                // 「更多」推进完整的热门列表（按播放量），不跳到动漫频道
                NavigationLink(value: AnimeBrowseRoute(channelId: nil, title: "热门新番", sort: "hits")) {
                    ShelfLinkLabel(text: "全部")
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                }
                .buttonStyle(.pressable(scale: 0.92))
                .accessibilityIdentifier("home.trending.all")
            }
            // 只有几张：直接排成固定的行，不用懒加载网格（懒加载在屏幕外不建视图，滚到之前找不到这些卡片）
            FixedGrid(items: items, columns: 3, spacing: spacing) { index, item in
                HomeAnimeGridCard(item: item, rank: index + 1, width: cardWidth)
                    .reveal(index)
            }
            .onAppear {
                let urls = items.compactMap { URL(string: $0.safePicURLString) }
                ImagePipeline.shared.prefetch(urls.map { ImageRequest(url: $0, maxPixel: ArtworkSize.poster) })
            }
        }
    }

    private func watchCard(_ item: AnimeWatchItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterArtwork(urlString: item.pic ?? "", title: item.name, width: 108)
                .allowsHitTesting(false)
                .overlay(alignment: .bottomTrailing) {
                    if item.hasUpdate {
                        TagBadge(text: "更新", style: .accent)
                            .padding(Theme.Space.sm)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.scaled(13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(item.lastContinu ?? "在线动漫")
                    .font(.scaled(11))
                    .tertiaryTextStyle()
                    .lineLimit(1)
            }
            .frame(width: 108, alignment: .leading)
        }
        .frame(width: 108, alignment: .top)
    }

    private func animeShelf(_ title: String, items: [AnimeVideoItem], identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ShelfHeader(title: title, identifier: identifier, inset: 0) {
                NavigationLink(value: AnimeBrowseRoute(channelId: nil, title: title, sort: "addtime")) {
                    ShelfLinkLabel(text: "全部")
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                }
                .buttonStyle(.pressable(scale: 0.92))
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        AnimeDetailLink(animeId: item.id) { AnimePosterCard(item: item, width: 108) }
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

    // MARK: 电影与剧集

    /// 我的片库 · 电影：两列横卡，先放四部；「全部」进完整的海报墙。
    private func movieGrid(_ library: HomeSnapshot, width: CGFloat) -> some View {
        let spacing: CGFloat = 10
        let cardWidth = ((width - spacing) / 2).rounded(.down)
        let items = Array(library.movies.prefix(4))
        return VStack(alignment: .leading, spacing: 10) {
            shelfHeader("我的片库 · 电影", detail: "\(library.movies.count) 部", identifier: "home.shelf.movies") {
                PosterGridScreen(title: "电影", items: library.movies) { item, width in
                    posterCard(item, library: library, width: width)
                }
            }
            FixedGrid(items: items, columns: 2, spacing: spacing) { index, item in
                LibraryWideCard(item: item, width: cardWidth) {
                    playing = HomeLibrary.queue(for: item, in: library.items)
                } onDelete: {
                    delete(item)
                } onMatch: {
                    matching = MatchRequest(item: item)
                }
                .reveal(index)
            }
        }
    }

    private func posterCard(_ item: HomeMediaItem, library: HomeSnapshot, width: CGFloat) -> some View {
        PosterCard(item: item, width: width) {
            playing = HomeLibrary.queue(for: item, in: library.items)
        } onDelete: {
            delete(item)
        } onMatch: {
            matching = MatchRequest(item: item)
        }
    }

    private func performerShelf(_ library: HomeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            shelfHeader("演员合集", detail: "\(library.performers.count) 位", identifier: "home.shelf.performers",
                        value: PerformerListRoute())
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(library.performers.enumerated()), id: \.element.id) { index, group in
                        performerLink(group, width: 200)
                            .reveal(index, id: group.id)
                            .shelfCard()
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

    private func performerLink(_ group: PerformerGroup, width: CGFloat) -> some View {
        PerformerNavigationLink(group: group) {
            PerformerCollageCard(group: group, width: width)
        }
        .accessibilityIdentifier("home.performer.\(group.id)")
        .buttonStyle(PosterButtonStyle())
    }

    private func seriesShelf(_ library: HomeSnapshot) -> some View {
        let episodeCount = library.series.reduce(0) { $0 + $1.episodes.count }
        return VStack(alignment: .leading, spacing: 8) {
            shelfHeader("剧集", detail: "\(library.series.count) 部 · \(episodeCount) 集", identifier: "home.shelf.series") {
                PosterGridScreen(title: "剧集", items: library.series) { group, width in
                    seriesLink(group, width: width, scope: "grid")
                }
            }

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(library.series.enumerated()), id: \.element.id) { index, group in
                        seriesLink(group, width: 108, scope: "shelf")
                            .reveal(index, id: group.id)
                            .shelfCard()
                            .prefetchArtwork(after: index, in: library.series, count: 4) { $0.posterURL }
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

    private func seriesLink(_ group: SeriesGroup, width: CGFloat, scope: String) -> some View {
        NavigationLink {
            SeriesDetailView(seriesID: group.id)
                .restoringAppearance(colorScheme)
        } label: {
            SeriesPosterCard(group: group, width: width)
        }
        .buttonStyle(PosterButtonStyle())
        .accessibilityIdentifier("home.series.\(group.id)")
        .contextMenu {
            Button("匹配封面", systemImage: AppIcon.poster.name) {
                matching = MatchRequest(group: group)
            }
        }
    }

    private func delete(_ item: HomeMediaItem) {
        if let local = localStore.files.first(where: { $0.id == item.id }) {
            localStore.delete(local)
        } else {
            mediaLibrary.remove(pickCode: item.media.pickCode, for: appState)
        }
    }

    // MARK: 空状态

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: AppIcon.playback.name)
                .font(.scaled(34, weight: Theme.iconWeight))
                .foregroundStyle(Theme.accent)
                .frame(width: 84, height: 84)
                .background(Theme.tileTint, in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
                .reveal(0)
            Text("让好内容，在这里相遇")
                .font(.display(22))
                .reveal(1)
            Text("连接你的 115 网盘，或导入本机视频。\n把喜欢的影片，变成随时可看的片库。")
                .font(.scaled(14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .reveal(2)
            Button { showAdd = true } label: {
                Label("添加影片", systemImage: AppIcon.add.name)
            }
            .buttonStyle(PrimaryActionStyle())
            .frame(maxWidth: 240)
            .padding(.top, 6)
            .reveal(3)
            Button("浏览网盘", action: onBrowseLibrary)
                .font(.scaled(14, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("home.browseLibrary")
                .reveal(4)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 56)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("home.emptyLibrary")
    }

}

private extension View {
    /// 从首页推进去的页面：深浅色跟系统（或「外观」设置）走，次要文字用主题灰。
    func restoringAppearance(_ scheme: ColorScheme) -> some View {
        environment(\.colorScheme, scheme)
            .environment(\.artworkTinted, false)
    }
}
