import SwiftUI
import UniformTypeIdentifiers

struct HomeTab: View {
    var onBrowseLibrary: () -> Void = {}
    @EnvironmentObject private var recents: RecentStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mediaLibrary: MediaLibraryStore
    @EnvironmentObject private var localStore: LocalMediaStore
    @EnvironmentObject private var metadataStore: MediaMetadataStore
    @EnvironmentObject private var scanner: CloudLibraryScanner
    @ObservedObject private var magnetHistory = MagnetHistoryStore.shared

    @State private var showImporter = false
    @State private var playing: PlaybackQueue?
    @State private var importError = ""
    @State private var playError = ""
    /// 横幅的翻页位置和下拉拉伸量。放在独立对象里，翻页、滚动时只重算横幅，不重算整个首页。
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

    private static let scrollSpace = "home.scroll"
    private let heroHeight: CGFloat = 500

    private var libraryFiles: [LibraryMedia] {
        HomeLibrary.media(local: localStore, cloud: mediaLibrary, appState: appState)
    }

    var body: some View {
        let library = snapshot
        let continueItems = continueEntries(library)

        NavigationStack {
            GeometryReader { outer in
                let topInset = outer.safeAreaInsets.top
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if library.featured.isEmpty {
                            emptyHeader(topInset: topInset)
                            VStack(alignment: .leading, spacing: 28) {
                                emptyState
                                if !continueItems.isEmpty {
                                    continueShelf(continueItems)
                                }
                            }
                            .padding(.horizontal, Theme.contentInset)
                            .padding(.bottom, 40)
                        } else {
                            hero(library, topInset: topInset)
                            sections(library, continueItems: continueItems)
                        }
                    }
                }
                .coordinateSpace(name: Self.scrollSpace)
                .scrollIndicators(.hidden)
                .ignoresSafeArea(edges: .top)
            }
            .background(Theme.pageBackground.ignoresSafeArea())
            .navigationDestination(for: PerformerRoute.self) { route in
                if let group = library.performers.first(where: { $0.id == route.id }) {
                    PerformerCollectionView(group: group)
                        .id(route.id)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "person.2")
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
                    localStore.importFiles(urls)
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

    // MARK: 精选横幅

    private func currentHero(_ library: HomeSnapshot, selection: Int) -> HomeMediaItem? {
        let featured = library.featured
        return featured.indices.contains(selection) ? featured[selection] : featured.first
    }

    /// 横幅铺到屏幕最上面；往下拉时从底边向上放大，松手跟着滚动视图的弹性一起回弹。
    /// 正常滚动时拉伸量恒为 0，不会触发任何重算。
    private func hero(_ library: HomeSnapshot, topInset: CGFloat) -> some View {
        HeroObserver(state: heroState) { state in
            heroPager(library, topInset: topInset, selection: state.selection)
                .frame(height: heroHeight + state.stretch)
                .offset(y: -state.stretch)
        }
        .frame(height: heroHeight)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: HeroMinYKey.self, value: proxy.frame(in: .named(Self.scrollSpace)).minY)
            }
        }
        .onPreferenceChange(HeroMinYKey.self) { minY in
            let stretch = max(minY, 0)
            if stretch != heroState.stretch { heroState.stretch = stretch }
        }
    }

    /// 翻页时只有图片和片名跟着滑，播放和换封面两个按钮固定在原处，作用于当前这一页
    private func heroPager(_ library: HomeSnapshot, topInset: CGFloat, selection: Int) -> some View {
        let featured = library.featured
        let current = currentHero(library, selection: selection)
        let bottomInset: CGFloat = featured.count > 1 ? 34 : 8
        let binding = Binding<Int>(get: { selection }, set: { heroState.selection = $0 })
        return ZStack(alignment: .top) {
            TabView(selection: binding) {
                ForEach(Array(featured.enumerated()), id: \.element.id) { index, item in
                    HeroPage(item: item, bottomInset: bottomInset + HeroActions.height + 16)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            heroTopBar(current, topInset: topInset)
        }
        .overlay(alignment: .bottomLeading) {
            if let current {
                HeroActions(hasMetadata: current.metadata != nil, title: recents.position(for: current.media.source) == nil ? "播放" : "继续播放") {
                    playing = HomeLibrary.queue(for: current, in: library.items)
                } onMatch: {
                    matching = MatchRequest(item: current)
                }
                .padding(.horizontal, Theme.contentInset)
                .padding(.bottom, bottomInset + 6)
            }
        }
        .overlay(alignment: .bottom) {
            if featured.count > 1 {
                heroIndicator(count: featured.count, selection: selection)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Theme.contentInset)
                    .padding(.bottom, 4)
            }
        }
    }

    private func heroTopBar(_ current: HomeMediaItem?, topInset: CGFloat) -> some View {
        HStack(spacing: 10) {
            Text("首页")
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            addMenu
        }
        .padding(.horizontal, Theme.contentInset)
        .padding(.top, topInset + 6)
    }

    private func heroIndicator(count: Int, selection: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == selection ? Color.primary : Color.primary.opacity(0.25))
                    .frame(width: index == selection ? 18 : 6, height: 6)
                    .contentShape(Rectangle().inset(by: -6))
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.3)) { heroState.selection = index }
                    }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selection)
        .accessibilityHidden(true)
    }

    // MARK: 顶部按钮

    private var addMenu: some View {
        Menu {
            Button("导入本地视频", systemImage: "folder.badge.plus") { showImporter = true }
            Button("添加 115 文件夹", systemImage: "icloud") { showCloudBrowser = true }
            Button("磁力链接播放", systemImage: "link") { magnetLaunch = MagnetLaunch(value: "") }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .glassCircle()
        }
        .accessibilityLabel("添加")
        .accessibilityIdentifier("home.sources")
    }

    // MARK: 内容区

    private func sections(_ library: HomeSnapshot, continueItems: [ContinueEntry]) -> some View {
        VStack(alignment: .leading, spacing: 30) {
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
        .padding(.top, 22)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shelfTitle(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.title3.weight(.bold))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func shelfHeader<Destination: View>(
        _ title: String,
        detail: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            shelfTitle(title, detail: detail)
            Spacer(minLength: 8)
            NavigationLink {
                destination()
            } label: {
                HStack(spacing: 3) {
                    Text("全部")
                    Image(systemName: "chevron.right")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 继续观看

    private func continueShelf(_ entries: [ContinueEntry]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                shelfTitle("继续观看", detail: "\(entries.count)")
                Spacer()
                NavigationLink {
                    ContinueHistoryView(entries: entries, onOpen: openEntry, onRemove: remove)
                } label: {
                    HStack(spacing: 3) { Text("全部"); Image(systemName: "chevron.right") }
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(entries.prefix(12))) { entry in
                        Button {
                            openEntry(entry)
                        } label: {
                            ContinueCard(entry: entry)
                        }
                        .buttonStyle(PosterButtonStyle())
                        .contextMenu {
                            Button("从继续观看移除", systemImage: "xmark.circle", role: .destructive) {
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
        VStack(alignment: .leading, spacing: 14) {
            shelfHeader("电影", detail: "\(library.movies.count) 部") {
                PosterGridScreen(title: "电影", items: library.movies) { item, width in
                    posterCard(item, library: library, width: width)
                }
            }

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(library.movies) { item in
                        posterCard(item, library: library, width: 105)
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
        VStack(alignment: .leading, spacing: 14) {
            shelfHeader("演员合集", detail: "\(library.performers.count) 位") {
                PosterGridScreen(title: "演员合集", items: library.performers) { group, width in
                    performerLink(group, width: width)
                }
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(library.performers) { group in
                        performerLink(group, width: 105)
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
            VStack(alignment: .leading, spacing: 9) {
                PosterArtwork(urlString: group.posterURL, title: group.name, width: width, alignment: .trailing)
                    .overlay(alignment: .topLeading) { EpisodeCountBadge(text: "\(group.collectionItems.count) 部").padding(7) }
                Text(group.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
        .accessibilityIdentifier("home.performer.\(group.id)")
        .buttonStyle(PosterButtonStyle())
    }

    private func seriesShelf(_ library: HomeSnapshot) -> some View {
        let episodeCount = library.series.reduce(0) { $0 + $1.episodes.count }
        return VStack(alignment: .leading, spacing: 14) {
            shelfHeader("剧集", detail: "\(library.series.count) 部 · \(episodeCount) 集") {
                PosterGridScreen(title: "剧集", items: library.series) { group, width in
                    seriesLink(group, width: width)
                }
            }

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(library.series) { group in
                        seriesLink(group, width: 105)
                    }
                }
                .padding(.horizontal, Theme.contentInset)
                .padding(.vertical, 4)
            }
            .padding(.horizontal, -Theme.contentInset)
            .scrollIndicators(.hidden)
        }
    }

    private func seriesLink(_ group: SeriesGroup, width: CGFloat) -> some View {
        NavigationLink {
            SeriesDetailView(seriesID: group.id)
        } label: {
            SeriesPosterCard(group: group, width: width)
        }
        .buttonStyle(PosterButtonStyle())
        .contextMenu {
            Button("匹配封面", systemImage: "photo") {
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

    private func emptyHeader(topInset: CGFloat) -> some View {
        HStack(spacing: 10) {
            Text("首页").font(.largeTitle.bold())
            Spacer(minLength: 0)
            addMenu
        }
        .padding(.horizontal, Theme.contentInset)
        .padding(.top, topInset + 6)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 80, height: 80)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24))
            Text("让好内容，在这里相遇")
                .font(.title2.weight(.semibold))
            Text("连接你的 115 网盘，或导入本机视频。\n把喜欢的影片，变成随时可看的片库。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
            Button { showImporter = true } label: {
                Label("添加本机视频", systemImage: "plus")
            }
            .buttonStyle(PrimaryActionStyle())
            .frame(maxWidth: 240)
            Button("浏览资源库", action: onBrowseLibrary)
                .font(.subheadline.weight(.medium))
                .frame(minHeight: 44)
                .accessibilityIdentifier("home.browseLibrary")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 70)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("home.emptyLibrary")
    }

}

/// 只比较数量和状态，不比较整份片库。扫描中每新增 300 个视频才重新匹配一次，
/// 否则每扫一页就把整个片库重新过一遍，界面会卡死。
final class HeroState: ObservableObject {
    @Published var selection = 0
    @Published var stretch: CGFloat = 0
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

/// 精选横幅的一页：背景图铺满，越往下越透明，融进整页取自这张图的底色；片名和按钮压在底部。
private struct HeroPage: View {
    let item: HomeMediaItem
    /// 底部留给固定按钮和翻页圆点的高度
    let bottomInset: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                // 滑到这一页时图通常已经预取好；还没到就先露出后面的虚化底色，不画默认图。
                ArtworkView(
                    urlString: HomeArtwork.heroURL(item),
                    fallbackURLString: item.posterURL,
                    title: item.title,
                    maxPixel: ArtworkSize.hero,
                    loading: .clear
                )
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.42),
                            .init(color: .black.opacity(0.55), location: 0.66),
                            .init(color: .clear, location: 0.9),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

                // 顶部淡一层底色，状态栏文字在两种模式下都看得清
                LinearGradient(
                    colors: [topScrim, topScrim.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 170)
                .frame(maxHeight: .infinity, alignment: .top)

                content
                    .padding(.horizontal, 20)
                    .padding(.bottom, bottomInset + 6)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }

    private var topScrim: Color {
        colorScheme == .dark ? Color.black.opacity(0.45) : Color(uiColor: .systemGroupedBackground).opacity(0.6)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("来自你的片库")
                .font(.caption2.weight(.medium))
                .tracking(1.5)
                .foregroundStyle(.secondary)
            if let logoURL = item.metadata?.logoURL, !logoURL.isEmpty {
                ArtworkView(urlString: logoURL, title: item.title)
                    .scaledToFit()
                    .frame(maxWidth: 250, maxHeight: 76, alignment: .leading)
            } else {
                Text(item.title)
                    .accessibilityIdentifier("home.heroTitle")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }

            HStack(spacing: 10) {
                if !item.year.isEmpty { Text(item.year) }
                if !item.countryLabel.isEmpty { Text(item.countryLabel) }
                if !item.rating.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text(item.rating)
                    }
                    .foregroundStyle(Color(uiColor: UIColor(hex: 0xF5A623)))
                }
                if let episode = item.episodeLabel { Text(episode) }
                if let genres = item.metadata?.genres, !genres.isEmpty {
                    Text(genres.prefix(2).joined(separator: " / "))
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.primary.opacity(0.85))
            .lineLimit(1)

            if let overview = item.metadata?.overview, !overview.isEmpty {
                Text(overview)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 420, alignment: .leading)
            }
        }
    }
}

/// 精选播放优先；更正影片资料收在主动打开的更多菜单中。
private struct HeroActions: View {
    @Environment(\.colorScheme) private var colorScheme
    static let height: CGFloat = 48
    let hasMetadata: Bool
    var title = "播放"
    let onPlay: () -> Void
    let onMatch: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPlay) {
                Label(title, systemImage: "play.fill")
            }
            .buttonStyle(PrimaryActionStyle(light: colorScheme == .dark))
            .accessibilityIdentifier("home.heroPlay")
            Menu {
                Button("匹配封面", systemImage: "photo", action: onMatch)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: Self.height, height: Self.height)
                    .glassCircle()
            }
            .accessibilityLabel("影片选项")
        }
    }
}
