import SwiftUI

// MARK: - 轮播大图 (AnimeHeroBanner)
//
// 圆角卡片 + 底部暗色渐变 + 玻璃角标，和片库海报的角标、首页精选的指示条同一套语言。

struct AnimeHeroBanner: View {
    static let height: CGFloat = 196

    let banners: [AnimeBanner]

    var body: some View {
        if !banners.isEmpty {
            // 和首页「推荐」同一个轮播：图不动、下一张从右下以弧形揭出来，只有文字左右滑；
            // 每 4 秒自动翻一张，也能手动拖，首尾相接。
            LoopingCarousel(items: banners, label: "热播轮播", positionIdentifier: "anime.bannerPosition") { banner in
                artwork(banner)
            } foreground: { banner in
                caption(banner)
            } hitArea: { banner in
                NavigationLink(value: AnimeDetailRoute(animeId: banner.vid ?? banner.id)) {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(banner.displayTitle)
                .accessibilityIdentifier("anime.banner.\(banner.id)")
            }
            .frame(height: Self.height)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }

    /// 画面层：封面 + 只压下半截的暗色渐变（上半截保留原图色彩，下半截保证白字可读）
    private func artwork(_ banner: AnimeBanner) -> some View {
        ZStack {
            Theme.surfaceRaised
            // 图片只铺在透明底上，「填满」裁出来的大图不会把卡片撑大
            Color.clear
                .overlay {
                    ArtworkView(urlString: banner.safePicURLString, title: banner.displayTitle,
                                maxPixel: ArtworkSize.hero, loading: .clear, drawsFallback: false)
                        .scaledToFill()
                }
                .clipped()
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.35),
                    .init(color: Color.black.opacity(0.45), location: 0.65),
                    .init(color: Color.black.opacity(0.82), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    /// 文字层：玻璃「热播」角标 + 连载信息、片名、简介。翻页时只有这一层左右滑。
    private func caption(_ banner: AnimeBanner) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("热播")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .glassBadge()

                if !banner.displayRemarks.isEmpty {
                    Text(banner.displayRemarks)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondaryOnArtwork)
                        .lineLimit(1)
                }
            }

            Text(banner.displayTitle)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)

            if !banner.displayDesc.isEmpty {
                Text(banner.displayDesc)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondaryOnArtwork)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .padding(.trailing, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }
}

// MARK: - 动漫海报卡片 (AnimePosterCard)
//
// 和片库的剧集卡（SeriesPosterCard）同一套规格：2:3 海报、左上角玻璃角标、
// 13pt 标题 + 11pt 次要信息。横滑货架和网格共用，宽度锁死、文字行数固定，任何一屏都对齐。

struct AnimePosterCard: View {
    let item: AnimeVideoItem
    var width: CGFloat = 105

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            PosterArtwork(urlString: item.safePicURLString, title: item.name, width: width)
                .allowsHitTesting(false)
                .overlay(alignment: .topLeading) {
                    // 连载状态（「更新至 12 集」「已完结」）。之前是金色字压黑底，
                    // 金色在浅色模式下是深灰，看不清；统一换成白字玻璃角标。
                    if let continu = item.continu?.trimmingCharacters(in: .whitespaces), !continu.isEmpty {
                        EpisodeCountBadge(text: continu)
                            .frame(maxWidth: width - 12, alignment: .leading)
                            .padding(6)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .secondaryTextStyle()
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
        .frame(width: width, alignment: .top)
        .accessibilityElement(children: .combine)
    }

    /// 「类型 · 年份」；两者都没有时写「在线动漫」，保证每张卡片都是两行字、高度一致。
    private var subtitle: String {
        let tags = item.tags.prefix(2).joined(separator: " · ")
        let year = item.year?.trimmingCharacters(in: .whitespaces) ?? ""
        switch (tags.isEmpty, year.isEmpty) {
        case (false, false): return "\(tags) · \(year)"
        case (false, true): return tags
        case (true, false): return year
        case (true, true): return "在线动漫"
        }
    }
}

// MARK: - 选集方块矩阵 (AnimeEpisodeMatrix)

/// 选集格子与剧集详情页（SeriesDetailView.episodeCell）同一套视觉规格：
/// 48pt 高、当前集整块填金、看完置灰打勾、看到一半画底部金色进度线。
/// 这里只对齐视觉，不共用代码，剧集页保持原样不动。
struct AnimeEpisodeMatrix: View {
    let episodes: [String]
    let activeEpisode: String?
    var isDescending: Bool = false
    /// 单集观看进度（0…1），由详情页按标题从播放记录里查。
    var progress: (String) -> Double? = { _ in nil }
    var onSelect: (String) -> Void

    private var orderedEpisodes: [String] {
        if isDescending {
            return Array(episodes.reversed())
        } else {
            return episodes
        }
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
            ForEach(orderedEpisodes, id: \.self) { ep in
                cell(ep)
            }
        }
        .id("anime-episode-grid-\(isDescending ? "desc" : "asc")-\(episodes.count)")
    }

    private func cell(_ ep: String) -> some View {
        let isCurrent = (ep == activeEpisode)
        let value = progress(ep) ?? 0
        let finished = value >= 0.92
        return Button {
            Haptics.tap()
            onSelect(ep)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                    .fill(isCurrent ? Theme.gold : Theme.surface)
                Text(formatEpisodeTitle(ep))
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isCurrent ? Theme.onPrimary : (finished ? Theme.textTertiary : Theme.textPrimary))
                if finished && !isCurrent {
                    Image(icon: .check)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(6)
                }
            }
            .frame(height: 48)
            .overlay(alignment: .bottom) {
                if value > 0.02 && !finished {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(isCurrent ? Theme.onPrimary.opacity(0.55) : Theme.gold)
                            .frame(width: max(4, (proxy.size.width - 16) * value), height: 2)
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
        .buttonStyle(.pressable)
    }

    private func formatEpisodeTitle(_ raw: String) -> String {
        // "第01集" -> "01", "第108集" -> "108"
        var clean = raw.replacingOccurrences(of: "第", with: "")
                       .replacingOccurrences(of: "集", with: "")
                       .replacingOccurrences(of: "话", with: "")
                       .trimmingCharacters(in: .whitespaces)
        if clean.count == 1 && clean.allSatisfy({ $0.isNumber }) {
            clean = "0" + clean
        }
        return clean.isEmpty ? raw : clean
    }
}
