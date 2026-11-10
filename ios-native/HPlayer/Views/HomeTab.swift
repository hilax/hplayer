import SwiftUI
import Pow
import UniformTypeIdentifiers

struct HomeTab: View {
    var onBrowseLibrary: () -> Void = {}
    var onSearch: () -> Void = {}
    var onOpenCatalog: (CatalogKind, CatalogSort) -> Void = { _, _ in }
    /// 首页频道（推荐 / 片库 / 动漫）；这一页本身是「推荐」。
    var channel: Binding<HomeChannel> = .constant(.recommend)
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

    @State private var showAdd = false
    @State private var addAction: AddMediaAction?
    @State private var actionItem: HomeMediaItem?
    @State private var pendingPlayback: PlaybackQueue?
    @State private var pendingMatch: HomeMediaItem?
    @State private var showImporter = false
    @State private var playing: PlaybackQueue?
    @State private var importError = ""
    @State private var playError = ""
    /// 横幅翻页和滚动状态独立保存，避免翻页时重算整个首页。
    @State private var heroState = HeroState()
    @State private var showCloudBrowser = false
    @State private var matching: MatchRequest?
    @State private var magnetLaunch: MagnetLaunch?
    /// 首页和片库共用的分组结果：HomeView 在后台算好（先等封面缓存恢复完，第一屏直接带封面），
    /// 匹配、扫描期间界面不会被整页重算拖住。见 LibrarySnapshotStore。
    @EnvironmentObject private var librarySnapshots: LibrarySnapshotStore
    private var snapshot: HomeSnapshot { librarySnapshots.home }
    /// 第一份首页分组算好之前不显示内容（也不先闪空状态），算好后淡入。
    private var snapshotReady: Bool { librarySnapshots.ready }

    /// 横幅每一页的大图和货架开头的海报提前下载好，滑到时直接有图；顺便把每一页的取色算好。
    private func prefetchArtwork(_ library: HomeSnapshot) {
        ImagePipeline.shared.prefetch(HomeArtwork.prefetchRequests(library, selection: heroState.realIndex(count: library.featured.count)))
        heroState.palette.prepare(library.featured)
    }


    private var libraryFiles: [LibraryMedia] {
        HomeLibrary.media(local: localStore, cloud: mediaLibrary, appState: appState)
    }

    var body: some View {
        let library = snapshot
        let continueItems = continueEntries(library)

        NavigationStack {
            GeometryReader { viewport in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !snapshotReady || metadataStore.isRestoring {
                            // 数据还在准备：只留空白页面底色，不显示空状态
                            Color.clear.frame(height: viewport.size.height)
                        } else if library.featured.isEmpty {
                            topBar(continueItems)
                                .padding(.top, viewport.safeAreaInsets.top)
                            VStack(alignment: .leading, spacing: 28) {
                                emptyState
                                if !continueItems.isEmpty {
                                    continueShelf(continueItems)
                                }
                            }
                            .padding(.bottom, 40)
                        } else {
                            Group {
                                heroCard(library, continueItems: continueItems,
                                         width: viewport.size.width, safeTop: viewport.safeAreaInsets.top)
                                sections(library, continueItems: continueItems)
                            }
                            // 整页铺的是封面取色的深底：文字和卡片一律按深色显示，浅色模式下也一样（和参考视频一致）。
                            .environment(\.colorScheme, .dark)
                            .environment(\.artworkTinted, true)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .ignoresSafeArea(edges: .top)
            }
            .overlay(alignment: .bottom) {
                if localStore.isImporting {
                    ProgressView("正在导入视频…").font(.subheadline)
                        .padding(16).background(Theme.surface, in: Capsule()).padding(.bottom, 12)
                }
            }
            .background {
                HomeHeroBackdrop(items: HeroLoop.pages(library.featured), motion: heroState.motion, palette: heroState.palette)
            }
            .navigationDestination(for: PerformerListRoute.self) { _ in
                PerformerGridView(groups: library.performers)
                    .restoringAppearance(colorScheme)
            }
            .navigationDestination(for: PerformerRoute.self) { route in
                Group {
                    if let group = library.performers.first(where: { $0.id == route.id }) {
                        PerformerCollectionView(group: group)
                            .id(route.id)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: AppIcon.people.name)
                            Text("演员合集已更新").font(.headline)
                            Text("返回首页后重新进入演员合集。").foregroundStyle(.secondary)
                        }
                    }
                }
                .restoringAppearance(colorScheme)
            }
            .toolbar(.hidden, for: .navigationBar)
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
            .onChange(of: librarySnapshots.revision) { _ in prefetchArtwork(snapshot) }
            .onAppear { if snapshotReady { prefetchArtwork(snapshot) } }
            .onChange(of: library.featured.count) { count in
                // 精选换了一批：回到第一张（循环时它在第 1 页，前面是最后一张的复制页）
                heroState.count = count
                heroState.jump(to: HeroLoop.page(forReal: 0, count: count))
                heroState.motion.reset(to: heroState.page)
            }
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

    // MARK: 顶栏与分类

    /// 搜索框、观看历史、添加：三个入口放在同一行，搜索框占满剩余宽度。
    private func topBar(_ continueItems: [ContinueEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HomeChannelBar(selection: channel)
                .padding(.horizontal, Theme.contentInset)
            searchRow(continueItems)
        }
    }

    private func searchRow(_ continueItems: [ContinueEntry]) -> some View {
        HStack(spacing: 4) {
            Button(action: onSearch) {
                HStack(spacing: 8) {
                    Image(systemName: AppIcon.search.name).font(.system(size: 15, weight: Theme.iconWeight))
                    Text("搜索片名、演员或番号").font(.system(size: 14))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(Theme.surface, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.pressable(scale: 0.98))
            .accessibilityLabel("搜索")
            .accessibilityIdentifier("home.search")

            NavigationLink {
                ContinueHistoryView(entries: continueItems, onOpen: openEntry, onRemove: remove)
            } label: {
                Image(systemName: AppIcon.history.name)
                    .font(.system(size: 21, weight: Theme.iconWeight))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable(scale: 0.88))
            .accessibilityLabel("观看历史")
            .accessibilityIdentifier("home.history")

            addMenu
        }
        .padding(.horizontal, Theme.contentInset)
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.heroBar")
    }

    // MARK: 精选横幅

    private func currentHero(_ library: HomeSnapshot, selection: Int) -> HomeMediaItem? {
        let featured = library.featured
        return featured.indices.contains(selection) ? featured[selection] : featured.first
    }

    /// 轮播图底部渐隐进页面背景的高度；按钮和指示点整体上移这么多，避开渐隐区。
    private static let heroFade: CGFloat = 96
    /// 按钮和页码点离轮播图底边的高度：落在渐隐区里，贴近下面的「继续观看」，中间不留大块空白。
    /// 片名在 HeroPage 里按同一个高度往上排。
    fileprivate static let heroControlsLift: CGFloat = 40

    /// 铺满屏幕上方的精选轮播：图片延伸到状态栏下面，频道条和搜索、历史、添加三个入口悬浮在上方。
    private func heroCard(_ library: HomeSnapshot, continueItems: [ContinueEntry],
                          width: CGFloat, safeTop: CGFloat) -> some View {
        let height = min(width * 0.98, 480) + safeTop * 0.4 + Self.heroFade
        return GeometryReader { proxy in
            let minY = proxy.frame(in: .global).minY
            // 下拉时图片向上拉伸，顶部不会露出空白
            let stretch = max(0, minY)
            HeroObserver(state: heroState) { state in
                heroPager(library, page: state.page, originX: proxy.frame(in: .global).minX)
            }
            .onPreferenceChange(HeroPagePositionKey.self) { samples in
                heroState.motion.update(samples: samples, originX: proxy.frame(in: .global).minX,
                                        width: proxy.size.width, count: HeroLoop.pages(library.featured).count)
                heroState.positionChanged()
            }
            .frame(width: proxy.size.width, height: height + stretch)
            .offset(y: -stretch)
        }
        .frame(height: height)
        .overlay(alignment: .top) {
            // 频道条在左、搜索 / 历史 / 添加在右，都悬浮在精选图上
            HStack(spacing: 8) {
                HomeChannelBar(selection: channel)
                Spacer(minLength: 8)
                floatingButtons(continueItems)
            }
            .padding(.horizontal, Theme.contentInset)
            .padding(.top, safeTop + 2)
        }
    }

    private func floatingButton(_ icon: AppIcon) -> some View {
        Image(systemName: icon.name)
            .font(.system(size: 17, weight: Theme.iconWeight))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(Color.white.opacity(0.16), in: Circle())
            .contentShape(Circle())
    }

    private func floatingButtons(_ continueItems: [ContinueEntry]) -> some View {
        HStack(spacing: 10) {
            Button(action: onSearch) { floatingButton(.search) }
                .buttonStyle(.pressable(scale: 0.88))
                .accessibilityLabel("搜索")
                .accessibilityIdentifier("home.search")
            NavigationLink {
                ContinueHistoryView(entries: continueItems, onOpen: openEntry, onRemove: remove)
                    .restoringAppearance(colorScheme)
            } label: { floatingButton(.history) }
                .buttonStyle(.pressable(scale: 0.88))
                .accessibilityLabel("观看历史")
                .accessibilityIdentifier("home.history")
            Button { showAdd = true } label: { floatingButton(.addCircle) }
                .buttonStyle(.pressable(scale: 0.88))
                .accessibilityLabel("添加")
                .accessibilityIdentifier("home.sources")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.heroBar")
    }

    /// 翻页时图片不动、片名跟着页面滑，播放和更多两个按钮固定在原处，作用于当前这一页。
    /// 首尾各多放一张复制页（最后一张放在最前、第一张放在最后），滑到复制页停稳后无动画换回真的那页，
    /// 所以第一张往右滑是最后一张、最后一张往左滑回到第一张，可以一直循环。
    private func heroPager(_ library: HomeSnapshot, page: Int, originX: CGFloat) -> some View {
        let featured = library.featured
        let pages = HeroLoop.pages(featured)
        let selection = HeroLoop.real(page, count: featured.count)
        let current = currentHero(library, selection: selection)
        let binding = Binding<Int>(get: { page }, set: { heroState.page = $0 })
        return TabView(selection: binding) {
            ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                HeroPage(item: item, index: index, originX: originX, featured: pages,
                         motion: heroState.motion, palette: heroState.palette)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .mask(
            VStack(spacing: 0) {
                Rectangle().fill(Color.black)
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.98), location: 0.125),
                        .init(color: .black.opacity(0.92), location: 0.25),
                        .init(color: .black.opacity(0.79), location: 0.375),
                        .init(color: .black.opacity(0.61), location: 0.5),
                        .init(color: .black.opacity(0.4), location: 0.625),
                        .init(color: .black.opacity(0.2), location: 0.75),
                        .init(color: .black.opacity(0.055), location: 0.875),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: Self.heroFade)
            }
        )
        .overlay(alignment: .bottomLeading) {
            if let current {
                HeroActions(hasMetadata: current.metadata != nil, title: heroPlayTitle(current)) {
                    playing = HomeLibrary.queue(for: current, in: library.items)
                } onMatch: {
                    actionItem = current
                }
                .padding(.leading, 18)
                .padding(.bottom, 16 + Self.heroControlsLift)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if featured.count > 1 {
                heroIndicator(count: featured.count, selection: selection)
                    .padding(.trailing, 8)
                    .padding(.bottom, 16 + Self.heroControlsLift)
            }
        }
    }

    /// 这部正在精选里、而且不是精选里的最后一部，才给「不在精选中显示」（精选至少留一部，首页不会变成空的）
    private func canHideFromFeatured(_ item: HomeMediaItem) -> Bool {
        guard let id = item.metadata?.imdbID, snapshot.featured.count > 1 else { return false }
        return snapshot.featured.contains { $0.metadata?.imdbID == id }
    }

    private func heroPlayTitle(_ item: HomeMediaItem) -> String {
        recents.position(for: item.media.source) == nil ? "播放" : "继续播放"
    }

    /// 右下角的小圆点：当前页拉长成胶囊，切换时弹簧过渡。
    private func heroIndicator(count: Int, selection: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == selection ? Color.white : Color.white.opacity(0.4))
                    .frame(width: index == selection ? 14 : 4, height: 4)
                    .contentShape(Rectangle().inset(by: -8))
                    .onTapGesture {
                        withAnimation(reduceMotion ? nil : Motion.smooth) {
                            heroState.page = HeroLoop.page(forReal: index, count: count)
                        }
                    }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .animation(reduceMotion ? nil : Motion.snappy, value: selection)
        .changeEffect(.shine(duration: 0.45), value: selection, isEnabled: !reduceMotion)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("精选影片")
        .accessibilityValue("第 \(selection + 1) 张，共 \(count) 张")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: heroState.page = HeroLoop.page(forReal: (selection + 1) % count, count: count)
            case .decrement: heroState.page = HeroLoop.page(forReal: (selection + count - 1) % count, count: count)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("home.carouselPosition")
    }

    // MARK: 顶部按钮

    private var addMenu: some View {
        Button { showAdd = true } label: {
            Image(systemName: AppIcon.addCircle.name)
                .font(.system(size: 22, weight: Theme.iconWeight))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.88))
        .accessibilityLabel("添加")
        .accessibilityIdentifier("home.sources")
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

    private func sections(_ library: HomeSnapshot, continueItems: [ContinueEntry]) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            if !continueItems.isEmpty {
                continueShelf(continueItems)
            }
            if !library.movies.isEmpty {
                movieShelf(library)
            }
            if !library.series.isEmpty {
                seriesShelf(library)
            }
            if !library.performers.isEmpty {
                performerShelf(library)
            }
        }
        .padding(.horizontal, Theme.contentInset)
        .padding(.top, 12)
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
                    .font(.system(size: 12))
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
                    .font(.system(size: 12))
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
                            ContinueCard(entry: entry)
                        }
                        .buttonStyle(PosterButtonStyle())
                        .reveal(index, id: entry.id)
                        .contextMenu {
                            Button("从继续观看移除", systemImage: AppIcon.remove.name, role: .destructive) {
                                remove(entry)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.contentInset)
                .padding(.vertical, 4)
            }
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
            let sourceLabel = recent.isAnime ? "在线动漫" : (recent.isCloud ? "115 网盘" : (recent.isLocalFile ? "本地视频" : "网络地址"))
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
            let tagLabel = recent.isAnime ? "动漫" : (recent.isCloud ? "115" : (recent.isLocalFile ? "本地" : "网络"))
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

    // MARK: 电影与剧集

    private func movieShelf(_ library: HomeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            shelfHeader("电影", detail: "\(library.movies.count) 部", identifier: "home.shelf.movies") {
                PosterGridScreen(title: "电影", items: library.movies) { item, width in
                    posterCard(item, library: library, width: width)
                }
            }

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(library.movies.enumerated()), id: \.element.id) { index, item in
                        posterCard(item, library: library, width: 108)
                            .reveal(index, id: item.id)
                    }
                }
                .padding(.horizontal, Theme.contentInset)
                .padding(.vertical, 4)
            }
            .padding(.horizontal, -Theme.contentInset)
            .scrollIndicators(.hidden)
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
                    }
                }
                .padding(.horizontal, Theme.contentInset)
                .padding(.vertical, 4)
            }
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
                    }
                }
                .padding(.horizontal, Theme.contentInset)
                .padding(.vertical, 4)
            }
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
                .font(.system(size: 34, weight: Theme.iconWeight))
                .foregroundStyle(Theme.accent)
                .frame(width: 84, height: 84)
                .background(Theme.tileTint, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .reveal(0)
            Text("让好内容，在这里相遇")
                .font(.display(22))
                .reveal(1)
            Text("连接你的 115 网盘，或导入本机视频。\n把喜欢的影片，变成随时可看的片库。")
                .font(.system(size: 14))
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
                .font(.system(size: 14, weight: .medium))
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

/// 只比较数量和状态，不比较整份片库。扫描中每新增 300 个视频才重新匹配一次，
/// 否则每扫一页就把整个片库重新过一遍，界面会卡死。
final class HeroState: ObservableObject {
    /// TabView 里的页码（含首尾两张复制页，见 HeroLoop）。
    @Published var page = 0 {
        didSet {
            // 页面位置报上来之前，底色先跟着选中项走
            motion.follow(selection: page)
            wrapWhenSettled()
        }
    }
    /// 精选的张数（不含复制页）
    var count = 0
    let motion = HeroMotionState()
    /// 每一页的封面取色
    let palette = HeroPalette()

    /// 当前是第几张精选（0 起，不含复制页）
    func realIndex(count: Int) -> Int { HeroLoop.real(page, count: count) }

    /// 无动画换页：复制页换回真页、换了一批精选时用。两页画面一样，看不出跳了一下。
    func jump(to page: Int) {
        guard self.page != page else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { self.page = page }
    }

    /// 页面位置更新后调用：停稳在复制页上就换回真页。
    func positionChanged() { wrapWhenSettled() }

    private func wrapWhenSettled() {
        guard let target = HeroLoop.wrapTarget(page, count: count) else { return }
        if let position = motion.position {
            // 还在滑动的话等它停稳；停稳时页面位置会再报一次
            if abs(position - CGFloat(page)) < 0.001 { jump(to: target) }
            return
        }
        // 拿不到页面位置时，等翻页动画结束再换
        let sentinel = page
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.page == sentinel, self.motion.position == nil else { return }
            self.jump(to: target)
        }
    }
}

/// 轮播首尾相接：把最后一张复制到最前、第一张复制到最后。只有一张时不循环。
enum HeroLoop {
    static func pages<Item>(_ items: [Item]) -> [Item] {
        guard items.count > 1, let first = items.first, let last = items.last else { return items }
        return [last] + items + [first]
    }

    /// 页码 → 第几张精选
    static func real(_ page: Int, count: Int) -> Int {
        guard count > 1 else { return min(max(page, 0), max(count - 1, 0)) }
        return ((page - 1) % count + count) % count
    }

    /// 第几张精选 → 页码
    static func page(forReal index: Int, count: Int) -> Int {
        count > 1 ? index + 1 : index
    }

    /// 停在复制页上时要换回的真页页码；不在复制页上返回 nil。
    static func wrapTarget(_ page: Int, count: Int) -> Int? {
        guard count > 1 else { return nil }
        if page == 0 { return count }
        if page == count + 1 { return 1 }
        return nil
    }
}

/// 只在横幅状态变化时重算自己的内容，父页面不订阅这个对象。
private struct HeroObserver<Content: View>: View {
    @ObservedObject var state: HeroState
    let content: (HeroState) -> Content
    init(state: HeroState, @ViewBuilder content: @escaping (HeroState) -> Content) {
        self.state = state
        self.content = content
    }
    var body: some View { content(state) }
}

// MARK: - 横幅单页

/// 精选横幅的一页（参考视频的效果）：翻页时图片钉在屏幕上不动，页面边缘像一扇窗从图上扫过去，
/// 新的一页就这样被「揭」出来；片名跟着页面一起走。画面下半截先柔化，再融进封面取色，和整页底色连成一片。
/// 卡片上的文字固定用白色：首页整页都是封面色的深底。
private struct HeroPage: View {
    let item: HomeMediaItem
    let index: Int
    let originX: CGFloat
    let featured: [HomeMediaItem]
    let motion: HeroMotionState
    let palette: HeroPalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let rawX = geometry.frame(in: .global).minX
            // 这一页离开原位多少。打开「减少动态效果」时不做窗口效果，图片跟着页面一起平移。
            let pageX = reduceMotion ? 0 : max(-width, min(width, rawX - originX))
            ZStack(alignment: .bottomLeading) {
                ZStack {
                    // 滑到这一页时图通常已经预取好；还没到就先露出底色，不画默认图。
                    ArtworkView(
                        urlString: HomeArtwork.heroURL(item),
                        fallbackURLString: item.posterURL,
                        title: item.title,
                        maxPixel: ArtworkSize.hero,
                        loading: .clear
                    )
                    .scaledToFill()
                    .frame(width: width, height: geometry.size.height)
                    .clipped()

                    softenedArtwork(size: geometry.size)
                }
                // 反向抵消页面的位移，图片停在原地；露出多少由这一页的边界（下面的 clipped）决定。
                .offset(x: -pageX)

                HeroTintOverlay(items: featured, motion: motion, palette: palette)

                content
                    .padding(.horizontal, 16)
                    .padding(.bottom, 62 + HomeTab.heroControlsLift)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .preference(key: HeroPagePositionKey.self, value: [index: rawX])
        }
    }

    /// 同一张图先失去细节再融进底色；小尺寸模糊后放大，避免对每页做全尺寸模糊。
    /// 裁切比例和清晰图一致，并跟清晰图一起钉在原地，柔化时不会出现第二个轮廓。
    private func softenedArtwork(size: CGSize) -> some View {
        let width = max(size.width, 1)
        return ArtworkView(urlString: HomeArtwork.heroURL(item), fallbackURLString: item.posterURL,
                           title: "", maxPixel: ArtworkSize.backdrop, loading: .clear, drawsFallback: false)
            .scaledToFill()
            .frame(width: width / 4, height: size.height / 4)
            .clipped()
            .blur(radius: 10)
            .scaleEffect(4)
            .frame(width: width, height: size.height)
            .clipped()
            .mask {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.42),
                    .init(color: .black.opacity(0.12), location: 0.58),
                    .init(color: .black.opacity(0.5), location: 0.74),
                    .init(color: .black.opacity(0.9), location: 0.9),
                    .init(color: .black, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
            .accessibilityHidden(true)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let logoURL = item.metadata?.logoURL, !logoURL.isEmpty {
                ArtworkView(urlString: logoURL, title: item.title)
                    .scaledToFit()
                    .frame(maxWidth: 200, maxHeight: 44, alignment: .leading)
            } else {
                Text(item.title)
                    .accessibilityIdentifier("home.heroTitle")
                    .font(.display(24))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 1)
            }

            HStack(spacing: 8) {
                if !item.year.isEmpty { Text(item.year) }
                if !item.countryLabel.isEmpty { Text(item.countryLabel) }
                if !item.rating.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: AppIcon.rating.name)
                            .font(.system(size: 9, weight: .bold))
                        Text(item.rating)
                    }
                    .foregroundStyle(Theme.rating)
                }
                if let episode = item.episodeLabel { Text(episode) }
                if let genres = item.metadata?.genres, !genres.isEmpty {
                    Text(genres.prefix(2).joined(separator: " / "))
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.82))
            .lineLimit(1)
        }
    }
}

/// 精选播放优先；更正影片资料收在主动打开的更多菜单中。
private struct HeroActions: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let height: CGFloat = 38
    let hasMetadata: Bool
    var title = "播放"
    let onPlay: () -> Void
    let onMatch: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPlay) {
                Label(title, systemImage: AppIcon.play.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.onPrimary)
                    .padding(.horizontal, 18)
                    .frame(height: Self.height)
                    .background(Theme.gold, in: Capsule())
                    .contentShape(Capsule())
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : Motion.fade, value: title)
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("home.heroPlay")
            Button(action: onMatch) {
                Image(systemName: AppIcon.more.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Self.height, height: Self.height)
                    .background(Color.white.opacity(0.2), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("影片选项")
        }
    }
}

private extension View {
    /// 首页内容强制按深色显示；从首页进入的页面恢复成系统（或「外观」设置）的深浅色，次要文字也恢复主题灰。
    func restoringAppearance(_ scheme: ColorScheme) -> some View {
        environment(\.colorScheme, scheme)
            .environment(\.artworkTinted, false)
    }
}
