import SwiftUI

// MARK: - 频道分类胶囊栏 (AnimeChannelBar)

struct AnimeChannelBar: View {
    let channels: [AnimeChannel]
    @Binding var selectedChannelId: Int?
    var onSelect: (Int?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // "全部" 胶囊
                channelPill(title: "全部", isSelected: selectedChannelId == nil) {
                    selectedChannelId = nil
                    onSelect(nil)
                }

                ForEach(channels) { channel in
                    channelPill(title: channel.name, isSelected: selectedChannelId == channel.id) {
                        selectedChannelId = channel.id
                        onSelect(channel.id)
                    }
                }
            }
            .padding(.horizontal, Theme.contentInset)
            .padding(.vertical, 4)
        }
    }

    private func channelPill(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: {
            Haptics.select()
            action()
        }) {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? Theme.onPrimary : Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isSelected ? Theme.primaryAction : Theme.surfaceRaised,
                    in: Capsule()
                )
        }
        .buttonStyle(.pressable)
    }
}

// MARK: - 轮播大图 (AnimeHeroBanner)

struct AnimeHeroBanner: View {
    let banners: [AnimeBanner]
    var onSelect: (AnimeBanner) -> Void

    @State private var currentIndex = 0
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        if banners.isEmpty {
            EmptyView()
        } else {
            TabView(selection: $currentIndex) {
                ForEach(Array(banners.enumerated()), id: \.element.id) { index, banner in
                    bannerCard(banner: banner)
                        .tag(index)
                        .onTapGesture {
                            Haptics.tap()
                            onSelect(banner)
                        }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .frame(height: 170)
            .padding(.horizontal, Theme.contentInset)
            .onReceive(timer) { _ in
                guard banners.count > 1 else { return }
                withAnimation(Motion.smooth) {
                    currentIndex = (currentIndex + 1) % banners.count
                }
            }
        }
    }

    private func bannerCard(banner: AnimeBanner) -> some View {
        ZStack(alignment: .bottomLeading) {
            // 背景封面图（通过 HPlayer 专属 ImagePipeline 磁盘与内存缓存）
            ArtworkView(urlString: banner.safePicURLString, title: banner.displayTitle, maxPixel: ArtworkSize.hero, loading: .clear, drawsFallback: false)
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
                    }
                }

                Text(banner.displayTitle)
                    .font(.display(16))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if !banner.displayDesc.isEmpty {
                    Text(banner.displayDesc)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondaryOnArtwork)
                        .lineLimit(1)
                }
            }
            .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
    }
}

// MARK: - 动漫海报卡片 (AnimePosterCard)

struct AnimePosterCard: View {
    let item: AnimeVideoItem
    var width: CGFloat = 105

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                // 封面（基于 ImagePipeline 磁盘+内存缓存与异步解码）
                PosterArtwork(urlString: item.safePicURLString, title: item.name, width: width)

                // 右下角连载状态角标
                if let continu = item.continu, !continu.isEmpty {
                    Text(continu)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.gold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(4)
                }
            }

            // 标题与分类
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Text(item.tags.prefix(2).joined(separator: ", ") + (item.year.map { " · \($0)" } ?? ""))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
    }
}

// MARK: - 选集方块矩阵 (AnimeEpisodeMatrix)

struct AnimeEpisodeMatrix: View {
    let episodes: [String]
    let activeEpisode: String?
    var isDescending: Bool = false
    var onSelect: (String) -> Void

    private var orderedEpisodes: [String] {
        isDescending ? episodes.reversed() : episodes
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
            ForEach(orderedEpisodes, id: \.self) { ep in
                let isSelected = (ep == activeEpisode)
                Button(action: {
                    Haptics.tap()
                    onSelect(ep)
                }) {
                    Text(formatEpisodeTitle(ep))
                        .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                        .foregroundStyle(isSelected ? Theme.onPrimary : Theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            isSelected ? Theme.primaryAction : Theme.surface,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isSelected ? Theme.goldLight : Theme.hairline, lineWidth: isSelected ? 1.5 : 0.5)
                        )
                }
                .buttonStyle(.pressable)
            }
        }
    }

    private func formatEpisodeTitle(_ raw: String) -> String {
        // "第01集" -> "01", "第108集" -> "108"
        var clean = raw.replacingOccurrences(of: "第", with: "")
                       .replacingOccurrences(of: "集", with: "")
                       .replacingOccurrences(of: "话", with: "")
        if clean.count == 1 { clean = "0" + clean }
        return clean.isEmpty ? raw : clean
    }
}
