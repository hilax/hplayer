import SwiftUI
import UniformTypeIdentifiers

struct HomeTab: View {
    @EnvironmentObject private var recents: RecentStore
    @StateObject private var localStore = LocalMediaStore()
    @StateObject private var metadataStore = MediaMetadataStore()

    @State private var showImporter = false
    @State private var playing: PlaybackQueue?
    @State private var importError = ""
    @State private var heroSelection = 0

    private var items: [HomeMediaItem] {
        localStore.files.map {
            HomeMediaItem(media: $0, metadata: metadataStore.metadataByMediaID[$0.id])
        }
    }

    private var featured: [HomeMediaItem] {
        let matched = items.filter { $0.metadata != nil }
        return Array((matched.isEmpty ? items : matched).prefix(6))
    }

    private var movies: [HomeMediaItem] {
        items.filter { $0.metadata?.isSeries == false }
    }

    private var series: [HomeMediaItem] {
        items.filter { $0.metadata?.isSeries == true }
    }

    private var unmatched: [HomeMediaItem] {
        items.filter { $0.metadata == nil }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.pageBackground.ignoresSafeArea()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        header

                        if localStore.files.isEmpty {
                            emptyState
                        } else {
                            if !featured.isEmpty {
                                heroCarousel
                            }
                            if !movies.isEmpty {
                                mediaShelf(
                                    title: "电影",
                                    subtitle: "\(movies.count) 部",
                                    items: movies
                                )
                            }
                            if !series.isEmpty {
                                mediaShelf(
                                    title: "剧集",
                                    subtitle: "\(series.count) 部",
                                    items: series
                                )
                            }
                            if !unmatched.isEmpty {
                                mediaShelf(
                                    title: "待匹配封面",
                                    subtitle: "\(unmatched.count) 个文件",
                                    items: unmatched
                                )
                            }
                            if !recents.items.isEmpty {
                                recentShelf
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 38)
                }
                .scrollIndicators(.hidden)
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
            .fullScreenCover(item: $playing) { queue in
                PlayerView(source: queue.source, playlist: queue.items)
                    .environmentObject(recents)
            }
            .alert("导入失败", isPresented: Binding(
                get: { !importError.isEmpty },
                set: { if !$0 { importError = "" } }
            )) {
                Button("好", role: .cancel) { importError = "" }
            } message: {
                Text(importError)
            }
            .task {
                localStore.refresh()
                metadataStore.sync(files: localStore.files)
            }
            .onChange(of: localStore.files) { files in
                metadataStore.sync(files: files)
            }
            .onChange(of: featured.count) { count in
                if heroSelection >= count { heroSelection = 0 }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("HPlayer")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                Text("你的私人媒体库")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showImporter = true
            } label: {
                Label("文件源", systemImage: "folder.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassCapsule()
            }
            .buttonStyle(.plain)

            Menu {
                Button("刷新媒体库", systemImage: "arrow.clockwise") {
                    localStore.refresh()
                }
                if !recents.items.isEmpty {
                    Button("清空最近播放", systemImage: "clock.arrow.circlepath", role: .destructive) {
                        recents.clear()
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .frame(width: 42, height: 42)
                    .glassCapsule()
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 10)
    }

    private var heroCarousel: some View {
        TabView(selection: $heroSelection) {
            ForEach(Array(featured.enumerated()), id: \.element.id) { index, item in
                HeroMediaCard(item: item) {
                    play(item)
                }
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: featured.count > 1 ? .always : .never))
        .frame(height: 438)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }

    private func mediaShelf(title: String, subtitle: String, items: [HomeMediaItem]) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title2.bold())
                Spacer()
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        PosterCard(item: item) {
                            play(item)
                        } onDelete: {
                            localStore.delete(item.media)
                        }
                    }
                }
                .padding(.horizontal, 1)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var recentShelf: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("最近播放")
                .font(.title2.bold())

            VStack(spacing: 10) {
                ForEach(recents.items.prefix(5)) { item in
                    Button {
                        guard let url = URL(string: item.url) else { return }
                        let source = PlaybackSource.direct(title: item.title, url: url)
                        playing = PlaybackQueue(source: source, items: [source])
                    } label: {
                        HStack(spacing: 13) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(Theme.accent)
                                .frame(width: 34, height: 34)
                                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(item.playedAt, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                            Image(systemName: "play.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(13)
                        .glassCard(cornerRadius: 18)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Theme.accent.opacity(0.34),
                                Theme.accentAlt.opacity(0.12),
                                Color.black,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(spacing: 16) {
                    Image(systemName: "play.rectangle.on.rectangle.fill")
                        .font(.system(size: 62, weight: .light))
                        .foregroundStyle(Theme.accentGradient)

                    Text("把视频变成一张电影海报墙")
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)

                    Text("导入文件后，HPlayer 会根据文件名或文件哈希自动匹配封面、年份、评分和剧情简介。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)

                    GlassCapsuleButton(
                        title: "从文件 App 导入",
                        systemImage: "folder.badge.plus",
                        prominent: true
                    ) {
                        showImporter = true
                    }
                }
                .padding(28)
            }
            .frame(height: 430)
        }
        .padding(.top, 18)
    }

    private func play(_ item: HomeMediaItem) {
        let source = PlaybackSource.direct(title: item.media.name, url: item.media.url)
        let queue = items.map {
            PlaybackSource.direct(title: $0.media.name, url: $0.media.url)
        }
        playing = PlaybackQueue(source: source, items: queue)
    }
}

private struct HomeMediaItem: Identifiable {
    let media: LocalMedia
    let metadata: MediaMetadata?

    var id: String { media.id }
    var title: String { metadata?.title ?? MediaNameParser.parse(media.name).title }
    var year: String { metadata?.year ?? "" }
    var posterURL: String { metadata?.posterURL ?? "" }
    var backgroundURL: String { metadata?.backgroundURL ?? "" }
    var subtitle: String {
        let parsed = MediaNameParser.parse(media.name)
        guard let season = parsed.season, let episode = parsed.episode else { return formatSize(media.size) }
        return "S\(String(format: "%02d", season))E\(String(format: "%02d", episode)) · \(formatSize(media.size))"
    }
}

private struct HeroMediaCard: View {
    let item: HomeMediaItem
    let onPlay: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkView(
                urlString: item.backgroundURL.isEmpty ? item.posterURL : item.backgroundURL,
                title: item.title
            )
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.18),
                    .init(color: .black.opacity(0.42), location: 0.52),
                    .init(color: .black.opacity(0.96), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 10) {
                if let logoURL = item.metadata?.logoURL, !logoURL.isEmpty {
                    ArtworkView(urlString: logoURL, title: item.title)
                        .scaledToFit()
                        .frame(maxWidth: 250, maxHeight: 70, alignment: .leading)
                } else {
                    Text(item.title)
                        .font(.system(size: 31, weight: .black, design: .rounded))
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    if !item.year.isEmpty { Text(item.year) }
                    if let country = item.metadata?.country, !country.isEmpty { Text(country) }
                    if let rating = item.metadata?.rating, !rating.isEmpty {
                        Label(rating, systemImage: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))

                if let metadata = item.metadata {
                    Text(metadata.genres.prefix(3).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }

                HStack(spacing: 10) {
                    Button(action: onPlay) {
                        Label("立即播放", systemImage: "play.fill")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 18)
                            .padding(.vertical, 11)
                            .foregroundStyle(.black)
                            .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Text(item.metadata?.matchedByHash == true ? "哈希匹配" : "名称匹配")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.white.opacity(0.12), in: Capsule())
                }

                Text(item.media.name)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            .padding(22)
        }
        .overlay(alignment: .topLeading) {
            Text(item.metadata?.isSeries == true ? "剧集精选" : "电影精选")
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.42), in: Capsule())
                .padding(18)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
    }
}

private struct PosterCard: View {
    let item: HomeMediaItem
    let onPlay: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    ArtworkView(urlString: item.posterURL, title: item.title)
                        .scaledToFill()
                        .frame(width: 146, height: 216)
                        .clipped()

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.72)],
                        startPoint: .center,
                        endPoint: .bottom
                    )

                    Text(item.subtitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(10)
                }
                .frame(width: 146, height: 216)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                }

                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(width: 146, alignment: .leading)

                Text(item.year.isEmpty ? "本地视频" : item.year)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 146, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("播放", systemImage: "play.fill", action: onPlay)
            Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}

private struct ArtworkView: View {
    let urlString: String
    let title: String

    var body: some View {
        if let url = URL(string: urlString) {
            AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.25))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable()
                case .failure:
                    fallback
                case .empty:
                    fallback.overlay { ProgressView().tint(.white) }
                @unknown default:
                    fallback
                }
            }
        } else {
            fallback
        }
    }

    private var fallback: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Theme.accent.opacity(0.42),
                    Theme.accentAlt.opacity(0.2),
                    Color(white: 0.08),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(String(title.prefix(1)).uppercased())
                .font(.system(size: 54, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
        }
    }
}
