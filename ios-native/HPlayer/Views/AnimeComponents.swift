import SwiftUI

// 动漫频道顶部的热播轮播和首页共用 ChannelHeroSection（见 ChannelHero.swift）。

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
        AnimeEpisodeCell(title: ep, isCurrent: ep == activeEpisode, progress: progress(ep) ?? 0) {
            onSelect(ep)
        }
    }

}

// MARK: - 选集格子 (AnimeEpisodeCell)

/// 一集的格子：48pt 高、当前集整块填主色、看完置灰打勾、看到一半画底部进度线。
/// 详情页的横排选集、全部选集面板里的网格都用它。
struct AnimeEpisodeCell: View {
    let title: String
    let isCurrent: Bool
    /// 0…1；≥ 0.92 算看完
    var progress: Double = 0
    let onTap: () -> Void

    private var finished: Bool { progress >= 0.92 }

    var body: some View {
        Button {
            Haptics.tap()
            onTap()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                    .fill(isCurrent ? Theme.gold : Theme.surface)
                Text(Self.shortTitle(title))
                    .font(.scaled(16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isCurrent ? Theme.onPrimary : (finished ? Theme.textTertiary : Theme.textPrimary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 4)
                if finished && !isCurrent {
                    Image(icon: .check)
                        .font(.scaled(8, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(6)
                }
            }
            .frame(height: 48)
            .overlay(alignment: .bottom) {
                if progress > 0.02 && !finished {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(isCurrent ? Theme.onPrimary.opacity(0.55) : Theme.gold)
                            .frame(width: max(4, (proxy.size.width - 16) * progress), height: 2)
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
        .accessibilityLabel(title)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// "第01集" -> "01"，"第108集" -> "108"；不是这种格式的原样显示（「特别篇」「OVA」）
    static func shortTitle(_ raw: String) -> String {
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
