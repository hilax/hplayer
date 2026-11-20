import SwiftUI

// 动漫频道顶部的热播轮播和首页共用 ChannelHeroSection（见 ChannelHero.swift）。
// 选集统一使用 UnifiedEpisodeShelf（见 EpisodeShelfView.swift）。

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
                    .font(.scaled(13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.scaled(11))
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
