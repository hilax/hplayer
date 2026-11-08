import SwiftUI

// MARK: - 频道分类标签栏 (AnimeChannelBar)
//
// 推荐 + 各频道横向标签，选中项白字加粗、下方一条金色滑条（滑条用 matchedGeometryEffect
// 在标签之间平移，和 App 其余分段选择器一致）。nil 代表「推荐」。

struct AnimeChannelBar: View {
    let channels: [AnimeChannel]
    @Binding var selectedChannelId: Int?
    var onSelect: (Int?) -> Void

    @Namespace private var underline

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                tab(title: "推荐", id: nil)
                ForEach(channels) { channel in
                    tab(title: channel.name, id: channel.id)
                }
            }
            .padding(.horizontal, Theme.contentInset)
            .padding(.top, 2)
        }
    }

    private func tab(title: String, id: Int?) -> some View {
        let isSelected = (selectedChannelId == id)
        return Button {
            Haptics.select()
            withAnimation(Motion.snappy) { onSelect(id) }
        } label: {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textTertiary)
                ZStack {
                    if isSelected {
                        Capsule()
                            .fill(Theme.primaryAction)
                            .frame(width: 22, height: 3)
                            .matchedGeometryEffect(id: "anime.channel.underline", in: underline)
                    } else {
                        Capsule().fill(Color.clear).frame(width: 22, height: 3)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.94))
        .accessibilityIdentifier("anime.channel.\(id.map(String.init) ?? "recommend")")
    }
}

// MARK: - 轮播大图 (AnimeHeroBanner)

struct AnimeHeroBanner: View {
    let banners: [AnimeBanner]

    @State private var currentIndex = 0

    var body: some View {
        if banners.isEmpty {
            EmptyView()
        } else {
            // 不做自动轮播：定时器会让外层 ScrollView 每几秒重排一次，
            // 也违反界面规范「不做无限循环动画」。用户手动左右滑动即可。
            TabView(selection: $currentIndex) {
                ForEach(Array(banners.enumerated()), id: \.element.id) { index, banner in
                    NavigationLink(value: AnimeDetailRoute(animeId: banner.vid ?? banner.id)) {
                        bannerCard(banner: banner)
                    }
                    .buttonStyle(.plain)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .frame(height: 170)
            .padding(.horizontal, Theme.contentInset)
        }
    }

    private func bannerCard(banner: AnimeBanner) -> some View {
        ZStack(alignment: .bottomLeading) {
            // 背景封面图（通过 HPlayer 专属 ImagePipeline 磁盘与内存缓存）
            ArtworkView(urlString: banner.safePicURLString, title: banner.displayTitle,
                        maxPixel: ArtworkSize.hero, loading: .clear, drawsFallback: false)
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            // 渐变蒙层
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(0.3),
                    Color.black.opacity(0.85)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // 文字与更新信息
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("HOT 热播")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(Theme.onPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.gold, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

                    if !banner.displayRemarks.isEmpty {
                        Text(banner.displayRemarks)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.goldLight)
                            .lineLimit(1)
                    }
                }

                Text(banner.displayTitle)
                    .font(.display(16))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !banner.displayDesc.isEmpty {
                    Text(banner.displayDesc)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondaryOnArtwork)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
    }
}

// MARK: - 动漫海报卡片 (AnimePosterCard)
//
// 横滑货架和两列网格共用这一张卡片：固定宽高、同一套文字行数，
// 保证任何一屏里所有卡片的几何尺寸完全一致，不会出现高低错落。

struct AnimePosterCard: View {
    let item: AnimeVideoItem
    var width: CGFloat = 105

    private var posterHeight: CGFloat { width * 1.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                // 封面（基于 ImagePipeline 磁盘+内存缓存与异步解码，自带固定 frame）
                PosterArtwork(urlString: item.safePicURLString, title: item.name, width: width)
                    .allowsHitTesting(false)

                // 右下角连载状态角标
                if let continu = item.continu, !continu.isEmpty {
                    Text(continu)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.gold)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(4)
                }
            }
            .frame(width: width, height: posterHeight, alignment: .bottomTrailing)

            // 标题与分类：宽度锁死，长片名统一尾部截断
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: width, alignment: .leading)
        }
        .frame(width: width, alignment: .top)
    }

    private var subtitle: String {
        let tags = item.tags.prefix(2).joined(separator: ", ")
        guard let year = item.year, !year.isEmpty else { return tags }
        return tags.isEmpty ? year : "\(tags) · \(year)"
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
