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

    @State private var playing: PlaybackQueue?
    @State private var matching: MatchRequest?
    @State private var season: Int?
    @State private var overviewExpanded = false

    private static let scrollSpace = "series.scroll"
    private let backdropHeight: CGFloat = 320

    var body: some View {
        let snapshot = HomeLibrary.snapshot(local: localStore, cloud: mediaLibrary, metadata: metadataStore, appState: appState)
        let group = snapshot.series.first { $0.id == seriesID }

        Group {
            if let group {
                content(group)
            } else {
                EmptyStateView(
                    icon: "film.stack",
                    title: "这部剧已经不在首页",
                    message: "可能已经被移除，或者重新匹配成了别的影片。"
                )
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .fullScreenCover(item: $playing) { queue in
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
                    actions(group)
                    overview(group)
                    episodesSection(group, episodes: episodes, seasons: seasons, currentSeason: currentSeason)
                }
                .padding(.horizontal, 18)
                .padding(.top, -150)
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
            PosterArtwork(urlString: group.posterURL, title: group.title, width: 112)

            VStack(alignment: .leading, spacing: 6) {
                Text(group.title)
                    .font(.title2.weight(.heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                HStack(spacing: 8) {
                    if !group.year.isEmpty { Text(group.year) }
                    if let country = group.episodes.first?.countryLabel, !country.isEmpty { Text(country) }
                    if !group.rating.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color(uiColor: UIColor(hex: 0xF5B400)))
                            Text(group.rating)
                        }
                    }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

                if !group.metadata.genres.isEmpty {
                    Text(group.metadata.genres.prefix(3).joined(separator: " / "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    chip(group.sourceLabel)
                    chip(group.metadata.matchedByHash ? "SHA-1 识别" : "已匹配")
                }
                .padding(.top, 2)
            }
            .padding(.bottom, 4)
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .glassCapsule()
    }

    private func actions(_ group: SeriesGroup) -> some View {
        let target = resumeTarget(group)
        return HStack(spacing: 10) {
            if let target {
                Button {
                    play(target.item, in: group)
                } label: {
                    Label(target.title, systemImage: "play.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .glassProminentCapsule()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("series.play")
            }

            Button {
                matching = MatchRequest(group: group)
            } label: {
                Image(systemName: "photo")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 50, height: 50)
                    .glassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("匹配封面")
        }
    }

    @ViewBuilder
    private func overview(_ group: SeriesGroup) -> some View {
        let text = group.metadata.overview
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .lineLimit(overviewExpanded ? nil : 3)
                if text.count > 60 {
                    Button(overviewExpanded ? "收起" : "更多") {
                        withAnimation(.easeInOut(duration: 0.2)) { overviewExpanded.toggle() }
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private func episodesSection(_ group: SeriesGroup, episodes: [HomeMediaItem], seasons: [Int], currentSeason: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Text("分集")
                    .font(.title3.weight(.bold))
                Text("\(episodes.count) 集")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if seasons.count > 1 {
                    Menu {
                        ForEach(seasons, id: \.self) { value in
                            Button("第 \(value) 季") { season = value }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("第 \(currentSeason) 季")
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.bold))
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .glassCapsule()
                    }
                }
            }

            VStack(spacing: 0) {
                ForEach(episodes) { episode in
                    episodeRow(episode, group: group)
                }
            }
            .padding(.vertical, 6)
            .surfaceCard(cornerRadius: 22)
        }
    }

    private func episodeRow(_ episode: HomeMediaItem, group: SeriesGroup) -> some View {
        let watched = recentEntry(for: episode)?.position
        return Button {
            play(episode, in: group)
        } label: {
            HStack(spacing: 12) {
                ArtworkView(urlString: episode.media.thumbnail, title: group.title, letterSize: 22)
                    .scaledToFill()
                    .frame(width: 112, height: 63)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        if let number = episode.parsed.episode {
                            Text(String(format: "E%02d", number))
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .frame(height: 18)
                                .glassBadge()
                                .padding(6)
                        }
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.episodeTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(episode.media.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text([formatSize(episode.media.size), episode.sourceLabel].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let watched {
                        Text("看到 \(playbackTimeText(watched))")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("播放", systemImage: "play.fill") { play(episode, in: group) }
            Button("匹配封面", systemImage: "photo") { matching = MatchRequest(item: episode) }
            Button(episode.isCloud ? "从媒体库移除" : "删除本地文件", systemImage: "trash", role: .destructive) {
                remove(episode)
            }
        }
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
