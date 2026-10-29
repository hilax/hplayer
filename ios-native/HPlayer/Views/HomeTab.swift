import SwiftUI
import UniformTypeIdentifiers

struct HomeTab: View {
    @EnvironmentObject private var recents: RecentStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mediaLibrary: MediaLibraryStore
    @EnvironmentObject private var localStore: LocalMediaStore
    @EnvironmentObject private var metadataStore: MediaMetadataStore
    @ObservedObject private var magnetHistory = MagnetHistoryStore.shared

    @State private var showImporter = false
    @State private var playing: PlaybackQueue?
    @State private var importError = ""
    @State private var playError = ""
    @State private var heroSelection = 0
    @State private var showCloudBrowser = false
    @State private var matching: MatchRequest?
    @State private var magnetLaunch: MagnetLaunch?

    private static let scrollSpace = "home.scroll"
    private let heroHeight: CGFloat = 540

    private var libraryFiles: [LibraryMedia] {
        HomeLibrary.media(local: localStore, cloud: mediaLibrary, appState: appState)
    }

    var body: some View {
        let library = HomeSnapshot(items: HomeLibrary.items(libraryFiles, metadata: metadataStore.metadataByMediaID))
        let continueItems = continueEntries(library)
        let heroItem = currentHero(library)

        NavigationStack {
            GeometryReader { outer in
                let topInset = outer.safeAreaInsets.top
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if library.items.isEmpty {
                            emptyHeader(topInset: topInset)
                            VStack(alignment: .leading, spacing: 28) {
                                emptyState
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
                AmbientBackdrop(
                    urlString: heroItem.map { $0.backgroundURL.isEmpty ? $0.posterURL : $0.backgroundURL } ?? "",
                    fallbackURLString: heroItem?.posterURL ?? ""
                )
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
            .task(id: libraryFiles) { metadataStore.sync(files: libraryFiles) }
            .onChange(of: library.featured.count) { count in
                if heroSelection >= count { heroSelection = 0 }
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
            MetadataMatchView(file: request.file, current: request.current) { metadata in
                for target in request.targets {
                    await metadataStore.match(metadata, to: target)
                }
            }
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

    private func currentHero(_ library: HomeSnapshot) -> HomeMediaItem? {
        let featured = library.featured
        return featured.indices.contains(heroSelection) ? featured[heroSelection] : featured.first
    }

    /// 横幅铺到屏幕最上面；往下拉时从底边向上放大，松手跟着滚动视图的弹性一起回弹。
    private func hero(_ library: HomeSnapshot, topInset: CGFloat) -> some View {
        GeometryReader { proxy in
            let minY = proxy.frame(in: .named(Self.scrollSpace)).minY
            let stretch = max(minY, 0)
            heroPager(library, topInset: topInset)
                .frame(width: proxy.size.width, height: heroHeight + stretch)
                .offset(y: -stretch)
        }
        .frame(height: heroHeight)
    }

    private func heroPager(_ library: HomeSnapshot, topInset: CGFloat) -> some View {
        let featured = library.featured
        let current = currentHero(library)
        return ZStack(alignment: .top) {
            TabView(selection: $heroSelection) {
                ForEach(Array(featured.enumerated()), id: \.element.id) { index, item in
                    HeroPage(item: item, bottomInset: featured.count > 1 ? 34 : 8) {
                        playing = HomeLibrary.queue(for: item, in: library.items)
                    } onMatch: {
                        matching = MatchRequest(item: item)
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            heroTopBar(current, topInset: topInset)
        }
        .overlay(alignment: .bottom) {
            if featured.count > 1 {
                heroIndicator(count: featured.count)
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

    private func heroIndicator(count: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == heroSelection ? Color.white : Color.white.opacity(0.45))
                    .frame(width: index == heroSelection ? 18 : 6, height: 6)
                    .contentShape(Rectangle().inset(by: -6))
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.3)) { heroSelection = index }
                    }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .glassCapsule()
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: heroSelection)
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
            Button("刷新媒体库", systemImage: "arrow.clockwise") {
                localStore.refresh()
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
            if !library.unmatched.isEmpty {
                pendingSection(library)
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
    }
}

// MARK: - 横幅单页

/// 精选横幅的一页：背景图铺满，越往下越透明，融进整页取自这张图的底色；片名和按钮压在底部。
private struct HeroPage: View {
    let item: HomeMediaItem
    /// 底部留给翻页圆点的高度
    let bottomInset: CGFloat
    let onPlay: () -> Void
    let onMatch: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                ArtworkView(
                    urlString: item.backgroundURL.isEmpty ? item.posterURL : item.backgroundURL,
                    fallbackURLString: item.posterURL,
                    title: item.title
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
                Text(matchText)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .glassCapsule()
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

            HStack(spacing: 10) {
                Button(action: onPlay) {
                    Label("播放", systemImage: "play.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 26)
                        .frame(height: 48)
                        .glassProminentCapsule()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.heroPlay")

                Button(action: onMatch) {
                    Image(systemName: item.metadata == nil ? "photo.badge.plus" : "photo")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: 48)
                        .glassCircle()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("更换封面")
                .accessibilityIdentifier("home.heroMatch")

                Spacer(minLength: 0)
            }
            .padding(.top, 6)
        }
    }

    private var matchText: String {
        guard let metadata = item.metadata else { return "等待匹配" }
        return metadata.matchedByHash ? "SHA-1 识别" : "已匹配"
    }
}
