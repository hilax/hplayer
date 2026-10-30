import SwiftUI

// MARK: - 数据

/// 首页里的一条媒体：文件本身加上匹配到的影片资料。
struct HomeMediaItem: Identifiable {
    let media: LibraryMedia
    let metadata: MediaMetadata?
    /// 文件名解析结果，排序和显示集数时反复用到，只算一次
    let parsed: MediaNameParser.ParsedName

    init(media: LibraryMedia, metadata: MediaMetadata?) {
        self.media = media
        self.metadata = metadata
        parsed = MediaNameParser.parse(media.name)
    }

    var id: String { media.id }
    var title: String { metadata?.title ?? (parsed.title.isEmpty ? media.name : parsed.title) }
    var year: String { metadata?.year ?? "" }
    var rating: String { metadata?.rating ?? "" }
    var posterURL: String { metadata?.posterURL ?? media.thumbnail }
    var backgroundURL: String { metadata?.backgroundURL ?? "" }
    var isCloud: Bool { media.localURL == nil }
    var isSeries: Bool { metadata?.isSeries == true }
    var sourceLabel: String { isCloud ? "115 网盘" : "本地视频" }

    var countryLabel: String {
        guard let country = metadata?.country.components(separatedBy: ",").first else { return "" }
        return ["China": "中国", "Japan": "日本", "United States": "美国", "Canada": "加拿大", "South Korea": "韩国"][country] ?? country
    }

    /// S01E04 这样的季集标记，没有季数时为空
    var episodeLabel: String? {
        guard let season = parsed.season, let episode = parsed.episode else { return nil }
        return "S\(String(format: "%02d", season))E\(String(format: "%02d", episode))"
    }

    /// 分集列表里的标题：第 4 集
    var episodeTitle: String {
        if let episode = parsed.episode { return "第 \(episode) 集" }
        return parsed.title.isEmpty ? media.name : parsed.title
    }

    /// 海报底部的小字：集数和大小
    var caption: String {
        let size = formatSize(media.size)
        if let episodeLabel { return size.isEmpty ? episodeLabel : "\(episodeLabel)  \(size)" }
        return size
    }
}

/// 同一部剧的所有集，首页合并成一张海报。
struct SeriesGroup: Identifiable {
    let id: String
    let metadata: MediaMetadata
    /// 已按季、集排好
    let episodes: [HomeMediaItem]

    var title: String { metadata.title }
    var year: String { metadata.year }
    var rating: String { metadata.rating }
    var posterURL: String { metadata.posterURL.isEmpty ? (episodes.first?.media.thumbnail ?? "") : metadata.posterURL }
    var backgroundURL: String { metadata.backgroundURL.isEmpty ? posterURL : metadata.backgroundURL }
    var countLabel: String { "\(episodes.count) 集" }

    var sourceLabel: String {
        let cloud = episodes.contains { $0.isCloud }
        let local = episodes.contains { !$0.isCloud }
        if cloud && local { return "本地 + 115" }
        return cloud ? "115 网盘" : "本地视频"
    }

    var detailText: String {
        year.isEmpty ? sourceLabel : "\(year) · \(sourceLabel)"
    }

    /// 出现过的季，没有季数的文件算第 1 季
    var seasons: [Int] {
        Array(Set(episodes.map { $0.parsed.season ?? 1 })).sorted()
    }
}

/// 首页一次刷新用到的全部分组，body 里只算一遍。
struct HomeSnapshot {
    let items: [HomeMediaItem]
    let movies: [HomeMediaItem]
    let series: [SeriesGroup]
    let unmatched: [HomeMediaItem]
    let featured: [HomeMediaItem]

    init(items: [HomeMediaItem]) {
        self.items = items
        let matched = items.filter { $0.metadata?.hasUsablePoster == true }
        movies = matched.filter { $0.metadata?.isSeries == false }
        let matchedIDs = Set(matched.map(\.id))
        unmatched = items.filter { !matchedIDs.contains($0.id) }
        let groups = HomeLibrary.seriesGroups(matched)
        series = groups

        // 精选：每部影片只出现一次，剧集用第一集代表
        var seen = Set<String>()
        var picks: [HomeMediaItem] = []
        for item in matched {
            guard let metadata = item.metadata, seen.insert(metadata.imdbID).inserted else { continue }
            if metadata.isSeries, let first = groups.first(where: { $0.id == metadata.imdbID })?.episodes.first {
                picks.append(first)
            } else {
                picks.append(item)
            }
            if picks.count == 6 { break }
        }
        featured = picks
    }

}

@MainActor
enum HomeLibrary {
    /// 首页媒体库：导入的本地视频加上当前账号加入首页的 115 文件
    static func media(local: LocalMediaStore, cloud: MediaLibraryStore, appState: AppState) -> [LibraryMedia] {
        local.files.map(LibraryMedia.init(local:)) + cloud.media(for: appState)
    }

    static func items(_ media: [LibraryMedia], metadata: [String: MediaMetadata]) -> [HomeMediaItem] {
        media.map { HomeMediaItem(media: $0, metadata: metadata[$0.id]) }
    }

    static func snapshot(local: LocalMediaStore, cloud: MediaLibraryStore, metadata: MediaMetadataStore, appState: AppState) -> HomeSnapshot {
        HomeSnapshot(items: items(media(local: local, cloud: cloud, appState: appState), metadata: metadata.metadataByMediaID))
    }

    nonisolated static func seriesGroups(_ items: [HomeMediaItem]) -> [SeriesGroup] {
        var order: [String] = []
        var buckets: [String: [HomeMediaItem]] = [:]
        for item in items {
            guard let metadata = item.metadata, metadata.isSeries else { continue }
            if buckets[metadata.imdbID] == nil { order.append(metadata.imdbID) }
            buckets[metadata.imdbID, default: []].append(item)
        }
        return order.compactMap { id in
            guard let episodes = buckets[id], let metadata = episodes.first?.metadata else { return nil }
            return SeriesGroup(id: id, metadata: metadata, episodes: episodes.sorted(by: episodeOrder))
        }
    }

    /// 先按季、再按集，没有集数的排在后面，最后按文件名
    nonisolated static func episodeOrder(_ a: HomeMediaItem, _ b: HomeMediaItem) -> Bool {
        let seasonA = a.parsed.season ?? 1
        let seasonB = b.parsed.season ?? 1
        if seasonA != seasonB { return seasonA < seasonB }
        let episodeA = a.parsed.episode ?? Int.max
        let episodeB = b.parsed.episode ?? Int.max
        if episodeA != episodeB { return episodeA < episodeB }
        return a.media.name.localizedStandardCompare(b.media.name) == .orderedAscending
    }

    /// 剧集按顺序连播；电影和其他视频沿用原来的整库列表
    nonisolated static func queue(for item: HomeMediaItem, in items: [HomeMediaItem]) -> PlaybackQueue {
        let list: [HomeMediaItem]
        if let metadata = item.metadata, metadata.isSeries {
            list = items.filter { $0.metadata?.imdbID == metadata.imdbID }.sorted(by: episodeOrder)
        } else {
            list = items
        }
        return PlaybackQueue(source: item.media.source, items: list.map { $0.media.source })
    }
}

/// 打开「匹配封面」：单个文件，或者一整部剧的所有集
struct MatchRequest: Identifiable {
    let id = UUID()
    let file: LibraryMedia
    let current: MediaMetadata?
    let targets: [LibraryMedia]

    init(item: HomeMediaItem) {
        file = item.media
        current = item.metadata
        targets = [item.media]
    }

    init?(group: SeriesGroup) {
        guard let first = group.episodes.first else { return nil }
        file = first.media
        current = group.metadata
        targets = group.episodes.map(\.media)
    }
}

/// 弹出磁力播放页，value 为空时只显示输入框
struct MagnetLaunch: Identifiable {
    let id = UUID()
    let value: String
}

/// 首页「继续观看」的一张卡片：普通播放记录或者磁力记录
struct ContinueEntry: Identifiable {
    enum Target {
        case recent(RecentItem)
        case magnet(MagnetHistoryItem)
    }

    let id: String
    let target: Target
    let title: String
    let subtitle: String
    let tag: String
    let artworkURL: String
    let progress: Double?
    let date: Date
    /// 能在首页媒体库里找到的话，播放时沿用媒体库的连播列表
    let libraryItem: HomeMediaItem?
}

func playbackTimeText(_ value: Double) -> String {
    guard value.isFinite, value >= 0 else { return "00:00" }
    let seconds = Int(value)
    return seconds >= 3600
        ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        : String(format: "%02d:%02d", seconds / 60, seconds % 60)
}

// MARK: - 海报与卡片

private let ratingStarColor = Color(uiColor: UIColor(hex: 0xFFC94A))

extension View {
    /// 压在图片上的小玻璃角标，固定用深色玻璃，白字在任何画面上都清楚
    @ViewBuilder
    func glassBadge() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
                .environment(\.colorScheme, .dark)
        } else {
            self.background(.black.opacity(0.5), in: Capsule())
                .overlay { Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5) }
        }
    }
}

struct RatingBadge: View {
    let rating: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(ratingStarColor)
            Text(rating)
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .glassBadge()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("评分 \(rating)")
    }
}

struct SourceBadge: View {
    let isCloud: Bool

    var body: some View {
        Image(systemName: isCloud ? "icloud.fill" : "iphone")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .glassBadge()
            .accessibilityHidden(true)
    }
}

struct EpisodeCountBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .glassProminentCapsule()
    }
}

/// 2:3 海报图，底部可以压一行小字
struct PosterArtwork: View {
    let urlString: String
    let title: String
    var width: CGFloat = 118
    var caption = ""
    var alignment: Alignment = .center

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkView(urlString: urlString, title: title)
                .scaledToFill()
                .frame(width: width, height: width * 1.5, alignment: alignment)
                .clipped()

            if !caption.isEmpty {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                Text(caption)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(10)
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        }
        .shadow(color: Theme.shadow, radius: 10, x: 0, y: 6)
    }
}

/// 电影或单个视频的海报，点一下直接播放
struct PosterCard: View {
    let item: HomeMediaItem
    var width: CGFloat = 118
    let onPlay: () -> Void
    let onDelete: () -> Void
    let onMatch: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 9) {
                PosterArtwork(urlString: item.posterURL, title: item.title, width: width, caption: item.caption,
                              alignment: item.metadata?.sourceKind == .r18dev ? .trailing : .center)
                    .overlay(alignment: .topTrailing) {
                        if !item.rating.isEmpty {
                            RatingBadge(rating: item.rating).padding(7)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        SourceBadge(isCloud: item.isCloud).padding(7)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(item.year.isEmpty ? item.sourceLabel : "\(item.year)  \(item.sourceLabel)")
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
}

/// 一部剧的海报，角标显示集数
struct SeriesPosterCard: View {
    let group: SeriesGroup
    var width: CGFloat = 118

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            PosterArtwork(urlString: group.posterURL, title: group.title, width: width)
                .overlay(alignment: .topLeading) {
                    EpisodeCountBadge(text: group.countLabel).padding(7)
                }
                .overlay(alignment: .topTrailing) {
                    if !group.rating.isEmpty {
                        RatingBadge(rating: group.rating).padding(7)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(group.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(group.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.series.\(group.id)")
    }
}

/// 「继续观看」卡片：16:9 画面、玻璃角标和玻璃进度条
struct ContinueCard: View {
    let entry: ContinueEntry

    private let width: CGFloat = 220
    private let height: CGFloat = 124

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                ArtworkView(urlString: entry.artworkURL, title: entry.title)
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
            }
            .frame(width: width, height: height)
            .overlay(alignment: .topLeading) {
                Text(entry.tag)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .glassBadge()
                    .padding(10)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .glassCircle()
                    .environment(\.colorScheme, .dark)
                    .padding(10)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .bottom) {
                if let progress = entry.progress {
                    GlassProgressBar(value: progress)
                        .environment(\.colorScheme, .dark)
                        .padding(10)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            }
            .shadow(color: Theme.shadow, radius: 10, x: 0, y: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(entry.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
    }
}

/// 「全部」页面：三列海报网格
struct PosterGridScreen<Item: Identifiable, Cell: View>: View {
    let title: String
    let items: [Item]
    let cell: (Item, CGFloat) -> Cell

    init(title: String, items: [Item], @ViewBuilder cell: @escaping (Item, CGFloat) -> Cell) {
        self.title = title
        self.items = items
        self.cell = cell
    }

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 14
            let available = max(proxy.size.width - 36, 200)
            let columns = max(3, Int((available + spacing) / (130 + spacing)))
            let width = floor((available - spacing * CGFloat(columns - 1)) / CGFloat(columns))
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(width), spacing: spacing, alignment: .top), count: columns),
                    alignment: .leading,
                    spacing: 22
                ) {
                    ForEach(items) { item in
                        cell(item, width)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
    }
}

/// 按下海报时轻微缩小，松手回弹。
struct PosterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

/// 网络图片；加载失败时先试备用地址，再用品牌色画一张「空白海报」
struct ArtworkView: View {
    let urlString: String
    var fallbackURLString = ""
    let title: String
    var letterSize: CGFloat = 52

    var body: some View {
        if let url = URL(string: urlString), !urlString.isEmpty {
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
            secondaryArtwork
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
                .font(.system(size: letterSize, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

// MARK: - 首页底色

/// 首页整页的底色：把当前精选图放大模糊铺满全屏，再盖一层半透明的浅色或深色，
/// 横幅和下面的电影、剧集列表都压在这层取自精选图的颜色上；切换精选时淡入淡出。
struct AmbientBackdrop: View {
    let urlString: String
    var fallbackURLString = ""

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Theme.pageBackground
                if !urlString.isEmpty || !fallbackURLString.isEmpty {
                    ArtworkView(urlString: urlString, fallbackURLString: fallbackURLString, title: "", letterSize: 1)
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .blur(radius: 60, opaque: true)
                        .saturation(1.4)
                        .opacity(colorScheme == .dark ? 0.9 : 0.75)
                        .id(urlString)
                        .transition(.opacity)
                }
                veil
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .animation(.easeInOut(duration: 0.6), value: urlString)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 半透明的一层：留住图片的颜色，又让文字看得清
    private var veil: Color {
        colorScheme == .dark ? Color.black.opacity(0.5) : Color.white.opacity(0.5)
    }
}

extension View {
    /// 首页列表里的卡片：半透明磨砂，透出下面精选图的颜色
    func translucentCard(cornerRadius: CGFloat = 22) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(.ultraThinMaterial, in: shape)
            .overlay { shape.strokeBorder(Theme.hairline, lineWidth: 0.5) }
    }
}
