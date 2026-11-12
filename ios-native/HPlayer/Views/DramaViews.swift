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
                    .font(.system(size: 28, weight: .bold))
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

    func reload(_ category: DramaCategory) async {
        shelves[category] = Shelf()
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

// MARK: - 首页「短剧」频道

struct DramaTab: View {
    @Binding var channel: HomeChannel
    @EnvironmentObject private var appState: AppState
    @StateObject private var feed = DramaFeed()
    @State private var category: DramaCategory = .series
    @Namespace private var pills

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    HomeChannelBar(selection: $channel)
                    Spacer(minLength: 8)
                }
                .padding(.leading, Theme.contentInset)
                .padding(.trailing, 6)
                .frame(minHeight: 44)
                .padding(.bottom, 4)

                HStack(spacing: 8) {
                    ForEach(DramaCategory.allCases) { item in
                        SelectionPill(title: item.title, selected: item == category, namespace: pills) {
                            category = item
                        }
                        .accessibilityIdentifier("drama.category.\(item.rawValue)")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.contentInset)
                .padding(.bottom, 8)

                content
            }
            .background(Theme.pageBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: DramaRoute.self) { route in
                DramaDetailView(route: route)
                    .environmentObject(appState)
                    .hidesTabBar()
            }
        }
        .designScreen("drama")
        .task(id: category) { await feed.loadFirstIfNeeded(category) }
    }

    @ViewBuilder
    private var content: some View {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(shelf.items) { item in
                        NavigationLink(value: DramaRoute(id: item.id, title: item.title, cover: item.cover)) {
                            DramaPosterCard(item: item)
                        }
                        .buttonStyle(PosterButtonStyle())
                        .accessibilityIdentifier("drama.poster.\(item.id)")
                        .onAppear {
                            if item.id == shelf.items.last?.id { Task { await feed.loadMore(category) } }
                        }
                    }
                }
                .padding(.horizontal, Theme.contentInset)
                .padding(.top, 4)

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
            .scrollIndicators(.hidden)
            .refreshable { await feed.reload(category) }
        }
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
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .padding(6)
                    }
                }
            Text(item.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Text(item.tags.prefix(2).joined(separator: " · "))
                .font(.system(size: 11))
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
    @State private var playing: PlaybackQueue?

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
        .onChange(of: playing == nil) { closed in
            if closed { lastWatched = DramaEpisodeRef.lastWatched(videoId: route.id) }
        }
        .playerWindow(item: $playing) { queue in
            PlayerView(source: queue.source, playlist: queue.items)
                .environmentObject(appState)
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
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(3)
                if let detail {
                    HStack(spacing: 10) {
                        if detail.score > 0 {
                            Label(String(format: "%.1f", detail.score), systemImage: AppIcon.rating.name)
                                .foregroundStyle(Theme.rating)
                        }
                        Text(detail.isFinished ? "全 \(detail.episodes.count) 集" : "更新至 \(detail.episodes.count) 集")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .font(.system(size: 13, weight: .semibold))
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
                Image(systemName: AppIcon.play.name)
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
                            .font(.system(size: 14, weight: current ? .bold : .medium).monospacedDigit())
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
        playing = PlaybackQueue(source: source(episode, in: detail),
                                items: detail.episodes.map { source($0, in: detail) })
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
