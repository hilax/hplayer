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

/// 同一演员的影片合集（至少两部）
struct PerformerGroup: Identifiable {
    /// 归一化后的名字：写法只差空格、全半角的算同一个人
    let id: String
    /// 显示用的名字
    let name: String
    let items: [HomeMediaItem]
    var posterURL: String { collectionItems.first?.posterURL ?? "" }

    /// The actor id is authoritative. This also repairs a stale or malformed
    /// cached group instead of letting another actor's work leak into the page.
    var collectionItems: [HomeMediaItem] {
        items.filter { item in
            item.metadata?.performers?.contains {
                PerformerName.key($0) == id
            } == true
        }
    }
}

/// 首页一次刷新用到的全部分组，body 里只算一遍。
struct HomeSnapshot {
    let items: [HomeMediaItem]
    let movies: [HomeMediaItem]
    let series: [SeriesGroup]
    let unmatched: [HomeMediaItem]
    let featured: [HomeMediaItem]
    let performers: [PerformerGroup]

    init(items: [HomeMediaItem]) {
        self.items = items
        let matched = items.filter { $0.metadata?.hasUsablePoster == true }
        movies = matched.filter { $0.metadata?.isSeries == false }
        var byPerformer: [String: (name: String, items: [HomeMediaItem])] = [:]
        var seenWork = Set<String>()
        for item in movies {
            guard let metadata = item.metadata, seenWork.insert(metadata.imdbID).inserted else { continue }
            var seenInWork = Set<String>()
            for raw in metadata.performers ?? [] {
                let key = PerformerName.key(raw)
                guard !key.isEmpty, seenInWork.insert(key).inserted else { continue }
                byPerformer[key, default: (PerformerName.display(raw), [])].items.append(item)
            }
        }
        performers = byPerformer.filter { $0.value.items.count >= 2 }
            .map { PerformerGroup(id: $0.key, name: $0.value.name, items: $0.value.items) }
            .filter { $0.collectionItems.count >= 2 }
            .sorted {
                let left = $0.collectionItems.count
                let right = $1.collectionItems.count
                return left != right ? left > right : $0.name < $1.name
            }
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
                // 横版封面按高度铺满后，宽度是卡片的两倍多。clipped 只裁掉画面，不裁点击区域：
                // 伸出卡片的那一截仍然接得住点击，会盖在左边相邻的卡片上，点左边那张打开的就是右边那张。
                // 图片自己不接收点击，点击区域由卡片外框的 contentShape 决定。
                .allowsHitTesting(false)

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
        .contentShape(Rectangle())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        }
        .background {
            // 阴影画在纯色形状上，滚动时不用对整张海报图重新取阴影
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black)
                .shadow(color: Theme.shadow, radius: 10, x: 0, y: 6)
        }
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
                              alignment: item.metadata?.isWideJacket == true ? .trailing : .center)
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
                    // 封面比卡片大时，多出来的部分不能接住点击（见 PosterArtwork）
                    .allowsHitTesting(false)
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
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
            // 整张卡片（含封面和标题之间的空隙）就是点击区域，且不会超出卡片：
            // 铺满裁剪的图片伸出去的部分不能抢相邻卡片的点击。
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

/// 网络图片；加载失败时先试备用地址，再用品牌色画一张「空白海报」。
/// maxPixel 是按显示尺寸缩小后的最长边（见 ArtworkSize），越小解码越快、内存越省。
/// 图还在下载时只留一块不显眼的底色，不画「空白海报」：否则每张图出现前都会闪一下蓝色字母图。
struct ArtworkView: View {
    enum Loading {
        /// 一块不显眼的底色（海报、列表缩略图）
        case neutral
        /// 什么都不画，露出后面的内容（横幅、虚化背景本来就有底）
        case clear
    }

    let urlString: String
    var fallbackURLString = ""
    let title: String
    var letterSize: CGFloat = 52
    var maxPixel = ArtworkSize.poster
    var loading: Loading = .neutral
    /// 加载失败、或根本没有图片地址时是否画「空白海报」。虚化背景不需要。
    var drawsFallback = true

    var body: some View {
        PipelineImage(url: Self.url(urlString), maxPixel: maxPixel) { phase in
            switch phase {
            case .loaded(let image): artwork(image)
            case .loading: loadingView
            case .failed: secondaryArtwork
            }
        }
        // 换了地址就整个重建，第一帧直接从内存缓存取新图，不会先留着上一张。
        .id(urlString)
    }

    private static func url(_ value: String) -> URL? {
        value.isEmpty ? nil : URL(string: value)
    }

    private func artwork(_ image: UIImage) -> some View {
        Image(uiImage: image).resizable()
            .accessibilityLabel(title)
            .accessibilityIdentifier("home.artwork.\(title)")
    }

    @ViewBuilder private var loadingView: some View {
        switch loading {
        case .neutral: Color(uiColor: .secondarySystemBackground)
        case .clear: Color.clear
        }
    }

    @ViewBuilder private var secondaryArtwork: some View {
        if !fallbackURLString.isEmpty, fallbackURLString != urlString, let url = Self.url(fallbackURLString) {
            PipelineImage(url: url, maxPixel: maxPixel) { phase in
                switch phase {
                case .loaded(let image): artwork(image)
                case .loading: loadingView
                case .failed: fallback
                }
            }
        } else { fallback }
    }

    @ViewBuilder private var fallback: some View {
        if drawsFallback {
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
        } else {
            Color.clear
        }
    }
}

// MARK: - 首页图片预取

enum HomeArtwork {
    /// 横幅那一页用的图：没有横版背景图就用海报
    static func heroURL(_ item: HomeMediaItem) -> String {
        item.backgroundURL.isEmpty ? item.posterURL : item.backgroundURL
    }

    /// 首页马上会用到的图片，按用到的先后排好：
    /// 横幅大图和背景小图（当前页最先，再往两边），然后是每个货架开头的海报。
    /// 滑动横幅、横向翻货架时图片已经在内存里，第一帧就是封面。
    static func prefetchRequests(_ library: HomeSnapshot, selection: Int = 0, shelfLimit: Int = 14) -> [ImageRequest] {
        var requests: [ImageRequest] = []
        var seen = Set<ImageRequest>()
        func add(_ value: String, _ maxPixel: Int) {
            guard !value.isEmpty, let url = URL(string: value) else { return }
            let request = ImageRequest(url: url, maxPixel: maxPixel)
            if seen.insert(request).inserted { requests.append(request) }
        }
        let featured = library.featured
        let order = featured.indices.sorted { (abs($0 - selection), $0) < (abs($1 - selection), $1) }
        for index in order {
            let value = heroURL(featured[index])
            add(value, ArtworkSize.hero)
            add(value, ArtworkSize.backdrop)
        }
        for item in library.movies.prefix(shelfLimit) { add(item.posterURL, ArtworkSize.poster) }
        for group in library.performers.prefix(shelfLimit) { add(group.posterURL, ArtworkSize.poster) }
        for group in library.series.prefix(shelfLimit) { add(group.posterURL, ArtworkSize.poster) }
        return requests
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
                    // 全屏大半径模糊每帧都很贵：在 1/8 大小上模糊，再放大铺满，视觉几乎一样。
                    // 图还没到、或者加载失败时什么都不画，只露出底色，不要闪一下蓝色的默认图。
                    ArtworkView(urlString: urlString, fallbackURLString: fallbackURLString, title: "", letterSize: 1,
                                maxPixel: ArtworkSize.backdrop, loading: .clear, drawsFallback: false)
                        .scaledToFill()
                        .frame(width: proxy.size.width / 8, height: proxy.size.height / 8)
                        .clipped()
                        .blur(radius: 7.5, opaque: true)
                        .scaleEffect(8)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
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
