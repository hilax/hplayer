import SwiftUI
import UniformTypeIdentifiers

struct HomeTab: View {
    @EnvironmentObject private var recents: RecentStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mediaLibrary: MediaLibraryStore
    @EnvironmentObject private var localStore: LocalMediaStore
    @EnvironmentObject private var metadataStore: MediaMetadataStore
    @EnvironmentObject private var scanner: CloudLibraryScanner
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AdultMetadataSettings.enabledKey) private var adultMatching = false
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
    @State private var showScan = false
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
    private let heroHeight: CGFloat = 540

    private var matchingBucket: Int {
        let count = localStore.files.count + mediaLibrary.files(for: appState).count
        return scanner.phase == .running ? count / 300 : count
    }

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
                                if libraryFiles.isEmpty && scanner.phase != .running {
                                    emptyState
                                } else {
                                    matchingState
                                }
                                if !continueItems.isEmpty {
                                    continueShelf(continueItems)
                                }
                            }
                            .padding(.horizontal, 18)
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
            // 整页底色取当前精选图的颜色：横幅往下渐渐透明，融进这层底色，下面的列表也压在它上面
            .background {
                HeroObserver(state: heroState) { state in
                    let heroItem = currentHero(library, selection: state.selection)
                    AmbientBackdrop(
                        urlString: heroItem.map(HomeArtwork.heroURL) ?? "",
                        fallbackURLString: heroItem?.posterURL ?? ""
                    )
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
            .task(id: HomeMatchingInput(count: matchingBucket, accountID: appState.libraryAccountID, background: scenePhase == .background, scanning: scanner.phase == .running)) {
                if scanner.accountID != appState.libraryAccountID {
                    metadataStore.pause()
                    scanner.selectAccount(appState.libraryAccountID)
                    mediaLibrary.add(scanner.discoveredFiles, for: appState)
                }
                metadataStore.hydrate(files: libraryFiles)
                if scenePhase == .background {
                    scanner.pause()
                    metadataStore.pause()
                    mediaLibrary.flush()
                } else {
                    // 初始视图可能在 inactive 阶段挂载；无需等一次可能已错过的 active 变化。
                    metadataStore.sync(files: libraryFiles)
                }
            }
            .onChange(of: adultMatching) { enabled in
                metadataStore.pause()
                guard scenePhase != .background else { return }
                if enabled {
                    metadataStore.retryFailed(files: libraryFiles)
                } else {
                    metadataStore.sync(files: libraryFiles)
                }
            }
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
        .sheet(isPresented: $showScan) {
            HomeLibraryScanView(onStart: { startScan($0) }, onStartFolder: { startScan(true, root: ($0, $1)) }, onRetryMatching: retryMatching)
                .environmentObject(scanner)
                .environmentObject(metadataStore)
                .environmentObject(mediaLibrary)
                .environmentObject(localStore)
                .environmentObject(appState)
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
                HeroActions(hasMetadata: current.metadata != nil) {
                    playing = HomeLibrary.queue(for: current, in: library.items)
                } onMatch: {
                    matching = MatchRequest(item: current)
                }
                .padding(.leading, 20)
                .padding(.bottom, bottomInset + 6)
            }
        }
        .overlay(alignment: .bottom) {
            if featured.count > 1 {
                heroIndicator(count: featured.count, selection: selection)
                    .padding(.bottom, 2)
            }
        }
    }

    private func heroTopBar(_ current: HomeMediaItem?, topInset: CGFloat) -> some View {
        HStack(spacing: 10) {
            if let current {
                Text(current.isSeries ? "剧集精选" : "电影精选")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 13)
                    .frame(height: 32)
                    .glassCapsule()
            }
            Spacer(minLength: 8)
            addMenu
            moreMenu
        }
        .padding(.horizontal, 18)
        .padding(.top, topInset + 6)
    }

    private func heroIndicator(count: Int, selection: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == selection ? Color.white : Color.white.opacity(0.45))
                    .frame(width: index == selection ? 18 : 6, height: 6)
                    .contentShape(Rectangle().inset(by: -6))
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.3)) { heroState.selection = index }
                    }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .glassCapsule()
        .environment(\.colorScheme, .dark)
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

    private var moreMenu: some View {
        Menu {
            Button("扫描 115 全盘并匹配封面", systemImage: "sparkle.magnifyingglass") {
                guard appState.isAuthenticated, appState.libraryAccountID != nil else {
                    showCloudBrowser = true
                    return
                }
                showScan = true
                if scanner.phase == .idle { startScan(false) }
            }
            .accessibilityIdentifier("home.scan115")
            Button("重新自动匹配封面", systemImage: "photo.badge.magnifyingglass") {
                retryMatching()
            }
            .disabled(libraryFiles.isEmpty)
            Button("刷新媒体库", systemImage: "arrow.clockwise") {
                localStore.refresh()
                metadataStore.resumeAutomatic()
                metadataStore.sync(files: libraryFiles)
            }
            if !recents.items.isEmpty || !magnetHistory.items.isEmpty {
                Button("清空继续观看", systemImage: "clock.arrow.circlepath", role: .destructive) {
                    recents.clear()
                    magnetHistory.removeAll()
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .glassCircle()
        }
        .accessibilityLabel("更多")
        .accessibilityIdentifier("home.more")
    }

    private func startScan(_ restart: Bool, root: (id: String, name: String)? = nil) {
        guard let accountID = appState.libraryAccountID, appState.isAuthenticated,
              let client = appState.directClient() else { return }
        // 不清空「已失败」记录：继续扫描时重新查询全部未匹配影片会重复请求并拖慢界面。
        metadataStore.resumeAutomatic()
        scanner.start(accountID: accountID, root: root, fetchPage: { cid, offset in
            try await client.filesPage(cid: cid, offset: offset)
        }, onBatch: { files in
            guard appState.isAuthenticated, appState.libraryAccountID == accountID else { return }
            mediaLibrary.add(files, for: appState)
        }, restart: restart, replayInventory: false)
    }

    private func retryMatching() {
        metadataStore.retryFailed(files: libraryFiles)
    }

    // MARK: 内容区

    private func sections(_ library: HomeSnapshot, continueItems: [ContinueEntry]) -> some View {
        VStack(alignment: .leading, spacing: 30) {
            if scanner.phase == .running || scanner.canResume || metadataStore.isMatching {
                scanStatus
            }
            if !continueItems.isEmpty {
                continueShelf(continueItems)
            }
            if !library.movies.isEmpty {
                movieShelf(library)
            }
            if !library.performers.isEmpty {
                performerShelf(library)
            }
            if !library.series.isEmpty {
                seriesShelf(library)
            }
        }
        .padding(.horizontal, 18)
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
                Text("全部")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 13)
                    .frame(height: 30)
                    .glassCapsule()
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 继续观看

    private func continueShelf(_ entries: [ContinueEntry]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            shelfTitle("继续观看", detail: "\(entries.count)")

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(entries) { entry in
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
                .padding(.horizontal, 18)
                .padding(.vertical, 4)
            }
            .padding(.horizontal, -18)
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

        return Array(entries.sorted { $0.date > $1.date }.prefix(12))
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
                        posterCard(item, library: library, width: 118)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 4)
            }
            .padding(.horizontal, -18)
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
                        performerLink(group, width: 118)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 4)
            }
            .padding(.horizontal, -18)
            .scrollIndicators(.hidden)
        }
    }

    private func performerLink(_ group: PerformerGroup, width: CGFloat) -> some View {
        NavigationLink {
            PerformerCollectionView(group: group)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                PosterArtwork(urlString: group.posterURL, title: group.name, width: width, alignment: .trailing)
                    .overlay(alignment: .topLeading) { EpisodeCountBadge(text: "\(group.items.count) 部").padding(7) }
                Text(group.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
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
                        seriesLink(group, width: 118)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 4)
            }
            .padding(.horizontal, -18)
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

    // MARK: 待匹配

    private func pendingSection(_ library: HomeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            shelfTitle("待匹配封面", detail: "\(library.unmatched.count) 个文件")

            VStack(spacing: 0) {
                ForEach(library.unmatched) { item in
                    pendingRow(item, library: library)
                }
            }
            .padding(.vertical, 6)
            .translucentCard(cornerRadius: 22)
        }
    }

    private func pendingRow(_ item: HomeMediaItem, library: HomeSnapshot) -> some View {
        HStack(spacing: 12) {
            ArtworkView(urlString: item.media.thumbnail, title: item.title, letterSize: 20)
                .scaledToFill()
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.media.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text([item.sourceLabel, formatSize(item.media.size)].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                matching = MatchRequest(item: item)
            } label: {
                Text("匹配")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15)
                    .frame(height: 34)
                    .glassProminentCapsule()
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            playing = HomeLibrary.queue(for: item, in: library.items)
        }
        .contextMenu {
            Button("播放", systemImage: "play.fill") {
                playing = HomeLibrary.queue(for: item, in: library.items)
            }
            Button("匹配封面", systemImage: "photo") { matching = MatchRequest(item: item) }
            Button(item.isCloud ? "从媒体库移除" : "删除本地文件", systemImage: "trash", role: .destructive) {
                delete(item)
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

    private var scanStatus: some View {
        Button { showScan = true } label: {
            HStack(spacing: 12) {
                if scanner.phase == .running || metadataStore.isMatching {
                    ProgressView().tint(Theme.accent)
                } else {
                    Image(systemName: "pause.circle").foregroundStyle(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(scanner.phase == .running ? "正在扫描 115 全盘" : (metadataStore.isMatching ? "正在自动匹配封面" : "全盘扫描尚未完成"))
                        .font(.subheadline.weight(.semibold))
                    Text("已发现 \(scanner.progress.discoveredVideos) 个视频 · 已扫描 \(scanner.progress.scannedFolders) 个文件夹")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .translucentCard(cornerRadius: 18)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.scanStatus")
    }

    private var matchingState: some View {
        VStack(spacing: 18) {
            if scanner.phase == .running || metadataStore.isMatching {
                ProgressView().controlSize(.large).tint(Theme.accent)
                Text(scanner.phase == .running ? "正在整理你的 115 片库" : "正在自动匹配封面")
                    .font(.title3.weight(.semibold))
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 40)).foregroundStyle(Theme.accent)
                Text("暂未匹配到封面").font(.title3.weight(.semibold))
            }
            Text("匹配成功的影片会自动显示在这里。没有匹配到的文件仍可在资源库中浏览和播放。")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if scanner.phase == .running || scanner.canResume {
                scanStatus
            }
            if !metadataStore.isMatching {
                GlassCapsuleButton(title: "重新自动匹配", systemImage: "arrow.clockwise", prominent: true) { retryMatching() }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 48)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("home.matchingState")
    }

    private func emptyHeader(topInset: CGFloat) -> some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            addMenu
            moreMenu
        }
        .padding(.horizontal, 18)
        .padding(.top, topInset + 6)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Theme.accentGradient)
                    .frame(width: 150, height: 150)
                    .blur(radius: 45)
                    .opacity(0.45)
                BrandLogo(size: 92)
                    .shadow(color: Theme.brandBlue.opacity(0.35), radius: 18, x: 0, y: 10)
            }
            .padding(.top, 12)

            VStack(spacing: 8) {
                Text("把片库变成海报墙")
                    .font(.title2.weight(.bold))
                Text("导入手机里的视频，或者添加 115 文件夹。HPlayer 会自动配上海报、年份和评分，按电影和剧集整理好。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            VStack(spacing: 12) {
                GlassCapsuleButton(title: "从文件 App 导入", systemImage: "folder.badge.plus", prominent: true) {
                    showImporter = true
                }
                GlassCapsuleButton(title: "添加 115 文件夹", systemImage: "icloud") {
                    showCloudBrowser = true
                }
                GlassCapsuleButton(title: "磁力链接播放", systemImage: "link") {
                    magnetLaunch = MagnetLaunch(value: "")
                }
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 34)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .surfaceCard(cornerRadius: 30)
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

private struct HomeMatchingInput: Equatable {
    let count: Int
    let accountID: String?
    let background: Bool
    let scanning: Bool
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
        VStack(alignment: .leading, spacing: 9) {
            if let logoURL = item.metadata?.logoURL, !logoURL.isEmpty {
                ArtworkView(urlString: logoURL, title: item.title)
                    .scaledToFit()
                    .frame(maxWidth: 250, maxHeight: 76, alignment: .leading)
            } else {
                Text(item.title)
                    .accessibilityIdentifier("home.heroTitle")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
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

/// 横幅底部固定的两个按钮：播放、换封面；翻页时不动
private struct HeroActions: View {
    static let height: CGFloat = 48

    let hasMetadata: Bool
    let onPlay: () -> Void
    let onMatch: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPlay) {
                Label("播放", systemImage: "play.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26)
                    .frame(height: Self.height)
                    .glassProminentCapsule()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.heroPlay")

            Button(action: onMatch) {
                Image(systemName: hasMetadata ? "photo" : "photo.badge.plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: Self.height, height: Self.height)
                    .glassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("更换封面")
            .accessibilityIdentifier("home.heroMatch")
        }
    }
}
