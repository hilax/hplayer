import SwiftUI
import UIKit

// MARK: - 首页轮播的每一张

/// 首页「推荐」顶部轮播的一张：片库精选和在线动漫的热播横图穿插着放。
struct HomeSlide: Identifiable {
    enum Content {
        case library(HomeMediaItem)
        case anime(AnimeBanner)
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
        }
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

/// 轮播里一张卡片的画面。片库精选：左下角片名、信息、播放和「影片选项」；
/// 热播动漫：整张点进动漫详情。卡片上的字一律白色，压在底部的暗色渐变上。
struct HomeSlideCard: View {
    let slide: HomeSlide
    var playTitle = "播放"
    var onPlay: () -> Void = {}
    var onOptions: () -> Void = {}

    var body: some View {
        switch slide.content {
        case .library(let item):
            libraryCard(item)
        case .anime(let banner):
            NavigationLink(value: AnimeDetailRoute(animeId: banner.vid ?? banner.id)) {
                ZStack(alignment: .bottomLeading) {
                    artwork(urlString: banner.safePicURLString, fallback: "", title: banner.displayTitle)
                    scrim
                    caption(title: banner.displayTitle,
                            subtitle: ["在线动漫", banner.displayRemarks].filter { !$0.isEmpty }.joined(separator: " · "),
                            trailingInset: 64)
                }
                .overlay(alignment: .topTrailing) { badge("热播") }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("home.slide.anime.\(banner.vid ?? banner.id)")
        }
    }

    private func libraryCard(_ item: HomeMediaItem) -> some View {
        let wide = HomeSlide.hasWideArtwork(item)
        return ZStack(alignment: .bottomLeading) {
            // 点画面任意位置也是播放；旁白只读下面那个「播放」按钮，不重复
            Button(action: onPlay) {
                Group {
                    if wide {
                        artwork(urlString: HomeArtwork.heroURL(item), fallback: item.posterURL, title: item.title)
                    } else {
                        posterOnlyArtwork(item)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)

            scrim

            VStack(alignment: .leading, spacing: 0) {
                caption(title: item.title, subtitle: librarySubtitle(item), trailingInset: 0)
                    .accessibilityIdentifier("home.heroTitle")
                HStack(spacing: 8) {
                    Button(action: onPlay) {
                        HStack(spacing: 5) {
                            Image(systemName: AppIcon.play.name)
                                .font(.system(size: 11, weight: .bold))
                            Text(playTitle)
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(Color.white, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier("home.heroPlay")

                    Button(action: onOptions) {
                        Image(systemName: AppIcon.more.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.22), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("影片选项")
                }
                .padding(.top, 8)
            }
            .padding(.leading, 14)
            .padding(.bottom, 12)
            .padding(.trailing, wide ? 64 : 124)
        }
        .overlay(alignment: .topTrailing) { badge("精选") }
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

    // MARK: 画面

    private func artwork(urlString: String, fallback: String, title: String) -> some View {
        // 图片只铺在一块透明底上：「填满」裁出来的大图不能把卡片撑大（撑大了片名、按钮会被挤出卡片，翻页也对不齐）
        Color.clear
            .overlay {
                ArtworkView(urlString: urlString, fallbackURLString: fallback, title: title,
                            maxPixel: ArtworkSize.hero, loading: .clear)
                    .scaledToFill()
            }
            .clipped()
            .background(Theme.surfaceRaised)
            .allowsHitTesting(false)
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
                    .overlay(Color.black.opacity(0.18))
                PosterArtwork(urlString: item.posterURL, title: item.title, width: posterHeight / 1.5)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                    .padding(.trailing, 22)
                    .offset(y: -height * 0.04)
            }
            .frame(width: proxy.size.width, height: height)
        }
        .background(Theme.surfaceRaised)
        .allowsHitTesting(false)
    }

    /// 只压下半截：上半截保留原图色彩，下半截保证白字可读。
    private var scrim: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0.38),
            .init(color: .black.opacity(0.42), location: 0.66),
            .init(color: .black.opacity(0.74), location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func caption(title: String, subtitle: String, trailingInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .lineLimit(1)
            }
        }
        .padding(.leading, trailingInset > 0 ? 14 : 0)
        .padding(.bottom, trailingInset > 0 ? 12 : 0)
        .padding(.trailing, trailingInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .padding(10)
            .allowsHitTesting(false)
    }
}

// MARK: - 热门新番（三列竖版海报）

/// 首页「热门新番」三列网格里的一张：竖版海报 + 右上角状态角标 + 右下角集数，
/// 下面是片名、右侧「⋮」更多，再下面是播放排名（前三名，玫红）或类型。
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
                        LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let episodes = AnimeEpisodeText.short(item) {
                            Text(episodes)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 7)
                                .padding(.bottom, 5)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if let status = AnimeEpisodeText.status(item) {
                            Text(status.title)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .frame(height: 18)
                                .background(status.highlighted ? Theme.accentFill : Color.black.opacity(0.62),
                                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .padding(6)
                        }
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .padding(.trailing, 22)
                    Text(subtitle)
                        .font(.system(size: 11, weight: rank <= 3 ? .medium : .regular))
                        .foregroundStyle(rank <= 3 ? Theme.accent : Theme.textSecondary)
                        .lineLimit(1)
                }
                .frame(width: width, alignment: .leading)
            }
            .frame(width: width, alignment: .top)
        }
        .overlay(alignment: .topTrailing) {
            moreMenu
                .offset(x: 6, y: posterHeight - 1)
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
                .font(.system(size: 13, weight: .semibold))
                .rotationEffect(.degrees(90))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 30, height: 30)
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

    /// 右上角的状态：完结（灰），连载中写着「更」的（玫红「更新」）；其他不标。
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

// MARK: - 我的片库 · 电影（两列横卡）

/// 片库电影两列横卡：有横版背景图（Cinemeta / TMDB）就用；DMM 这类横版封套直接铺；
/// 只有竖海报的，铺一层虚化再把海报立在中间。右上角评分，下面片名和「年份 · 类型」。
struct LibraryWideCard: View {
    let item: HomeMediaItem
    let width: CGFloat
    let onPlay: () -> Void
    let onDelete: () -> Void
    let onMatch: () -> Void

    private var height: CGFloat { (width * 9 / 16).rounded() }

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 6) {
                artwork
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 0.5)
                    }
                    .overlay(alignment: .topTrailing) {
                        if !item.rating.isEmpty { RatingBadge(rating: item.rating).padding(6) }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 12))
                        .secondaryTextStyle()
                        .lineLimit(1)
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(PosterButtonStyle())
        .accessibilityIdentifier("home.poster.\(item.metadata?.imdbID ?? item.id)")
        .contextMenu {
            Button("播放", systemImage: AppIcon.play.name, action: onPlay)
            Button("匹配封面", systemImage: AppIcon.poster.name, action: onMatch)
            Button(item.isCloud ? "从媒体库移除" : "删除本地文件", systemImage: AppIcon.trash.name, role: .destructive, action: onDelete)
        }
    }

    private var detail: String {
        var parts: [String] = []
        if !item.year.isEmpty { parts.append(item.year) }
        if let genre = item.metadata?.genres.first { parts.append(genre) }
        return parts.isEmpty ? item.sourceLabel : parts.joined(separator: " · ")
    }

    @ViewBuilder private var artwork: some View {
        if !item.backgroundURL.isEmpty {
            ArtworkView(urlString: item.backgroundURL, fallbackURLString: item.posterURL, title: item.title)
                .scaledToFill()
                .frame(width: width, height: height)
                .clipped()
                .allowsHitTesting(false)
        } else if item.metadata?.isWideJacket == true {
            ArtworkView(urlString: item.posterURL, title: item.title)
                .scaledToFill()
                .frame(width: width, height: height)
                .clipped()
                .allowsHitTesting(false)
        } else {
            ZStack {
                ArtworkView(urlString: item.posterURL, title: "", maxPixel: ArtworkSize.backdrop,
                            loading: .neutral, drawsFallback: false)
                    .scaledToFill()
                    .frame(width: width / 3, height: height / 3)
                    .clipped()
                    .blur(radius: 5)
                    .scaleEffect(3.4)
                    .frame(width: width, height: height)
                    .clipped()
                    .overlay(Color.black.opacity(0.15))
                ArtworkView(urlString: item.posterURL, title: item.title)
                    .scaledToFill()
                    .frame(width: height * 0.84 / 1.5, height: height * 0.84)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            }
            .frame(width: width, height: height)
            .background(Theme.surfaceRaised)
            .allowsHitTesting(false)
        }
    }
}
