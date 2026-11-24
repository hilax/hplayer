import SwiftUI

// 磁力聚合各页面共用的组件：封面、海报卡片、影片行、分类标签、搜索框、状态页。
// 版式和首页 / 动漫 / 片库同一套：频道条式的分类、胶囊搜索框、顶部轮播加氛围色、18pt 栏目标题；
// 封面用 3:4 海报，番号浮在封面左上角。

// MARK: - 版式常量

enum MagnetLayout {
    /// 三列海报网格（最新、女优页、片商页）。
    static let posterColumns = [
        GridItem(.flexible(), spacing: 10, alignment: .top),
        GridItem(.flexible(), spacing: 10, alignment: .top),
        GridItem(.flexible(), spacing: 10, alignment: .top)
    ]

    /// 三列头像网格（女优分类）。
    static let avatarColumns = [
        GridItem(.flexible(), spacing: 12, alignment: .top),
        GridItem(.flexible(), spacing: 12, alignment: .top),
        GridItem(.flexible(), spacing: 12, alignment: .top)
    ]

    static let posterRatio: CGFloat = 3.0 / 4.0

    /// 最新出种的横版卡片：JavBus / DMM 大封面的比例约 1.49，用 3:2 几乎不裁
    static let wideRatio: CGFloat = 3.0 / 2.0
}

// MARK: - 日期

enum MagnetDates {
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// 「2026-11-21」：今年的写成「11-21」，往年的保持原样。
    static func short(_ date: String, now: Date = Date()) -> String {
        let parts = date.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4 else { return date }
        let year = Calendar(identifier: .gregorian).component(.year, from: now)
        return String(parts[0]) == String(year) ? "\(parts[1])-\(parts[2])" : date
    }

    /// 出种时间：今天 / 昨天 / N 天前（一周内）/ 月-日。Sukebei 的日期是按 UTC 记的，天数也按 UTC 算。
    static func freshness(_ date: String?, now: Date = Date()) -> (label: String, isToday: Bool)? {
        guard let date, let day = dayFormatter.date(from: date) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: day),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1:
            return ("今天", true)
        case 1:
            return ("昨天", false)
        case 2...6:
            return ("\(days) 天前", false)
        default:
            return (short(date, now: now), false)
        }
    }
}

// MARK: - 封面 / 头像

/// 封面/头像：走 ImagePipeline（带防盗链请求头、磁盘缓存、后台缩小解码）。
/// 加载中只显示底色，加载失败才显示占位图标。
struct MagnetArtwork: View {
    let url: URL?
    let maxPixel: Int
    let placeholder: String

    var body: some View {
        PipelineImage(url: url, maxPixel: maxPixel) { phase in
            switch phase {
            case let .loaded(image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            case .loading:
                Rectangle().fill(Theme.surfaceRaised)
            case .failed:
                Rectangle()
                    .fill(Theme.surfaceRaised)
                    .overlay { Image(appIconNamed: placeholder).foregroundStyle(.secondary) }
            }
        }
    }
}

/// 影片封面。JavBus 列表页给的是 147×200 的小图，放大到两列海报里会很糊；
/// 这里换成同一部片的大封面（`pics/cover/xxx_b.jpg`，800 像素宽），按版式裁出正面：
/// - 竖版单封面（宽高比 < 0.9）：整张显示；
/// - 左背右正的横版封面（宽高比约 1.49）：取右边 47.5%，和站点自己做小图的取法一致；
/// - 其他版式（正面的位置不固定）：不冒险裁剪，继续用小图。
/// 大图加载期间和加载失败时都先显示小图，大图到了再换上。
struct MagnetCover: View {
    /// 列表页里的封面地址（小图）。
    let url: URL?

    enum Crop: Equatable {
        case full
        case trailing
    }

    /// 横版封面里「正面」占的宽度比例。
    static let frontFraction: CGFloat = 0.475

    /// 小图地址 → 同一部片的大封面地址；不是 JavBus 小图的地址返回 nil。
    static func highResURL(for url: URL?) -> URL? {
        guard let url else { return nil }
        let text = url.absoluteString
        guard text.contains("/pics/thumb/"), text.hasSuffix(".jpg") else { return nil }
        let cover = text.replacingOccurrences(of: "/pics/thumb/", with: "/pics/cover/")
        return URL(string: String(cover.dropLast(".jpg".count)) + "_b.jpg")
    }

    /// 按大图的宽高比决定怎么取正面；nil 表示不裁，回退到小图。
    static func crop(for size: CGSize) -> Crop? {
        guard size.width > 0, size.height > 0 else { return nil }
        let ratio = size.width / size.height
        if ratio < 0.9 { return .full }
        if ratio >= 1.45, ratio <= 1.52 { return .trailing }
        return nil
    }

    /// 大图超过这个时间还没到，才开始加载小图垫底。大多数封面一两秒内就到了，
    /// 这样不会给每张封面同时发两个请求（一屏九张封面时，请求翻倍容易被图床限流，表现就是封面空着）。
    static let thumbnailDelay: UInt64 = 1_200_000_000

    /// 番号。JavBus 自己的两张图都取不到时，用它去 DMM 找官方封面。
    var code: String = ""

    @State private var thumbnailWanted = false

    var body: some View {
        if let hires = Self.highResURL(for: url) {
            PipelineImage(url: hires, maxPixel: 800) { phase in
                switch phase {
                case let .loaded(image):
                    if let crop = Self.crop(for: image.size) {
                        Self.front(of: image, crop: crop)
                    } else {
                        thumbnail
                    }
                case .loading:
                    if thumbnailWanted { thumbnail } else { Rectangle().fill(Theme.surfaceRaised) }
                case .failed:
                    thumbnail
                }
            }
            .task(id: url) {
                thumbnailWanted = false
                try? await Task.sleep(nanoseconds: Self.thumbnailDelay)
                guard !Task.isCancelled else { return }
                thumbnailWanted = true
            }
        } else {
            thumbnail
        }
    }

    /// 小图；小图也没有（JavBus 对刚登记的新片经常两张图都还没上传，一直回 404）就换 DMM 的官方封面。
    private var thumbnail: some View {
        PipelineImage(url: url, maxPixel: 420) { phase in
            switch phase {
            case let .loaded(image):
                Image(uiImage: image).resizable().scaledToFill()
            case .loading:
                Rectangle().fill(Theme.surfaceRaised)
            case .failed:
                MagnetFallbackCover(code: code)
            }
        }
    }

    static func front(of image: UIImage, crop: Crop) -> some View {
        GeometryReader { proxy in
            let aspect = image.size.width / image.size.height
            let width: CGFloat = {
                switch crop {
                case .full:
                    return max(proxy.size.width, proxy.size.height * aspect)
                case .trailing:
                    return max(proxy.size.width / Self.frontFraction, proxy.size.height * aspect)
                }
            }()
            Image(uiImage: image)
                .resizable()
                .frame(width: width, height: width / aspect)
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height,
                    alignment: crop == .trailing ? .trailing : .center
                )
                .clipped()
        }
    }
}

/// DMM 的官方封面（横版，正面在右边，和 JavBus 的大图版式一致，取法也一样）。
/// 查到之前只显示底色；确实没有（还没发行、DMM 也没收录）才显示占位图标。
struct MagnetFallbackCover: View {
    let code: String
    /// 横版卡片（最新出种）：整张封面都显示，不只取正面
    var wide = false
    @State private var url: URL?
    @State private var finished = false

    init(code: String, wide: Bool = false) {
        self.code = code
        self.wide = wide
        if !code.isEmpty, let cached = MagnetCoverFallback.shared.cachedURL(for: code) {
            _url = State(initialValue: cached)
            _finished = State(initialValue: true)
        } else {
            _url = State(initialValue: nil)
            _finished = State(initialValue: false)
        }
    }

    var body: some View {
        Group {
            if let url {
                PipelineImage(url: url, maxPixel: 800) { phase in
                    switch phase {
                    case let .loaded(image):
                        // DMM 对没有封面的片会回一张 90×122 的「暂无图片」占位图（状态码还是 200），当作没有。
                        if max(image.size.width, image.size.height) < 200 {
                            placeholder
                        } else if wide {
                            MagnetWideCover.artwork(image)
                        } else {
                            MagnetCover.front(of: image, crop: MagnetCover.crop(for: image.size) ?? .full)
                        }
                    case .loading:
                        Rectangle().fill(Theme.surfaceRaised)
                    case .failed:
                        placeholder
                    }
                }
            } else if finished || code.isEmpty {
                placeholder
            } else {
                Rectangle().fill(Theme.surfaceRaised)
            }
        }
        .task(id: code) {
            guard !code.isEmpty else {
                url = nil
                finished = true
                return
            }
            if let cached = MagnetCoverFallback.shared.cachedURL(for: code) {
                url = cached
                finished = true
                return
            }
            url = nil
            finished = false
            let found = await MagnetCoverFallback.shared.url(for: code)
            guard !Task.isCancelled else { return }
            url = found
            finished = true
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Theme.surfaceRaised)
            .overlay { Image(appIconNamed: AppIcon.poster.name).foregroundStyle(.secondary) }
    }
}

/// 横版封面（最新出种卡片）：JavBus / DMM 的大封面本来就是横版（左背面、右正面），整张显示；
/// 竖版的图（单张正面、列表小图）放在同一张图的模糊放大底上居中，不硬裁成一条。
/// 取图顺序和 MagnetCover 一样：JavBus 大图 → 列表小图 → DMM 官方封面。
struct MagnetWideCover: View {
    let url: URL?
    var code: String = ""

    var body: some View {
        if let hires = MagnetCover.highResURL(for: url) {
            PipelineImage(url: hires, maxPixel: 800) { phase in
                switch phase {
                case let .loaded(image):
                    Self.artwork(image)
                case .loading:
                    Rectangle().fill(Theme.surfaceRaised)
                case .failed:
                    thumbnail
                }
            }
        } else if url != nil {
            thumbnail
        } else {
            MagnetFallbackCover(code: code, wide: true)
        }
    }

    private var thumbnail: some View {
        PipelineImage(url: url, maxPixel: 420) { phase in
            switch phase {
            case let .loaded(image):
                Self.artwork(image)
            case .loading:
                Rectangle().fill(Theme.surfaceRaised)
            case .failed:
                MagnetFallbackCover(code: code, wide: true)
            }
        }
    }

    @ViewBuilder
    static func artwork(_ image: UIImage) -> some View {
        if image.size.width >= image.size.height * 1.2 {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 18, opaque: true)
                    .overlay { Color.black.opacity(0.28) }
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
    }
}

/// 浮在封面上的番号小标签。底色固定是深色，文字就必须固定是白色：
/// 之前用的 `Theme.goldLight` 在浅色模式下是深灰，深灰字落在深色底上几乎看不见。
struct MagnetCodeChip: View {
    let code: String

    var body: some View {
        Text(code)
            .font(.scaled(10, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.brandNight.opacity(0.78), in: Capsule())
    }
}

/// 圆形头像。`ringed` 用在女优页抬头：一圈金色描边。
struct MagnetStarAvatar: View {
    let star: MagnetStarItem
    var size: CGFloat = 84
    var ringed = false

    var body: some View {
        MagnetArtwork(url: star.avatarURL, maxPixel: Int(size * 3), placeholder: AppIcon.mine.name)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle().strokeBorder(
                    ringed ? Theme.accent.opacity(0.7) : Theme.hairline,
                    lineWidth: ringed ? 2 : 0.5
                )
            }
    }
}

// MARK: - 卡片上的女优名

private struct MagnetShowsStarNamesKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// 卡片上要不要写女优名。女优页自己的作品列表全是她，不用每张都写一遍（也省掉一批详情页请求）。
    var magnetShowsStarNames: Bool {
        get { self[MagnetShowsStarNamesKey.self] }
        set { self[MagnetShowsStarNamesKey.self] = newValue }
    }
}

/// 卡片上的女优名（「A、B 等」）。列表页本身不带演员：已经查过的从缓存直接出（首帧就有，不跳），
/// 没查过的卡片一出现就排队去查（MagnetStarNames），列表还会提前预取后面几张（prefetchStarNames）；
/// 卡片滑走时它的等待撤掉，还没轮到的不发请求。
/// 没有名字时显示 fallback（灰一档），fallback 也没有就是一段空文字（占住这一行的高度）。
struct MagnetStarNamesText: View {
    let movie: MagnetSearchItem
    var font: Font
    var color: Color
    var fallback: String?
    var limit: Int

    @Environment(\.magnetShowsStarNames) private var enabled
    @State private var names: [String]?

    init(movie: MagnetSearchItem, font: Font = .scaled(11, weight: .semibold),
         color: Color = Theme.textSecondary, fallback: String? = nil, limit: Int = 2) {
        self.movie = movie
        self.font = font
        self.color = color
        self.fallback = fallback
        self.limit = limit
        _names = State(initialValue: Self.known(movie))
    }

    /// 已经知道的名字：条目自带的，或者缓存里的。
    static func known(_ movie: MagnetSearchItem) -> [String]? {
        if !movie.stars.isEmpty { return movie.stars.map(\.name) }
        return MagnetStarNames.shared.cachedNames(for: movie)
    }

    private var shownNames: String? {
        guard enabled, let names else { return nil }
        return MagnetStarNames.display(names, limit: limit)
    }

    var body: some View {
        Group {
            if let shownNames {
                Text(shownNames)
                    .font(font)
                    .foregroundStyle(color)
                    .transition(.opacity)
            } else {
                Text(fallback ?? "")
                    .font(font.weight(.regular))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .lineLimit(1)
        .task(id: movie.id) { await resolve() }
    }

    private func resolve() async {
        if let known = Self.known(movie) {
            names = known
            return
        }
        names = nil
        guard enabled, !movie.code.isEmpty || !movie.detailPath.isEmpty else { return }
        let found = await MagnetStarNames.shared.names(for: movie)
        guard !Task.isCancelled, let found else { return }
        withAnimation(.easeOut(duration: 0.18)) { names = found }
    }
}

/// 列表里第 index 张卡片出现时，把后面 count 张的女优名也排上预取：滑到时名字多半已经在缓存里，首帧就有。
private struct StarNamesPrefetch: ViewModifier {
    let index: Int
    let movies: [MagnetSearchItem]
    let count: Int
    @Environment(\.magnetShowsStarNames) private var enabled

    func body(content: Content) -> some View {
        content.onAppear {
            guard enabled, !InterfacePreview.active else { return }
            let start = index + 1
            guard start < movies.count else { return }
            let next = movies[start ..< min(movies.count, start + count)].filter {
                $0.stars.isEmpty && MagnetStarNames.shared.cachedNames(for: $0) == nil
            }
            guard !next.isEmpty else { return }
            Task { await MagnetStarNames.shared.prefetch(next) }
        }
    }
}

extension View {
    func prefetchStarNames(after index: Int, in movies: [MagnetSearchItem], count: Int = 6) -> some View {
        modifier(StarNamesPrefetch(index: index, movies: movies, count: count))
    }
}

// MARK: - 影片：海报卡片与行

/// 海报卡片：3:4 封面（左上角番号）、两行标题、女优与发行日期。点击进入磁力详情。
struct MagnetPosterCard: View {
    let movie: MagnetSearchItem

    var body: some View {
        NavigationLink {
            MagnetDetailView(item: movie)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(MagnetLayout.posterRatio, contentMode: .fit)
                    .overlay {
                        MagnetCover(url: movie.coverURL, code: movie.code)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 0.5)
                    }
                    .overlay(alignment: .topLeading) {
                        if !movie.code.isEmpty {
                            MagnetCodeChip(code: movie.code).padding(5)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if movie.isFresh {
                            Text("新种")
                                .font(.scaled(9, weight: .bold))
                                .foregroundStyle(Theme.onPrimary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.accent, in: Capsule())
                                .padding(5)
                        }
                    }

                // 和动漫、片库的海报卡同一套字：13pt 标题（两行，番号已经在封面上）、11pt 次要信息
                Text(movie.title)
                    .font(.scaled(13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)

                // 女优在左（放不下先截女优名），日期在右；今年的日期省掉年份
                HStack(spacing: 6) {
                    MagnetStarNamesText(movie: movie)
                    Spacer(minLength: 0)
                    if let date = movie.releaseDate {
                        Text(MagnetDates.short(date))
                            .font(.scaled(11).monospacedDigit())
                            .tertiaryTextStyle()
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
            }
        }
        .buttonStyle(.pressable(scale: 0.97))
    }
}

/// 三列海报网格，滑到最后一项时触发翻页。
struct MagnetPosterGrid: View {
    let movies: [MagnetSearchItem]
    let loadMore: () -> Void

    var body: some View {
        LazyVGrid(columns: MagnetLayout.posterColumns, alignment: .leading, spacing: 16) {
            ForEach(Array(movies.enumerated()), id: \.element.id) { index, movie in
                MagnetPosterCard(movie: movie)
                    // 卡片优先显示大图（取右半边正面），所以提前取的也是大图
                    .prefetchArtwork(after: index, in: movies, count: 9, maxPixel: 800) {
                        MagnetCover.highResURL(for: $0.coverURL)?.absoluteString ?? ""
                    }
                    .prefetchStarNames(after: index, in: movies, count: 6)
                    .gridCardEntrance()
                    .onAppear {
                        if movie.id == movies.last?.id { loadMore() }
                    }
            }
        }
    }
}

// MARK: - 最新出种

/// 最新出种卡片用到的种子信息：从 Sukebei 预取的磁力里汇总。
struct MagnetFreshSummary {
    var freshness: (label: String, isToday: Bool)?
    var hasSubtitles: Bool
    /// 「4K」或「高清」，都不是就没有
    var quality: String?
    /// 各个种子里最多的做种数
    var seeders: Int?
    /// 排第一的种子的大小
    var size: String?

    init(_ movie: MagnetSearchItem, now: Date = Date()) {
        let torrents = movie.prefetchedMagnets
        freshness = MagnetDates.freshness(movie.releaseDate, now: now)
        hasSubtitles = torrents.contains { $0.hasSubtitles }
        if torrents.contains(where: { MagnetFreshSummary.isUHD($0.name) }) {
            quality = "4K"
        } else if torrents.contains(where: { $0.isHD }) {
            quality = "高清"
        } else {
            quality = nil
        }
        seeders = torrents.compactMap(\.seeders).max()
        let firstSize = torrents.first?.size ?? ""
        size = firstSize.isEmpty || firstSize == "未知大小" ? nil : firstSize
    }

    static func isUHD(_ name: String) -> Bool {
        name.range(of: #"(?i)(?<![a-z0-9])(?:4k|2160p|uhd)(?![a-z0-9])"#, options: .regularExpression) != nil
    }
}

/// 最新出种卡片：3:2 横版大封面（整张封面），左上角出种时间（今天是琥珀色），左下角番号，
/// 右下角「中字」（白底黑字）和「4K / 高清」（白色描边）——和磁力详情页的资源标签同一套语义；
/// 下面一行片名，一行女优（还没查到时先写大小）+ 做种数。点进磁力详情。
struct MagnetFreshCard: View {
    static let width: CGFloat = 264

    let movie: MagnetSearchItem

    var body: some View {
        let info = MagnetFreshSummary(movie)
        NavigationLink {
            MagnetDetailView(item: movie)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                cover(info)

                VStack(alignment: .leading, spacing: 3) {
                    Text(movie.title)
                        .font(.scaled(13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        MagnetStarNamesText(movie: movie, font: .scaled(12, weight: .semibold),
                                            color: Theme.textSecondary, fallback: info.size)
                        Spacer(minLength: 0)
                        if let seeders = info.seeders, seeders > 0 {
                            Text("\(seeders) 做种")
                                .font(.scaled(11).monospacedDigit())
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                    }
                }
            }
            .frame(width: Self.width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.97))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("magnet.fresh.\(movie.id)")
    }

    private func cover(_ info: MagnetFreshSummary) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        return Color.clear
            .aspectRatio(MagnetLayout.wideRatio, contentMode: .fit)
            .overlay {
                MagnetWideCover(url: movie.coverURL, code: movie.code)
            }
            // 底部压一层渐暗，番号和标签在任何封面上都看得清
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.62)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 64)
                    .allowsHitTesting(false)
            }
            .clipShape(shape)
            .contentShape(shape)
            .overlay {
                shape.strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline)
            }
            .overlay(alignment: .topLeading) {
                if let freshness = info.freshness {
                    TagBadge(text: freshness.label, style: freshness.isToday ? .accent : .onArtwork)
                        .padding(8)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !movie.code.isEmpty {
                    Text(movie.code)
                        .font(.scaled(15, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .shadow(color: Color.black.opacity(0.35), radius: 3, y: 1)
                        .padding(.leading, 10)
                        .padding(.bottom, 8)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 4) {
                    if info.hasSubtitles {
                        artworkTag("中字", filled: true)
                    }
                    if let quality = info.quality {
                        artworkTag(quality, filled: false)
                    }
                }
                .padding(.trailing, 8)
                .padding(.bottom, 9)
            }
    }

    /// 封面上的小标签：实心是白底黑字，空心是白色描边白字。
    private func artworkTag(_ text: String, filled: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
        return Text(text)
            .font(Theme.Typo.badge)
            .foregroundStyle(filled ? Theme.ink : Color.white)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(minHeight: 18)
            .background(filled ? Theme.paper : Color.black.opacity(0.28), in: shape)
            .overlay {
                if !filled {
                    shape.strokeBorder(Color.white.opacity(0.75), lineWidth: 1)
                }
            }
    }
}

/// 最新出种横滑货架（Sukebei RSS 刚出种的新作，最多 20 部，避免过多离屏封面探测）。
/// 横版大卡片，和下面「最新上架」的三列竖海报拉开层次；松手按卡片吸附。
struct MagnetFreshShelf: View {
    static let maxItems = 20
    let movies: [MagnetSearchItem]

    var body: some View {
        let shown = Array(movies.prefix(Self.maxItems))
        VStack(alignment: .leading, spacing: 12) {
            MagnetSectionHeader(title: "最新出种", trailing: "按出种时间")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, movie in
                        MagnetFreshCard(movie: movie)
                            .shelfCard()
                            .prefetchArtwork(after: index, in: shown, count: 3, maxPixel: 800) {
                                MagnetCover.highResURL(for: $0.coverURL)?.absoluteString ?? ""
                            }
                            .prefetchStarNames(after: index, in: shown, count: 2)
                    }
                }
                .shelfContent()
            }
            .shelfScrolling()
            .padding(.horizontal, -Theme.contentInset)
        }
    }
}

/// 最新出种还没到时的占位：和卡片同尺寸的灰块，到了不跳。
struct MagnetFreshShelfSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MagnetSectionHeader(title: "最新出种", trailing: "按出种时间")
            HStack(alignment: .top, spacing: 12) {
                ForEach(0 ..< 2, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .fill(Theme.surfaceRaised)
                            .frame(width: MagnetFreshCard.width, height: MagnetFreshCard.width / MagnetLayout.wideRatio)
                        RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                            .fill(Theme.surfaceRaised)
                            .frame(width: MagnetFreshCard.width * 0.78, height: 10)
                        RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                            .fill(Theme.surfaceRaised)
                            .frame(width: MagnetFreshCard.width * 0.42, height: 10)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("最新出种正在加载")
    }
}

/// 影片行：左边封面，右边番号、标题、女优与日期。
struct MagnetListRow: View {
    let movie: MagnetSearchItem

    var body: some View {
        NavigationLink {
            MagnetDetailView(item: movie)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                MagnetCover(url: movie.coverURL, code: movie.code)
                    .frame(width: 72, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 0.5)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    if !movie.code.isEmpty || movie.isFresh {
                        HStack(spacing: 6) {
                            if !movie.code.isEmpty {
                                Text(movie.code)
                                    .font(.scaled(15, weight: .bold))
                                    .foregroundStyle(Theme.textPrimary)
                            }
                            if movie.isFresh {
                                Text("新种")
                                    .font(.scaled(10, weight: .bold))
                                    .foregroundStyle(Theme.onPrimary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.accent, in: Capsule())
                            }
                        }
                    }

                    Text(movie.title)
                        .font(.scaled(13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 0)

                    HStack(spacing: 8) {
                        // 女优在左、日期在右（和海报卡一样）；还没查到女优时左边是空的，日期位置不变
                        MagnetStarNamesText(movie: movie, font: .scaled(12, weight: .semibold), color: Theme.accent)
                        Spacer(minLength: 0)
                        if let date = movie.releaseDate {
                            Text(date)
                                .font(.scaled(12))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                    }
                }
                // 不封顶高度：默认字号下和 96pt 高的封面对齐（女优与日期贴底），字号放大时行跟着变高，标题不会被截掉。
                // maxHeight: .infinity 配合外层 fixedSize，让这一栏和封面一样高、Spacer 才能把底行推到底。
                .frame(maxWidth: .infinity, minHeight: 96, maxHeight: .infinity, alignment: .topLeading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.985))
    }
}

// MARK: - 分类标签、搜索框

/// 浏览分类：和首页频道条（HomeChannelBar）同一个样子——选中项 20pt 加粗、下方 18×3 的棱镜光轨，在分类之间滑动。
struct MagnetCategoryTabs: View {
    @Binding var selection: MagnetCategory
    @Namespace private var underline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 点击区域：每个标签左右各 6pt、整行 44pt 高，标签间的视觉间距仍是 18（6 + 6 + 6）
        HStack(spacing: 6) {
            ForEach(MagnetCategory.allCases) { category in
                let selected = selection == category
                Button {
                    guard !selected else { return }
                    Haptics.select()
                    withAnimation(reduceMotion ? nil : Motion.snappy) { selection = category }
                } label: {
                    Text(category.title)
                        .font(.scaled(selected ? 20 : 16, weight: selected ? .bold : .medium))
                        .heroForeground(secondary: !selected)
                        .frame(height: 44)
                        .overlay(alignment: .bottom) {
                            if selected {
                                Capsule()
                                    .fill(Theme.prismGradient)
                                    .frame(width: 18, height: 3)
                                    .matchedGeometryEffect(id: "magnet.category.underline", in: underline)
                                    .offset(y: -3)
                            }
                        }
                        .padding(.horizontal, 6)
                        .frame(minWidth: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("magnet.category.\(category.rawValue)")
            }
        }
        .padding(.leading, -6)
        .accessibilityElement(children: .contain)
    }
}

/// 搜索框：和首页的搜索框同一个胶囊样子，但这里可以直接输入；键盘上的「搜索」键提交。
/// 空着时右边是系统粘贴按钮（不会弹「允许粘贴」），有内容时换成清除按钮。
struct MagnetSearchField: View {
    @Binding var text: String
    let onSubmit: () -> Void
    let onClear: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(appIconNamed: AppIcon.search.name)
                .font(.scaled(15, weight: Theme.iconWeight))
                .foregroundStyle(Theme.textSecondary)

            TextField("番号、女优，或粘贴磁力链接", text: $text)
                .font(Theme.Typo.row)
                .tint(Theme.accent)
                .submitLabel(.search)
                .focused($focused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit(onSubmit)
                .accessibilityIdentifier("magnet.search")

            if !text.isEmpty {
                Button {
                    onClear()
                } label: {
                    Image(appIconNamed: AppIcon.clear.name)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 点击区域 44×44，但不把搜索框撑高（头部这一行是固定 38pt）
                .padding(.vertical, -3)
                .accessibilityLabel("清除搜索")
            } else {
                PasteButton(payloadType: String.self) { strings in
                    guard let first = strings.first else { return }
                    Task { @MainActor in text = first.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.roundedRectangle(radius: Theme.Radius.chip))
                .tint(Theme.surfaceHigh)
                .foregroundStyle(Theme.textPrimary)
                // 系统粘贴按钮的点击区域只能跟着按钮大小走：从 mini 放大到 small
                .controlSize(.small)
                .accessibilityIdentifier("magnet.paste")
            }
        }
        .padding(.leading, Theme.Space.md + 2)
        .padding(.trailing, text.isEmpty ? 6 : 0)
        .frame(minHeight: 40)
        .heroFieldChrome(focused: focused)
    }
}

// MARK: - 专题与女优

/// 专题里的片商卡片：片商缩写、名称、常见番号前缀，右边淡淡的片商名水印。
struct MagnetStudioCard: View {
    let studio: MagnetStudio

    var body: some View {
        HStack(spacing: 14) {
            Text(studio.monogram)
                .font(.display(17))
                .foregroundStyle(Theme.accent)
                .frame(width: 56, height: 56)
                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(studio.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(studio.codeHint)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 0)

            Image(appIconNamed: AppIcon.forward.name)
                .font(.scaled(13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .background(alignment: .bottomTrailing) {
            Text(studio.title)
                .font(.display(64))
                .foregroundStyle(Color.primary.opacity(0.05))
                .lineLimit(1)
                .fixedSize()
                .offset(x: 6, y: 18)
                .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .surfaceCard()
    }
}

/// 女优分类里的一格：圆头像加姓名。
struct MagnetStarGridCell: View {
    let star: MagnetStarItem
    /// 已经喜欢：头像右下角一个小红心
    var favorite = false

    var body: some View {
        VStack(spacing: 8) {
            MagnetStarAvatar(star: star, size: 84)
                .overlay(alignment: .bottomTrailing) {
                    if favorite { FavoriteHeartBadge().offset(x: -2, y: -2) }
                }
            Text(star.name)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// 喜欢的女优头像角上的小心形：琥珀心放在页面底色的圆里，压在任何头像上都看得清
struct FavoriteHeartBadge: View {
    var size: CGFloat = 22

    var body: some View {
        Image(appIconNamed: AppIcon.heartFill.name)
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(Theme.accent)
            .frame(width: size, height: size)
            .background(Theme.pageBackground, in: Circle())
            .overlay { Circle().strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline) }
            .accessibilityHidden(true)
    }
}

/// 女优列表顶部「我喜欢的」：按喜欢的时间排的一行头像，横向滑动。长按可以取消喜欢。
struct FavoriteStarsRow: View {
    @ObservedObject private var favorites = FavoriteStarStore.shared

    var body: some View {
        if !favorites.items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                MagnetSectionHeader(title: "我喜欢的", trailing: "\(favorites.items.count) 位")
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(favorites.items) { entry in
                            let star = entry.item
                            NavigationLink {
                                StarMoviesView(star: star)
                            } label: {
                                VStack(spacing: 6) {
                                    MagnetStarAvatar(star: star, size: 64)
                                    Text(star.name)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                }
                                .frame(width: 72)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.pressable(scale: 0.95))
                            .accessibilityIdentifier("magnet.favorite.\(star.id)")
                            .contextMenu {
                                Button(role: .destructive) {
                                    Haptics.select()
                                    withAnimation(Motion.smooth) { _ = favorites.toggle(star) }
                                } label: {
                                    Label("取消喜欢", image: AppIcon.heart.name)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.contentInset)
                }
                .scrollIndicators(.hidden)
                .padding(.horizontal, -Theme.contentInset)
            }
            .transition(.opacity)
        }
    }
}

/// 搜索结果里「匹配女优」的横向卡片。
struct MagnetStarChip: View {
    let star: MagnetStarItem

    var body: some View {
        HStack(spacing: 10) {
            MagnetStarAvatar(star: star, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(star.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("查看她的作品")
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
            }

            Image(appIconNamed: AppIcon.forward.name)
                .font(.scaled(11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .frame(minHeight: 56)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        }
    }
}

// MARK: - 栏目标题

/// 栏目标题：和首页货架标题（ShelfHeader）一致，18pt 粗体，右边一行浅色说明。
struct MagnetSectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.scaled(18, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.scaled(12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

// MARK: - 按钮样式

/// 圆角矩形按钮：实心金色（主操作）或描边（次操作），高 44。
struct MagnetActionStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.scaled(14, weight: prominent ? .bold : .semibold))
            .foregroundStyle(prominent ? Theme.onPrimary : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                    .fill(prominent ? Theme.primaryAction : Color.clear)
            }
            .overlay {
                if !prominent {
                    RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.88 : 1) : 0.4)
            .animation(reduceMotion ? nil : Motion.snappy, value: configuration.isPressed)
    }
}

// MARK: - 状态：加载中、出错、为空

/// 加载中：用占位块撑出版面，不再只放一个转圈。占位块不做循环动画。
struct MagnetLoadingView: View {
    enum Style { case grid, list, avatars }

    let style: Style

    var body: some View {
        Group {
            switch style {
            case .grid:
                LazyVGrid(columns: MagnetLayout.posterColumns, spacing: 16) {
                    ForEach(0 ..< 6, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
                                .fill(Theme.surfaceRaised)
                                .aspectRatio(MagnetLayout.posterRatio, contentMode: .fit)
                            bar(widthFactor: 0.92)
                            bar(widthFactor: 0.6)
                        }
                    }
                }
            case .list:
                VStack(spacing: 14) {
                    ForEach(0 ..< 4, id: \.self) { _ in
                        HStack(alignment: .top, spacing: 12) {
                            RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
                                .fill(Theme.surfaceRaised)
                                .frame(width: 72, height: 96)
                            VStack(alignment: .leading, spacing: 8) {
                                bar(widthFactor: 0.3)
                                bar(widthFactor: 0.95)
                                bar(widthFactor: 0.7)
                            }
                            .padding(.top, 4)
                        }
                    }
                }
            case .avatars:
                LazyVGrid(columns: MagnetLayout.avatarColumns, spacing: 20) {
                    ForEach(0 ..< 6, id: \.self) { _ in
                        VStack(spacing: 8) {
                            Circle().fill(Theme.surfaceRaised).frame(width: 84, height: 84)
                            bar(widthFactor: 0.6)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在加载")
    }

    private func bar(widthFactor: CGFloat) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                .fill(Theme.surfaceRaised)
                .frame(width: proxy.size.width * widthFactor)
        }
        .frame(height: 10)
    }
}

/// 加载失败：说明原因，给出「重新加载」。
struct MagnetErrorState: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            EmptyStateMark(.alert, size: 104)

            Text("加载未完成")
                .font(.headline)

            Text(message)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            Button("重新加载", action: retry)
                .buttonStyle(MagnetActionStyle(prominent: true))
                .frame(maxWidth: 200)
            .padding(.top, 8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .surfaceCard()
    }
}

/// 为空：一个图标加一两句话。
struct MagnetEmptyState: View {
    let icon: AppIcon
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 14) {
            EmptyStateMark(icon, size: 104)
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 分页影片网格（女优页、片商页共用）

/// 一页页加载的海报网格：加载中、失败重试、空列表、网格加底部翻页提示。
struct MagnetMovieGridFeed: View {
    let emptyText: String
    let movies: [MagnetSearchItem]
    let isLoading: Bool
    let errorText: String?
    let paging: PagingState
    let retry: () -> Void
    let loadMore: () -> Void

    var body: some View {
        if isLoading {
            MagnetLoadingView(style: .grid)
        } else if let errorText {
            MagnetErrorState(message: errorText, retry: retry)
        } else if movies.isEmpty {
            MagnetEmptyState(icon: .archive, title: emptyText)
        } else {
            VStack(spacing: 8) {
                MagnetPosterGrid(movies: movies, loadMore: loadMore)
                PagingFooter(
                    isLoading: paging.isLoadingMore,
                    failed: paging.loadMoreFailed,
                    retry: loadMore
                )
            }
        }
    }
}
