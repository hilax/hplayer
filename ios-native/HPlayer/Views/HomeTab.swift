import SwiftUI
import UniformTypeIdentifiers

struct HomeTab: View {
    @EnvironmentObject private var recents: RecentStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mediaLibrary: MediaLibraryStore
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var localStore = LocalMediaStore()
    @StateObject private var metadataStore = MediaMetadataStore()

    @State private var showImporter = false
    @State private var playing: PlaybackQueue?
    @State private var importError = ""
    @State private var heroSelection = 0
    @State private var showCloudBrowser = false
    @State private var matchingItem: HomeMediaItem?

    private var libraryFiles: [LibraryMedia] {
        localStore.files.map(LibraryMedia.init(local:)) + mediaLibrary.files(for: appState).map(LibraryMedia.init(cloud:))
    }

    private var items: [HomeMediaItem] {
        libraryFiles.map { HomeMediaItem(media: $0, metadata: metadataStore.metadataByMediaID[$0.id]) }
    }

    private var featured: [HomeMediaItem] {
        let matched = items.filter { $0.metadata != nil }
        return Array((matched.isEmpty ? items : matched).prefix(6))
    }

    private var currentFeatured: HomeMediaItem? {
        let list = featured
        guard !list.isEmpty else { return nil }
        return list.indices.contains(heroSelection) ? list[heroSelection] : list[0]
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

    private var librarySummary: String {
        let all = items
        guard !all.isEmpty else { return "你的私人影院" }
        var parts: [String] = []
        let movieCount = movies.count
        let seriesCount = Set(series.compactMap { $0.metadata?.imdbID }).count
        if movieCount > 0 { parts.append("\(movieCount) 部电影") }
        if seriesCount > 0 { parts.append("\(seriesCount) 部剧集") }
        if parts.isEmpty { parts.append("\(all.count) 个视频") }
        return parts.joined(separator: "，")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    header

                    if items.isEmpty {
                        emptyState
                    } else {
                        if !featured.isEmpty {
                            heroSection
                        }
                        if !recents.items.isEmpty {
                            recentShelf
                        }
                        if !movies.isEmpty {
                            mediaShelf(title: "电影", subtitle: "\(movies.count) 部", items: movies)
                        }
                        if !series.isEmpty {
                            mediaShelf(title: "剧集", subtitle: "\(series.count) 集", items: series)
                        }
                        if !unmatched.isEmpty {
                            mediaShelf(title: "待匹配封面", subtitle: "\(unmatched.count) 个文件", items: unmatched)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 40)
                .background(alignment: .top) { ambientBackdrop }
            }
            .scrollIndicators(.hidden)
            .background(Theme.pageBackground.ignoresSafeArea())
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
            .task { localStore.refresh() }
            .task(id: libraryFiles) { metadataStore.sync(files: libraryFiles) }
            .sheet(isPresented: $showCloudBrowser) { HomeCloudBrowser() }
            .sheet(item: $matchingItem) { item in
                MetadataMatchView(file: item.media, current: item.metadata) { metadata in
                    await metadataStore.match(metadata, to: item.media)
                }
            }
            .onChange(of: featured.count) { count in
                if heroSelection >= count { heroSelection = 0 }
            }
        }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            BrandLogo(size: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text("HPlayer")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                Text(librarySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Menu {
                Button("导入本地视频", systemImage: "folder.badge.plus") { showImporter = true }
                Button("添加 115 文件夹", systemImage: "icloud") { showCloudBrowser = true }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                    Text("添加")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .glassCapsule()
            }
            .accessibilityIdentifier("home.sources")

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
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .glassCapsule()
            }
            .accessibilityLabel("更多")
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    /// 当前精选影片的模糊背景，像放映厅里银幕映到墙上的光。
    @ViewBuilder
    private var ambientBackdrop: some View {
        if let item = currentFeatured,
           let url = URL(string: item.backgroundURL.isEmpty ? item.posterURL : item.backgroundURL) {
            AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.6))) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Color.clear
                }
            }
            .frame(height: 620)
            .frame(maxWidth: .infinity)
            .clipped()
            .blur(radius: 70)
            .opacity(colorScheme == .dark ? 0.55 : 0.30)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.7), location: 0.45),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .padding(.horizontal, -18)
            .offset(y: -160)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: 精选

    private var heroSection: some View {
        VStack(spacing: 14) {
            TabView(selection: $heroSelection) {
                ForEach(Array(featured.enumerated()), id: \.element.id) { index, item in
                    HeroMediaCard(item: item) {
                        play(item)
                    } onMatch: {
                        matchingItem = item
                    }
                    .tag(index)
                    .contextMenu { Button("匹配封面", systemImage: "photo") { matchingItem = item } }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 430)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.white.opacity(colorScheme == .dark ? 0.08 : 0.25), lineWidth: 0.5)
            }
            .shadow(color: Theme.shadow, radius: 26, x: 0, y: 14)

            if featured.count > 1 {
                heroIndicator
            }
        }
    }

    private var heroIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<featured.count, id: \.self) { index in
                Capsule()
                    .fill(index == heroSelection ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.track))
                    .frame(width: index == heroSelection ? 22 : 6, height: 6)
                    .contentShape(Rectangle().inset(by: -6))
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.3)) { heroSelection = index }
                    }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: heroSelection)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    // MARK: 片架

    private func mediaShelf(title: String, subtitle: String, items: [HomeMediaItem]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.title3.weight(.bold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        PosterCard(item: item) {
                            play(item)
                        } onDelete: {
                            if let local = localStore.files.first(where: { $0.id == item.id }) { localStore.delete(local) }
                            else { mediaLibrary.remove(pickCode: item.media.pickCode, for: appState) }
                        } onMatch: {
                            matchingItem = item
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

    private var recentShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("最近播放")
                .font(.title3.weight(.bold))

            VStack(spacing: 0) {
                let recent = Array(recents.items.prefix(5))
                ForEach(recent) { item in
                    Button {
                        guard let url = URL(string: item.url) else { return }
                        let source = PlaybackSource.direct(title: item.title, url: url)
                        playing = PlaybackQueue(source: source, items: [source])
                    } label: {
                        HStack(spacing: 13) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 34, height: 34)
                                .background(Theme.tileTint, in: Circle())

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(item.playedAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .surfaceCard(cornerRadius: 20)
        }
    }

    // MARK: 空状态

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Theme.accentGradient)
                    .frame(width: 150, height: 150)
                    .blur(radius: 45)
                    .opacity(colorScheme == .dark ? 0.55 : 0.35)
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
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 34)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .surfaceCard(cornerRadius: 30)
        .padding(.top, 10)
    }

    private func play(_ item: HomeMediaItem) {
        let queue: [HomeMediaItem]
        if let metadata = item.metadata, metadata.isSeries {
            queue = items.filter { $0.metadata?.imdbID == metadata.imdbID }
                .sorted { $0.media.name.localizedStandardCompare($1.media.name) == .orderedAscending }
        } else { queue = items }
        playing = PlaybackQueue(source: item.media.source, items: queue.map { $0.media.source })
    }
}

private struct HomeMediaItem: Identifiable {
    let media: LibraryMedia
    let metadata: MediaMetadata?

    var id: String { media.id }
    var title: String { metadata?.title ?? MediaNameParser.parse(media.name).title }
    var year: String { metadata?.year ?? "" }
    var rating: String { metadata?.rating ?? "" }
    var posterURL: String { metadata?.posterURL ?? media.thumbnail }
    var backgroundURL: String { metadata?.backgroundURL ?? "" }
    var isCloud: Bool { media.localURL == nil }
    var countryLabel: String {
        guard let country = metadata?.country.components(separatedBy: ",").first else { return "" }
        return ["China": "中国", "Japan": "日本", "United States": "美国", "Canada": "加拿大", "South Korea": "韩国"][country] ?? country
    }
    var episodeLabel: String? {
        let parsed = MediaNameParser.parse(media.name)
        guard let season = parsed.season, let episode = parsed.episode else { return nil }
        return "S\(String(format: "%02d", season))E\(String(format: "%02d", episode))"
    }
    var subtitle: String {
        if let episodeLabel { return "\(episodeLabel)  \(formatSize(media.size))" }
        return formatSize(media.size)
    }
}

private struct HeroMediaCard: View {
    let item: HomeMediaItem
    let onPlay: () -> Void
    let onMatch: () -> Void

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

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.25),
                        .init(color: .black.opacity(0.45), location: 0.55),
                        .init(color: .black.opacity(0.92), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 10) {
                    if let logoURL = item.metadata?.logoURL, !logoURL.isEmpty {
                        ArtworkView(urlString: logoURL, title: item.title)
                            .scaledToFit()
                            .frame(maxWidth: 240, maxHeight: 72, alignment: .leading)
                    } else {
                        Text(item.title)
                            .accessibilityIdentifier("home.heroTitle")
                            .font(.system(size: 30, weight: .heavy, design: .rounded))
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }

                    HStack(spacing: 10) {
                        if !item.year.isEmpty { Text(item.year) }
                        if !item.countryLabel.isEmpty { Text(item.countryLabel) }
                        if !item.rating.isEmpty {
                            Label(item.rating, systemImage: "star.fill")
                                .labelStyle(CompactLabelStyle())
                                .foregroundStyle(Color(uiColor: UIColor(hex: 0xFFC94A)))
                        }
                        if let episode = item.episodeLabel { Text(episode) }
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))

                    if let metadata = item.metadata, !metadata.genres.isEmpty {
                        Text(metadata.genres.prefix(3).joined(separator: " / "))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }

                    HStack(spacing: 10) {
                        Button(action: onPlay) {
                            Label("播放", systemImage: "play.fill")
                                .font(.subheadline.weight(.bold))
                                .padding(.horizontal, 22)
                                .padding(.vertical, 11)
                                .foregroundStyle(.black)
                                .background(.white, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home.heroPlay")

                        Button(action: onMatch) {
                            Image(systemName: item.metadata == nil ? "photo.badge.plus" : "photo")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(.white.opacity(0.18), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("更换封面")
                        .accessibilityIdentifier("home.heroMatch")

                        Spacer(minLength: 0)

                        Text(matchText)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.14), in: Capsule())
                    }
                    .padding(.top, 4)
                }
                .foregroundStyle(.white)
                .padding(22)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .topLeading) {
                Text(item.metadata?.isSeries == true ? "剧集精选" : "电影精选")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.35), in: Capsule())
                    .overlay { Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5) }
                    .padding(18)
            }
            .contentShape(Rectangle())
            .clipped()
        }
    }

    private var matchText: String {
        guard let metadata = item.metadata else { return "等待匹配" }
        return metadata.matchedByHash ? "SHA-1 识别" : "已匹配"
    }
}

private struct PosterCard: View {
    let item: HomeMediaItem
    let onPlay: () -> Void
    let onDelete: () -> Void
    let onMatch: () -> Void

    private let width: CGFloat = 138
    private let height: CGFloat = 206

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .bottomLeading) {
                    ArtworkView(urlString: item.posterURL, title: item.title)
                        .scaledToFill()
                        .frame(width: width, height: height)
                        .clipped()

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.7)],
                        startPoint: .center,
                        endPoint: .bottom
                    )

                    Text(item.subtitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(10)
                }
                .frame(width: width, height: height)
                .overlay(alignment: .topTrailing) {
                    if !item.rating.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color(uiColor: UIColor(hex: 0xFFC94A)))
                            Text(item.rating)
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(8)
                    }
                }
                .overlay(alignment: .topLeading) {
                    Image(systemName: item.isCloud ? "icloud.fill" : "iphone")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(8)
                        .accessibilityHidden(true)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.5)
                }
                .shadow(color: Theme.shadow, radius: 10, x: 0, y: 6)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(PosterButtonStyle())
        .accessibilityIdentifier("home.poster.\(item.metadata?.imdbID ?? item.id)")
        .contextMenu {
            Button("播放", systemImage: "play.fill", action: onPlay)
            Button("匹配封面", systemImage: "photo", action: onMatch)
            Button(item.isCloud ? "从媒体库移除" : "删除本地文件", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    private var detailText: String {
        let source = item.isCloud ? "115 网盘" : "本地视频"
        return item.year.isEmpty ? source : "\(item.year)  \(source)"
    }
}

/// 按下海报时轻微缩小，松手回弹。
private struct PosterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

/// 图标和文字挨得更紧的 Label，用在评分这类小信息上。
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 10, weight: .bold))
            configuration.title
        }
    }
}

private struct ArtworkView: View {
    let urlString: String
    var fallbackURLString = ""
    let title: String

    var body: some View {
        if let url = URL(string: urlString) {
            AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.25))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable()
                        .accessibilityLabel(title)
                        .accessibilityIdentifier("home.artwork.\(title)")
                case .failure:
                    secondaryArtwork
                case .empty:
                    secondaryArtwork
                @unknown default:
                    fallback
                }
            }
        } else {
            fallback
        }
    }

    @ViewBuilder private var secondaryArtwork: some View {
        if !fallbackURLString.isEmpty, fallbackURLString != urlString, let url = URL(string: fallbackURLString) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().accessibilityLabel(title).accessibilityIdentifier("home.artwork.\(title)")
                } else { fallback }
            }
        } else { fallback }
    }

    /// 没有海报时用品牌色画一张「空白海报」
    private var fallback: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Theme.brandBlue.opacity(0.85),
                    Theme.brandViolet.opacity(0.75),
                    Theme.brandNavy,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(String(title.prefix(1)).uppercased())
                .font(.system(size: 52, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}
