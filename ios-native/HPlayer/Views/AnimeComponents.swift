import SwiftUI

// MARK: - 轮播大图 (AnimeHeroBanner)
//
// 圆角卡片 + 底部暗色渐变 + 玻璃角标，和片库海报的角标、首页精选的指示条同一套语言。

struct AnimeHeroBanner: View {
    static let height: CGFloat = 196

    let banners: [AnimeBanner]

    @State private var currentIndex = 0
    /// iOS 17 翻页滚动视图当前停在哪一页（scrollPosition 绑定）
    @State private var scrolledIndex: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !banners.isEmpty {
            VStack(spacing: 8) {
                // 不做自动轮播：定时器会让外层 ScrollView 每几秒重排一次，
                // 也违反界面规范「不做无限循环动画」。用户手动左右滑动即可。
                pager
                    .frame(height: Self.height)

                if banners.count > 1 {
                    indicator
                }
            }
        }
    }

    /// iOS 17 起用按页吸附的横向滚动，翻页时封面比卡片慢半拍（视差）；iOS 16 用系统分页 TabView。
    @ViewBuilder private var pager: some View {
        if #available(iOS 17.0, *) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(banners.enumerated()), id: \.element.id) { index, banner in
                        link(banner)
                            .containerRelativeFrame(.horizontal)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $scrolledIndex)
            .onChange(of: scrolledIndex) { value in
                if let value, value != currentIndex { currentIndex = value }
            }
        } else {
            TabView(selection: $currentIndex) {
                ForEach(Array(banners.enumerated()), id: \.element.id) { index, banner in
                    link(banner).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }

    private func link(_ banner: AnimeBanner) -> some View {
        NavigationLink(value: AnimeDetailRoute(animeId: banner.vid ?? banner.id)) {
            bannerCard(banner: banner)
        }
        .buttonStyle(.pressable(scale: 0.98))
        .accessibilityIdentifier("anime.banner.\(banner.id)")
    }

    private func select(_ index: Int) {
        withAnimation(reduceMotion ? nil : Motion.smooth) {
            currentIndex = index
            scrolledIndex = index
        }
    }

    private var indicator: some View {
        HStack(spacing: 4) {
            ForEach(banners.indices, id: \.self) { index in
                Capsule()
                    .fill(index == currentIndex ? Theme.textPrimary : Theme.textTertiary.opacity(0.5))
                    .frame(width: index == currentIndex ? 14 : 4, height: 4)
                    .contentShape(Rectangle().inset(by: -8))
                    .onTapGesture { select(index) }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 12)
        .animation(reduceMotion ? nil : Motion.snappy, value: currentIndex)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("热播轮播")
        .accessibilityValue("第 \(currentIndex + 1) 张，共 \(banners.count) 张")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: select((currentIndex + 1) % banners.count)
            case .decrement: select((currentIndex + banners.count - 1) % banners.count)
            @unknown default: break
            }
        }
    }

    private func bannerCard(banner: AnimeBanner) -> some View {
        ZStack(alignment: .bottomLeading) {
            Theme.surfaceRaised

            // 背景封面图（通过 HPlayer 专属 ImagePipeline 磁盘与内存缓存）
            ArtworkView(urlString: banner.safePicURLString, title: banner.displayTitle,
                        maxPixel: ArtworkSize.hero, loading: .clear, drawsFallback: false)
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .bannerParallax()
                .clipped()
                .allowsHitTesting(false)

            // 只压下半部分：上半部分保留原图色彩，下半部分保证白字可读
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.35),
                    .init(color: Color.black.opacity(0.45), location: 0.65),
                    .init(color: Color.black.opacity(0.82), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// 轮播翻页时封面比卡片慢半拍：卡片滑走一整页，封面只挪 1/5，看起来像隔着一层玻璃。
    /// 只在 iOS 17 的翻页滚动视图里生效；减弱动态效果时关闭。
    func bannerParallax() -> some View { modifier(BannerParallax()) }
}

private struct BannerParallax: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            if reduceMotion {
                content
            } else {
                content.scrollTransition(.interactive, axis: .horizontal) { view, phase in
                    view
                        .scaleEffect(1.12)
                        .offset(x: -phase.value * 56, y: 0)
                }
            }
        } else {
            content
        }
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
