import SwiftUI

/// 一部剧的详情：背景图、海报、简介，下面是按季和集排好的分集。
/// 只用首页媒体库里已有的数据，从首页和搜索都能进来。
struct SeriesDetailView: View {
    let seriesID: String

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mediaLibrary: MediaLibraryStore
    @EnvironmentObject private var localStore: LocalMediaStore
    @EnvironmentObject private var metadataStore: MediaMetadataStore
    @EnvironmentObject private var recents: RecentStore
    /// 首页在后台算好的分组结果，直接读；不要在 body 里重新把整个片库分组（打开时卡的就是这个）。
    @EnvironmentObject private var librarySnapshots: LibrarySnapshotStore

    @State private var playing: PlaybackQueue?
    @State private var matching: MatchRequest?
    @State private var season: Int?
    @State private var overviewExpanded = false
    @Namespace private var seasonNamespace

    private static let scrollSpace = "series.scroll"
    private let backdropHeight: CGFloat = 265

    var body: some View {
        let group = librarySnapshots.home.series.first { $0.id == seriesID }

        Group {
            if let group {
                content(group)
            } else {
                EmptyStateView(
                    icon: AppIcon.series.name,
                    title: "这部剧已经不在首页",
                    message: "可能已经被移除，或者重新匹配成了别的影片。"
                )
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .designScreen("detail")
        .hidesTabBar()
        // 返回和更多用系统导航栏，和应用其他二级页一样（iOS 26 上是液态玻璃圆按钮）；
        // 导航栏底色去掉，背景图一直铺到状态栏下面。
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .modifier(TransparentNavigationBar())
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let group {
                    Menu {
                        Button("匹配封面", systemImage: AppIcon.poster.name) { matching = MatchRequest(group: group) }
                    } label: {
                        Image(systemName: AppIcon.more.name)
                    }
                    .accessibilityLabel("剧集选项")
                    .accessibilityIdentifier("series.more")
                }
            }
        }
        .playerWindow(item: $playing) { queue in
            PlayerView(source: queue.source, playlist: queue.items)
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
    }

    // MARK: 页面

    private func content(_ group: SeriesGroup) -> some View {
        let seasons = group.seasons
        let currentSeason = season.flatMap { seasons.contains($0) ? $0 : nil } ?? seasons.first ?? 1
        let episodes = seasons.count > 1
            ? group.episodes.filter { ($0.parsed.season ?? 1) == currentSeason }
            : group.episodes

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                backdrop(group)

                VStack(alignment: .leading, spacing: 22) {
                    header(group)
                    overview(group)
                    actions(group)
                    episodesSection(group, episodes: episodes, seasons: seasons, currentSeason: currentSeason)
                }
                .padding(.horizontal, Theme.contentInset)
                .padding(.top, -55)
                .padding(.bottom, 40)
            }
        }
        .coordinateSpace(name: Self.scrollSpace)
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
    }

    /// 背景图往下拉时放大，和首页横幅一样
    private func backdrop(_ group: SeriesGroup) -> some View {
        GeometryReader { proxy in
            let minY = proxy.frame(in: .named(Self.scrollSpace)).minY
            let stretch = max(minY, 0)
            ZStack(alignment: .bottom) {
                ArtworkView(urlString: group.backgroundURL, fallbackURLString: group.posterURL, title: group.title)
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: backdropHeight + stretch)
                    .clipped()

                LinearGradient(
                    stops: [
                        .init(color: Theme.pageBackground.opacity(0), location: 0.4),
                        .init(color: Theme.pageBackground.opacity(0.85), location: 0.8),
                        .init(color: Theme.pageBackground, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: proxy.size.width, height: backdropHeight + stretch)
            .offset(y: -stretch)
        }
        .frame(height: backdropHeight)
        .accessibilityHidden(true)
    }

    private func header(_ group: SeriesGroup) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            PosterArtwork(urlString: group.posterURL, title: group.title, width: 97)
                .reveal(0)

            VStack(alignment: .leading, spacing: 7) {
                Text(group.title)
                    .font(.display(24))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                HStack(spacing: 8) {
                    if !group.year.isEmpty { Text(group.year) }
                    if let country = group.episodes.first?.countryLabel, !country.isEmpty { Text(country) }
                    if !group.rating.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: AppIcon.rating.name)
                                .font(.system(size: 10, weight: .bold))
                            Text(group.rating)
                        }
                        .foregroundStyle(Theme.gold)
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)

                let genres = Array(group.metadata.genres.prefix(3))
                if !genres.isEmpty || !group.sourceLabel.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(genres, id: \.self) { chip($0) }
                        if !group.sourceLabel.isEmpty { chip(group.sourceLabel, tinted: false) }
                    }
                    .lineLimit(1)
                }
            }
            .padding(.bottom, 4)
        }
    }

    private func chip(_ text: String, tinted: Bool = true) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tinted ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(tinted ? Theme.tileTint : Theme.surfaceRaised, in: Capsule())
    }

    private func actions(_ group: SeriesGroup) -> some View {
        let target = resumeTarget(group)
        return HStack(spacing: 10) {
            if let target {
                Button {
                    play(target.item, in: group)
                } label: {
                    Label(target.title, systemImage: AppIcon.play.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.onPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Theme.primaryAction, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.pressable(scale: 0.97))
                .accessibilityIdentifier("series.play")
            }
        }
    }

    @ViewBuilder
    private func overview(_ group: SeriesGroup) -> some View {
        let text = group.metadata.overview
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(4)
                    .lineLimit(overviewExpanded ? nil : 3)
                if text.count > 60 {
                    Button(overviewExpanded ? "收起" : "更多") {
                        withAnimation(Motion.snappy) { overviewExpanded.toggle() }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.pressable(scale: 0.94))
                }
            }
        }
    }

    private func episodesSection(_ group: SeriesGroup, episodes: [HomeMediaItem], seasons: [Int], currentSeason: Int) -> some View {
        let target = resumeTarget(group)?.item
        return VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: "选集", inset: 0) {
                Text("共 \(episodes.count) 集")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            if seasons.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(seasons, id: \.self) { value in
                            SelectionPill(
                                title: "第 \(value) 季 · \(group.episodes.filter { ($0.parsed.season ?? 1) == value }.count) 集",
                                selected: value == currentSeason,
                                namespace: seasonNamespace
                            ) { withAnimation(Motion.snappy) { season = value } }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                    episodeCell(episode, index: index, group: group, isCurrent: episode.id == target?.id)
                }
            }
            .id(currentSeason)
            .transition(.opacity)

            if let target, let line = episodeDetail(target) {
                Text(line)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
    }

    /// 选集里的一格：数字、看过的小勾、看到一半的金色进度线；接下来要看的那一集整块填金。
    private func episodeCell(_ episode: HomeMediaItem, index: Int, group: SeriesGroup, isCurrent: Bool) -> some View {
        let recent = recentEntry(for: episode)
        let progress = recent?.progress ?? 0
        let finished = progress >= 0.92
        let number = episode.parsed.episode.map { String($0) } ?? String(index + 1)
        return Button {
            Haptics.tap()
            play(episode, in: group)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                    .fill(isCurrent ? Theme.gold : Theme.surface)
                Text(number)
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isCurrent ? Theme.onPrimary : (finished ? Theme.textTertiary : Color.primary))
                if finished && !isCurrent {
                    Image(systemName: AppIcon.check.name)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(6)
                }
            }
            .frame(height: 48)
            .overlay(alignment: .bottom) {
                if progress > 0.02 && !finished {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(isCurrent ? Theme.onPrimary.opacity(0.55) : Theme.gold)
                            .frame(width: max(4, (proxy.size.width - 16) * progress), height: 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 8)
                    }
                    .frame(height: 2)
                    .padding(.bottom, 5)
                }
            }
            .overlay {
                if !isCurrent {
                    RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.92))
        .reveal(index, id: episode.id)
        .accessibilityLabel(episode.episodeTitle)
        .accessibilityValue(finished ? "已看完" : (recent?.position).map { "看到 \(playbackTimeText($0))" } ?? "")
        .contextMenu {
            Button("播放", systemImage: AppIcon.play.name) { play(episode, in: group) }
            Button("匹配封面", systemImage: AppIcon.poster.name) { matching = MatchRequest(item: episode) }
            Button(episode.isCloud ? "从媒体库移除" : "删除本地文件", systemImage: AppIcon.trash.name, role: .destructive) {
                remove(episode)
            }
        }
    }

    private func episodeDetail(_ episode: HomeMediaItem) -> String? {
        let parts = [episode.episodeTitle, episode.media.name, formatSize(episode.media.size), episode.sourceLabel]
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: 播放

    private func play(_ episode: HomeMediaItem, in group: SeriesGroup) {
        playing = PlaybackQueue(source: episode.media.source, items: group.episodes.map { $0.media.source })
    }

    /// 最近看过的一集：看到一半就继续这一集，看完了就下一集；没看过从第一集开始
    private func resumeTarget(_ group: SeriesGroup) -> (item: HomeMediaItem, title: String)? {
        for recent in recents.items {
            guard let index = group.episodes.firstIndex(where: { matches(recent, $0) }) else { continue }
            let episode = group.episodes[index]
            if let position = recent.position {
                return (episode, "继续播放 \(episode.episodeTitle) · \(playbackTimeText(position))")
            }
            if index + 1 < group.episodes.count {
                let next = group.episodes[index + 1]
                return (next, "播放 \(next.episodeTitle)")
            }
            return (episode, "重新播放 \(episode.episodeTitle)")
        }
        guard let first = group.episodes.first else { return nil }
        return (first, "播放 \(first.episodeTitle)")
    }

    private func recentEntry(for episode: HomeMediaItem) -> RecentItem? {
        recents.items.first { matches($0, episode) }
    }

    private func matches(_ recent: RecentItem, _ episode: HomeMediaItem) -> Bool {
        if let pickCode = recent.pickCode, !pickCode.isEmpty {
            return episode.isCloud && episode.media.pickCode == pickCode
        }
        guard recent.isLocalFile, let url = URL(string: recent.url) else { return false }
        return !episode.isCloud && episode.media.name == url.lastPathComponent
    }

    private func remove(_ episode: HomeMediaItem) {
        if let local = localStore.files.first(where: { $0.id == episode.id }) {
            localStore.delete(local)
        } else {
            mediaLibrary.remove(pickCode: episode.media.pickCode, for: appState)
        }
    }
}

/// iOS 26 的导航栏按钮自带液态玻璃底，去掉导航栏底色就能直接压在背景图上；
/// 更早的系统按钮没有底，保留系统默认的导航栏底色，免得返回键在亮色背景图上看不清。
struct TransparentNavigationBar: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.toolbarBackground(.hidden, for: .navigationBar)
        } else {
            content
        }
    }
}
