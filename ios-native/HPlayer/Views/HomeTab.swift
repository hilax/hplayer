import SwiftUI
import Pow
import UniformTypeIdentifiers

struct HomeTab: View {
    var onBrowseLibrary: () -> Void = {}
    var onSearch: () -> Void = {}
    var onOpenCatalog: (CatalogKind, CatalogSort) -> Void = { _, _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var seriesTransition
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
    /// 首页的分组结果。在后台线程算好再换上，匹配、扫描期间界面不会被整页重算拖住。
    @State private var snapshot = HomeSnapshot(items: [])

    private var snapshotKey: HomeSnapshotKey {
        HomeSnapshotKey(local: localStore.files.count, cloudRevision: mediaLibrary.revision,
                        metadataRevision: metadataStore.revision, account: appState.libraryAccountID)
    }

    private func rebuildSnapshot() async {
        let files = libraryFiles
        let matches = metadataStore.metadataByMediaID
        if snapshot.items.isEmpty {
            // 第一次同步算出，避免首页先闪一下空白。
            let first = HomeSnapshot(items: files.map { HomeMediaItem(media: $0, metadata: matches[$0.id]) })
            snapshot = first
            prefetchArtwork(first)
            return
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        let result = await Task.detached(priority: .userInitiated) {
            HomeSnapshot(items: files.map { HomeMediaItem(media: $0, metadata: matches[$0.id]) })
        }.value
        if !Task.isCancelled {
            snapshot = result
            prefetchArtwork(result)
        }
    }

    /// 横幅每一页的大图和货架开头的海报提前下载好，滑到时直接有图。
    private func prefetchArtwork(_ library: HomeSnapshot) {
        ImagePipeline.shared.prefetch(HomeArtwork.prefetchRequests(library, selection: heroState.selection))
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
                        if library.featured.isEmpty {
                            topBar(continueItems)
                            VStack(alignment: .leading, spacing: 28) {
                                emptyState
                                if !continueItems.isEmpty {
                                    continueShelf(continueItems)
                                }
                            }
                            .padding(.bottom, 40)
                        } else {
                            heroCard(library, continueItems: continueItems,
                                     width: viewport.size.width, safeTop: viewport.safeAreaInsets.top)
                            sections(library, continueItems: continueItems)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .ignoresSafeArea(edges: .top)
                .trackHomeShelfHeader(state: heroState, threshold: 150)
            }
            .overlay(alignment: .top) {
                HomeScrolledBar(state: heroState, onSearch: onSearch, onAdd: { showAdd = true })
            }
            .overlay(alignment: .bottom) {
                if localStore.isImporting {
                    ProgressView("正在导入视频…").font(.subheadline)
                        .padding(16).background(Theme.surface, in: Capsule()).padding(.bottom, 12)
                }
            }
            .background {
                HeroObserver(state: heroState) { state in
                    if let current = currentHero(library, selection: state.selection) {
                        AmbientBackdrop(urlString: HomeArtwork.heroURL(current), fallbackURLString: current.posterURL)
                    } else {
                        Theme.pageBackground.ignoresSafeArea()
                    }
                }
            }
            .navigationDestination(for: PerformerRoute.self) { route in
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
            .task(id: snapshotKey) { await rebuildSnapshot() }
            .onChange(of: library.featured.count) { count in
                if heroState.selection >= count { heroState.selection = 0 }
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
            }, onMatch: { pendingMatch = item; actionItem = nil }, onRemove: { delete(item); actionItem = nil })
            .presentationDetents([.height(590)])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $playing) { queue in
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
    private static let heroFade: CGFloat = 190
    /// 按钮和页码点上移的高度：停在渐隐区的上半段，背后还有足够的暗色
    private static let heroControlsLift: CGFloat = 110

    /// 铺满屏幕上方的精选轮播：图片延伸到状态栏下面，搜索、历史、添加三个入口悬浮在左上角之上。
    private func heroCard(_ library: HomeSnapshot, continueItems: [ContinueEntry],
                          width: CGFloat, safeTop: CGFloat) -> some View {
        let height = min(width * 1.18, 520) + safeTop * 0.4 + Self.heroFade
        return GeometryReader { proxy in
            let minY = proxy.frame(in: .global).minY
            // 下拉时图片向上拉伸，顶部不会露出空白
            let stretch = max(0, minY)
            HeroObserver(state: heroState) { state in
                heroPager(library, selection: state.selection)
            }
            .frame(width: proxy.size.width, height: height + stretch)
            .offset(y: -stretch)
            .preference(key: HeroMinYKey.self, value: minY)
        }
        .frame(height: height)
        .overlay(alignment: .topTrailing) { floatingButtons(continueItems).padding(.top, safeTop + 4) }
        .onPreferenceChange(HeroMinYKey.self) { minY in
            if #unavailable(iOS 18.0) {
                let scrolled = minY < -150
                if scrolled != heroState.scrolled { heroState.scrolled = scrolled }
            }
        }
    }

    private func floatingButton(_ icon: AppIcon) -> some View {
        Image(systemName: icon.name)
            .font(.system(size: 17, weight: Theme.iconWeight))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(Color.white.opacity(0.2), in: Circle())
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
            } label: { floatingButton(.history) }
                .buttonStyle(.pressable(scale: 0.88))
                .accessibilityLabel("观看历史")
                .accessibilityIdentifier("home.history")
            Button { showAdd = true } label: { floatingButton(.addCircle) }
                .buttonStyle(.pressable(scale: 0.88))
                .accessibilityLabel("添加")
                .accessibilityIdentifier("home.sources")
        }
        .padding(.horizontal, Theme.contentInset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.heroBar")
    }

    /// 翻页时只有图片和片名跟着滑，播放和更多两个按钮固定在原处，作用于当前这一页
    private func heroPager(_ library: HomeSnapshot, selection: Int) -> some View {
        let featured = library.featured
        let current = currentHero(library, selection: selection)
        let binding = Binding<Int>(get: { selection }, set: { heroState.selection = $0 })
        return TabView(selection: binding) {
            ForEach(Array(featured.enumerated()), id: \.element.id) { index, item in
                HeroPage(item: item)
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
                        .init(color: .black.opacity(0.92), location: 0.25),
                        .init(color: .black.opacity(0.62), location: 0.5),
                        .init(color: .black.opacity(0.26), location: 0.75),
                        .init(color: .black.opacity(0), location: 1),
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
                        withAnimation(reduceMotion ? nil : Motion.smooth) { heroState.selection = index }
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
            case .increment: heroState.selection = min(selection + 1, count - 1)
            case .decrement: heroState.selection = max(selection - 1, 0)
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
        .padding(.top, 24)
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
                    .foregroundStyle(Theme.textTertiary)
                NavigationLink {
                    destination()
                } label: {
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
                        .reveal(index)
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
            var detail: [String] = [recent.isCloud ? "115 网盘" : (recent.isLocalFile ? "本地视频" : "网络地址")]
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
            entries.append(ContinueEntry(
                id: "recent|\(recent.id)",
                target: .recent(recent),
                title: match?.title ?? (parsed.isEmpty ? recent.title : parsed),
                subtitle: detail.joined(separator: " · "),
                tag: recent.isCloud ? "115" : (recent.isLocalFile ? "本地" : "网络"),
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
                            .reveal(index)
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
            shelfHeader("演员合集", detail: "\(library.performers.count) 位", identifier: "home.shelf.performers") {
                PerformerGridView(groups: library.performers)
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(library.performers.enumerated()), id: \.element.id) { index, group in
                        performerLink(group, width: 200)
                            .reveal(index)
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
                            .reveal(index)
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
        let sourceID = "\(scope)|\(group.id)"
        return NavigationLink {
            SeriesDetailView(seriesID: group.id)
                .modifier(SeriesTransitionDestination(id: sourceID, namespace: seriesTransition, reduceMotion: reduceMotion))
        } label: {
            SeriesPosterCard(group: group, width: width)
                .modifier(SeriesTransitionSource(id: sourceID, namespace: seriesTransition, reduceMotion: reduceMotion))
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
    @Published var selection = 0
    @Published var scrolled = false
}

private extension View {
    @ViewBuilder
    func trackHomeShelfHeader(state: HeroState, threshold: CGFloat) -> some View {
        if #available(iOS 18.0, *) {
            self.onScrollGeometryChange(for: Bool.self, of: { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > threshold
            }, action: { _, scrolled in state.scrolled = scrolled })
        } else { self }
    }
}

private struct HomeScrolledBar: View {
    @ObservedObject var state: HeroState
    let onSearch: () -> Void
    let onAdd: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group { bar }
            .animation(reduceMotion ? nil : Motion.snappy, value: state.scrolled)
    }

    @ViewBuilder
    private var bar: some View {
        if state.scrolled {
            HStack(spacing: 8) {
                Button(action: onSearch) {
                    HStack(spacing: 8) {
                        Image(systemName: AppIcon.search.name).font(.system(size: 14, weight: Theme.iconWeight))
                        Text("你的片库").font(.system(size: 14, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Theme.surface, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.pressable(scale: 0.98))
                .accessibilityLabel("搜索")
                .accessibilityIdentifier("home.scrolledSearch")
                Button(action: onAdd) {
                    Image(systemName: AppIcon.addCircle.name)
                        .font(.system(size: 22, weight: Theme.iconWeight))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable(scale: 0.88))
                .accessibilityLabel("添加影片")
                .accessibilityIdentifier("home.scrolledAdd")
            }
            .padding(.horizontal, Theme.contentInset).padding(.top, 2).padding(.bottom, 6)
            .background { Rectangle().fill(.regularMaterial).ignoresSafeArea(edges: .top) }
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

private struct HeroMinYKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
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

private struct HomeSnapshotKey: Equatable {
    let local: Int
    let cloudRevision: Int
    let metadataRevision: Int
    let account: String?
}

// MARK: - 横幅单页

/// 精选横幅的一页：图片铺满圆角卡片，底部压一层深色渐变，片名和信息放在渐变上。
/// 卡片上的文字固定用白色，浅色和深色模式下都一样清楚。
private struct HeroPage: View {
    let item: HomeMediaItem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let scrim = Color(red: 11 / 255, green: 12 / 255, blue: 16 / 255)

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let rawX = reduceMotion ? 0 : geometry.frame(in: .global).minX
            let pageX = max(-width, min(width, rawX))
            ZStack(alignment: .bottomLeading) {
                // 滑到这一页时图通常已经预取好；还没到就先露出底色，不画默认图。
                ArtworkView(
                    urlString: HomeArtwork.heroURL(item),
                    fallbackURLString: item.posterURL,
                    title: item.title,
                    maxPixel: ArtworkSize.hero,
                    loading: .clear
                )
                .scaledToFill()
                .frame(width: width * 1.4, height: geometry.size.height)
                .clipped()
                .offset(x: -pageX * 0.2)
                .frame(width: width, height: geometry.size.height)
                .clipped()

                LinearGradient(
                    stops: [
                        .init(color: Self.scrim.opacity(0), location: 0.1),
                        .init(color: Self.scrim.opacity(0.55), location: 0.55),
                        .init(color: Self.scrim.opacity(0.94), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                content
                    .padding(.horizontal, 16)
                    .padding(.bottom, 62 + 110)
                    .offset(x: pageX * 0.35)
                    .opacity(1 - min(1, abs(pageX) / width * 1.5))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .background(Theme.surface)
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
                    .foregroundStyle(Theme.gold)
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
