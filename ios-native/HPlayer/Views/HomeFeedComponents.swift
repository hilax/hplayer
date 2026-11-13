import SwiftUI
import UIKit

// MARK: - 首页轮播的每一张

/// 首页「推荐」顶部轮播的一张：片库精选和在线动漫的热播横图穿插着放。
struct HomeSlide: Identifiable {
    enum Content {
        case library(HomeMediaItem)
        case anime(AnimeBanner)
        /// 磁力页「最新上架」：JavBus 的大封面（约 800×538 的横版封套）
        case magnet(MagnetSearchItem)
    }

    let id: String
    let content: Content

    /// 片库影片有没有能直接铺满 16:9 卡片的横图：背景图，或者 DMM 那种本来就是横版的封套。
    static func hasWideArtwork(_ item: HomeMediaItem) -> Bool {
        !item.backgroundURL.isEmpty || item.metadata?.isWideJacket == true
    }

    /// 这一张显示的图（取色也用它）
    var palette: HeroPalette.Source {
        switch content {
        case .library(let item):
            if Self.hasWideArtwork(item) {
                return .init(key: HomeArtwork.heroURL(item), fallback: item.posterURL)
            }
            // 只有竖海报：卡片铺的是这张海报的虚化，按整张海报取色
            return .init(key: item.posterURL, aspect: 2.0 / 3.0)
        case .anime(let banner):
            return .init(key: banner.safePicURLString)
        case .magnet(let movie):
            return .init(key: Self.magnetCover(movie), fallback: movie.coverURL?.absoluteString ?? "")
        }
    }

    /// 磁力影片用大封面；不是 JavBus 小图地址时退回列表里的封面
    static func magnetCover(_ movie: MagnetSearchItem) -> String {
        (MagnetCover.highResURL(for: movie.coverURL) ?? movie.coverURL)?.absoluteString ?? ""
    }

    /// 磁力页的轮播：最新上架的前 limit 部（有封面的）
    static func magnet(_ movies: [MagnetSearchItem], limit: Int = 6) -> [HomeSlide] {
        movies.filter { $0.coverURL != nil }.prefix(limit).map { HomeSlide(id: "magnet|\($0.id)", content: .magnet($0)) }
    }

    /// 片库频道的轮播：最近加入的电影，有横版背景图的排前面，最多 limit 张。
    static func recentLibrary(_ snapshot: HomeSnapshot, limit: Int = 6) -> [HomeSlide] {
        let recent = Array(snapshot.movies.reversed())
        let ordered = recent.filter(hasWideArtwork) + recent.filter { !hasWideArtwork($0) }
        return ordered.prefix(limit).map { HomeSlide(id: "library|\($0.id)", content: .library($0)) }
    }

    /// 动漫频道的轮播：动漫接口的热播横图。
    static func anime(_ banners: [AnimeBanner]) -> [HomeSlide] {
        banners.filter { !$0.img.isEmpty }.map { HomeSlide(id: "anime|\($0.id)", content: .anime($0)) }
    }

    /// 片库精选和热播横图交替排：精选、热播、精选、热播……一边没了就接着放另一边，最多 limit 张。
    static func interleave(featured: [HomeMediaItem], banners: [AnimeBanner], limit: Int = 8) -> [HomeSlide] {
        let library = featured.map { HomeSlide(id: "library|\($0.id)", content: .library($0)) }
        let online = banners.map { HomeSlide(id: "anime|\($0.id)", content: .anime($0)) }
        var result: [HomeSlide] = []
        var index = 0
        while result.count < limit, index < max(library.count, online.count) {
            if index < library.count { result.append(library[index]) }
            if result.count < limit, index < online.count { result.append(online[index]) }
            index += 1
        }
        return result
    }
}

/// 轮播一张的画面层：图（只有竖海报时铺虚化底、海报立在右边）+ 底部暗色渐变 + 右上角角标。
/// 翻页时这一层原地不动，由轮播的弧形遮罩揭开。
struct HomeSlideArtwork: View {
    let slide: HomeSlide

    var body: some View {
        ZStack {
            switch slide.content {
            case .library(let item):
                if HomeSlide.hasWideArtwork(item) {
                    HomeSlideImage(urlString: HomeArtwork.heroURL(item), fallback: item.posterURL, title: item.title)
                } else {
                    posterOnlyArtwork(item)
                }
            case .anime(let banner):
                HomeSlideImage(urlString: banner.safePicURLString, fallback: "", title: banner.displayTitle)
            case .magnet(let movie):
                HomeSlideImage(urlString: HomeSlide.magnetCover(movie), fallback: movie.coverURL?.absoluteString ?? "",
                               title: movie.code)
            }
            LinearGradient(stops: [
                .init(color: .clear, location: 0.38),
                .init(color: .black.opacity(Theme.Opacity.medium), location: 0.66),
                .init(color: .black.opacity(Theme.Opacity.heavy), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .overlay(alignment: .topTrailing) { badge }
        .clipped()
    }

    private var badge: some View {
        let text: String
        switch slide.content {
        case .library: text = "精选"
        case .anime: text = "热播"
        case .magnet: text = "最新"
        }
        // 轮播卡片上的角标：画面本身已经够醒目，用暗底白字，不再压一块琥珀
        return TagBadge(text: text, style: .onArtwork)
            .padding(Theme.Space.md)
    }

    /// 只有竖海报：铺一层这张海报的虚化，海报本身立在右边，不硬裁成横图。
    private func posterOnlyArtwork(_ item: HomeMediaItem) -> some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let posterHeight = height * 0.66
            ZStack(alignment: .trailing) {
                ArtworkView(urlString: item.posterURL, title: "", maxPixel: ArtworkSize.backdrop,
                            loading: .clear, drawsFallback: false)
                    .scaledToFill()
                    .frame(width: proxy.size.width / 3, height: height / 3)
                    .clipped()
                    .blur(radius: 6)
                    .scaleEffect(3.4)
                    .frame(width: proxy.size.width, height: height)
                    .clipped()
                    .overlay(Color.black.opacity(Theme.Opacity.faint))
                PosterArtwork(urlString: item.posterURL, title: item.title, width: posterHeight / 1.5)
                    .shadow(color: .black.opacity(Theme.Opacity.medium), radius: 10, y: 4)
                    .padding(.trailing, 22)
                    .offset(y: -height * 0.04)
            }
            .frame(width: proxy.size.width, height: height)
        }
        .background(Theme.surfaceRaised)
    }
}

/// 铺满卡片的图。图只铺在一块透明底上：「填满」裁出来的大图不会把卡片撑大。
struct HomeSlideImage: View {
    let urlString: String
    let fallback: String
    let title: String

    var body: some View {
        Color.clear
            .overlay {
                ArtworkView(urlString: urlString, fallbackURLString: fallback, title: title,
                            maxPixel: ArtworkSize.hero, loading: .clear)
                    .scaledToFill()
            }
            .clipped()
            .background(Theme.surfaceRaised)
    }
}

/// 轮播一张的文字层：左下角白字片名和信息。翻页时揭到一半原地换成下一张。
/// 卡片上不放按钮：点卡片就是播放 / 进详情，更多操作长按卡片。
struct HomeSlideCaption: View {
    let slide: HomeSlide

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            switch slide.content {
            case .library(let item):
                titleBlock(title: item.title, subtitle: librarySubtitle(item))
                    .accessibilityIdentifier("home.heroTitle")
            case .anime(let banner):
                titleBlock(title: banner.displayTitle,
                           subtitle: ["在线动漫", banner.displayRemarks].filter { !$0.isEmpty }.joined(separator: " · "))
            case .magnet(let movie):
                titleBlock(title: movie.code.isEmpty ? movie.title : movie.code,
                           subtitle: [movie.stars.first?.name ?? "", movie.releaseDate ?? ""].filter { !$0.isEmpty }
                               .joined(separator: " · "))
            }
        }
        .padding(.leading, 14)
        .padding(.bottom, 12)
        .padding(.trailing, trailingInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }

    /// 右边留给页码点；只有竖海报的片库影片，海报立在右边，文字再让开一些
    private var trailingInset: CGFloat {
        if case .library(let item) = slide.content, !HomeSlide.hasWideArtwork(item) { return 124 }
        return 64
    }

    private func librarySubtitle(_ item: HomeMediaItem) -> String {
        var parts = ["我的片库"]
        if !item.year.isEmpty { parts.append(item.year) }
        if let genres = item.metadata?.genres, !genres.isEmpty {
            parts.append(genres.prefix(2).joined(separator: " / "))
        }
        if !item.rating.isEmpty { parts.append("★ \(item.rating)") }
        return parts.joined(separator: " · ")
    }

    private func titleBlock(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.scaled(22, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .shadow(color: .black.opacity(Theme.Opacity.medium), radius: 6, y: 1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.scaled(12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(Theme.Opacity.heavy))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 热门新番（三列竖版海报）

/// 首页「热门新番」三列网格里的一张：竖版海报 + 右上角状态角标 + 右下角集数，
/// 下面是片名、右侧「⋮」更多，再下面是播放排名（前三名，强调色）或类型。
/// 整张点进动漫详情；「⋮」是叠在上面的独立按钮，不和详情入口嵌套。
struct HomeAnimeGridCard: View {
    let item: AnimeVideoItem
    /// 在「最多播放」里排第几（1 起）；前三名显示排名
    let rank: Int
    let width: CGFloat
    @ObservedObject private var watchlist = AnimeWatchlistStore.shared

    private var posterHeight: CGFloat { width * 1.5 }

    var body: some View {
        AnimeDetailLink(animeId: item.id) {
            VStack(alignment: .leading, spacing: 6) {
                PosterArtwork(urlString: item.safePicURLString, title: item.name, width: width)
                    .allowsHitTesting(false)
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.clear, .black.opacity(Theme.Opacity.strong)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let episodes = AnimeEpisodeText.short(item) {
                            Text(episodes)
                                .font(.scaled(10, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 7)
                                .padding(.bottom, 5)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if let status = AnimeEpisodeText.status(item) {
                            TagBadge(text: status.title, style: status.highlighted ? .accent : .onArtwork)
                                .padding(Theme.Space.sm)
                        }
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.scaled(13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .padding(.trailing, 22)
                    Text(subtitle)
                        .font(.scaled(11, weight: rank <= 3 ? .medium : .regular))
                        .foregroundStyle(rank <= 3 ? Theme.accent : Theme.textSecondary)
                        .lineLimit(1)
                }
                .frame(width: width, alignment: .leading)
            }
            .frame(width: width, alignment: .top)
        }
        .overlay(alignment: .topTrailing) {
            moreMenu
                .offset(x: 13, y: posterHeight - 8)
        }
    }

    private var subtitle: String {
        if rank <= 3 { return "最多播放第 \(rank) 名" }
        let tags = item.tags.prefix(2).joined(separator: " · ")
        return tags.isEmpty ? (item.year ?? "在线动漫") : tags
    }

    private var moreMenu: some View {
        let following = watchlist.isWatched(id: item.id)
        return Menu {
            Button(following ? "取消追番" : "加入追番",
                   systemImage: following ? AppIcon.heartFill.name : AppIcon.heart.name) {
                Haptics.tap()
                watchlist.toggle(item: item)
            }
            Button("复制片名", systemImage: AppIcon.copy.name) {
                UIPasteboard.general.string = item.name
            }
        } label: {
            Image(systemName: AppIcon.more.name)
                .font(.scaled(13, weight: .semibold))
                .rotationEffect(.degrees(90))
                .foregroundStyle(Theme.textTertiary)
                // 看上去还是一个小「⋮」，点按区域 44pt
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("更多操作：\(item.name)")
        .accessibilityIdentifier("home.trending.more.\(item.id)")
    }
}

/// 动漫接口的连载字段五花八门（「28|周四五11:00更」「6#周六23:00更」「更新至26集」「全52集」「抢先版 AI修复」），
/// 卡片上只要一个短的集数和一个状态。
enum AnimeEpisodeText {
    struct Status: Equatable {
        let title: String
        let highlighted: Bool
    }

    /// 右下角的集数：「更新至 28 集」「全 52 集」；认不出就原样给（太长的不显示）。
    static func short(_ item: AnimeVideoItem) -> String? {
        let raw = (item.continu ?? "").trimmingCharacters(in: .whitespaces)
        if item.isend == 1, let total = item.total, total > 0 { return "全 \(total) 集" }
        if let number = leadingNumber(raw) { return "更新至 \(number) 集" }
        if let number = number(in: raw, after: "更新至") { return "更新至 \(number) 集" }
        if let number = number(in: raw, after: "全") { return "全 \(number) 集" }
        guard !raw.isEmpty, raw.count <= 8 else { return nil }
        return raw
    }

    /// 右上角的状态：完结（灰），连载中写着「更」的（强调色「更新」）；其他不标。
    static func status(_ item: AnimeVideoItem) -> Status? {
        let raw = item.continu ?? ""
        if item.isend == 1 || raw.hasPrefix("全") || raw.contains("完结") { return Status(title: "完结", highlighted: false) }
        if raw.contains("更") { return Status(title: "更新", highlighted: true) }
        return nil
    }

    /// 「28|周四…」「6#周六…」开头的数字
    private static func leadingNumber(_ raw: String) -> Int? {
        let digits = raw.prefix { $0.isNumber }
        guard !digits.isEmpty, raw.dropFirst(digits.count).first.map({ $0 == "|" || $0 == "#" }) == true else { return nil }
        return Int(digits)
    }

    private static func number(in raw: String, after prefix: String) -> Int? {
        guard let range = raw.range(of: prefix) else { return nil }
        let digits = raw[range.upperBound...].drop { $0 == " " }.prefix { $0.isNumber }
        return Int(digits)
    }
}

// MARK: - 固定行数的小网格

/// 首页里只有几张卡片的网格（热门新番六张）：按列数排成几行，一次建好。
/// 不用 LazyVGrid——懒加载网格在屏幕外不建视图，首页往下才有的卡片在滚到之前根本不存在。
struct FixedGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    let columns: Int
    var spacing: CGFloat = 10
    var rowSpacing: CGFloat = 16
    @ViewBuilder let cell: (Int, Item) -> Cell

    var body: some View {
        let rows = stride(from: 0, to: items.count, by: max(columns, 1)).map { start in
            Array(start..<min(start + columns, items.count))
        }
        VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(rows, id: \.first) { row in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(row, id: \.self) { index in
                        cell(index, items[index])
                    }
                }
            }
        }
    }
}
