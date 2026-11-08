import SwiftUI

struct AnimeDetailView: View {
    let animeId: Int

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var watchlist = AnimeWatchlistStore.shared

    @State private var detail: AnimeVideoDetail?
    @State private var selectedRouteIndex = 0
    @State private var activeEpisode: String?
    @State private var isDescending = false
    @State private var isOverviewExpanded = false
    @State private var isLoading = true
    @State private var isResolvingPlay = false
    @State private var errorMessage: String? = nil

    @State private var playingQueue: PlaybackQueue?

    private static let scrollSpace = "anime.detail.scroll"
    private let backdropHeight: CGFloat = 260

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()

            if let detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        backdropView(detail)

                        VStack(alignment: .leading, spacing: 20) {
                            headerView(detail)
                            primaryPlayButton(detail)
                            routesAndEpisodesSection(detail)
                            synopsisSection(detail)
                        }
                        .padding(.horizontal, Theme.contentInset)
                        .padding(.top, -50)
                        .padding(.bottom, 40)
                    }
                }
                .coordinateSpace(name: Self.scrollSpace)
                .scrollIndicators(.hidden)
                .ignoresSafeArea(edges: .top)
            } else if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(Theme.accent)
                    Text("加载番剧详情...")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                VStack(spacing: 12) {
                    Image(icon: .alert)
                        .iconStyle(size: 36, color: Theme.accent)
                    Text(errorMessage ?? "番剧详情加载失败")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textPrimary)
                    Button("重试") {
                        Task { await loadDetail() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.primaryAction)
                }
            }

            // 加载/解析中遮罩
            if isResolvingPlay {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(Theme.gold)
                    Text("正在解析流媒体播放地址...")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(24)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .designScreen("anime-detail")
        .hidesTabBar()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .modifier(TransparentNavigationBar())
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let detail {
                    Button {
                        Haptics.tap()
                        watchlist.toggle(detail: detail)
                    } label: {
                        Image(icon: watchlist.isWatched(id: detail.id) ? .heartFill : .heart)
                            .foregroundStyle(watchlist.isWatched(id: detail.id) ? Theme.gold : Theme.accent)
                    }
                    .accessibilityLabel(watchlist.isWatched(id: detail.id) ? "取消追番" : "追番")
                    .accessibilityIdentifier("anime.watchlist.\(detail.id)")
                }
            }
        }
        .task {
            await loadDetail()
        }
        .playerWindow(item: $playingQueue) { queue in
            PlayerView(source: queue.source, playlist: queue.items)
                .environmentObject(appState)
        }
    }

    // MARK: - 氛围拉伸大图背景

    private func backdropView(_ detail: AnimeVideoDetail) -> some View {
        GeometryReader { proxy in
            let minY = proxy.frame(in: .named(Self.scrollSpace)).minY
            let stretch = max(minY, 0)

            ZStack(alignment: .bottom) {
                ArtworkView(urlString: detail.safePicURLString, title: detail.name, maxPixel: ArtworkSize.hero, loading: .clear, drawsFallback: false)
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: backdropHeight + stretch)
                    .clipped()

                LinearGradient(
                    stops: [
                        .init(color: Theme.pageBackground.opacity(0), location: 0.3),
                        .init(color: Theme.pageBackground.opacity(0.85), location: 0.8),
                        .init(color: Theme.pageBackground, location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: proxy.size.width, height: backdropHeight + stretch)
            .offset(y: -stretch)
        }
        .frame(height: backdropHeight)
    }

    // MARK: - 海报与元信息抬头

    private func headerView(_ detail: AnimeVideoDetail) -> some View {
        HStack(alignment: .bottom, spacing: 14) {
            // 封面海报
            PosterArtwork(urlString: detail.safePicURLString, title: detail.name, width: 95)
                .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)

            // 信息文字
            VStack(alignment: .leading, spacing: 6) {
                Text(detail.name)
                    .font(.display(20))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                if let continu = detail.continu, !continu.isEmpty {
                    Text(continu)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.gold)
                }

                HStack(spacing: 6) {
                    if let year = detail.year, !year.isEmpty { Text(year) }
                    if let area = detail.area, !area.isEmpty { Text(area) }
                    if let stars = detail.stars, !stars.isEmpty {
                        HStack(spacing: 2) {
                            Image(icon: .rating)
                                .iconStyle(size: 10, color: Theme.gold)
                            Text(stars)
                        }
                        .foregroundStyle(Theme.gold)
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)

                // 分类胶囊
                HStack(spacing: 5) {
                    ForEach(detail.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Theme.tileTint, in: Capsule())
                    }
                }
            }
            .padding(.bottom, 4)
        }
    }

    // MARK: - 主播放按钮

    private func primaryPlayButton(_ detail: AnimeVideoDetail) -> some View {
        let currentRoute = detail.parts.indices.contains(selectedRouteIndex) ? detail.parts[selectedRouteIndex] : detail.parts.first
        let ep = activeEpisode ?? currentRoute?.part.first ?? "第01集"

        return Button(action: {
            Task { await startPlay(episode: ep, detail: detail) }
        }) {
            HStack(spacing: 8) {
                Image(icon: .play)
                    .iconStyle(size: 14, color: Theme.onPrimary)
                Text("立即播放：\(ep)")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.onPrimary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Theme.primaryAction, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Theme.gold.opacity(0.3), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.pressable)
    }

    // MARK: - 线路切换与选集矩阵

    private func routesAndEpisodesSection(_ detail: AnimeVideoDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 线路选择器与正倒序
            HStack {
                HStack(spacing: 6) {
                    ForEach(Array(detail.parts.enumerated()), id: \.element.id) { index, route in
                        let isSelected = (index == selectedRouteIndex)
                        Button(action: {
                            Haptics.select()
                            selectedRouteIndex = index
                        }) {
                            Text(route.playZh)
                                .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                                .foregroundStyle(isSelected ? Theme.onPrimary : Theme.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    isSelected ? Theme.primaryAction : Theme.surfaceRaised,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                )
                        }
                        .buttonStyle(.pressable)
                    }
                }

                Spacer()

                Button(action: {
                    Haptics.tap()
                    isDescending.toggle()
                }) {
                    HStack(spacing: 3) {
                        Image(icon: isDescending ? .sortDescending : .sortAscending)
                            .iconStyle(size: 12, color: Theme.textSecondary)
                        Text(isDescending ? "倒序" : "正序")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.pressable)
            }

            // 选集列表矩阵
            if let currentRoute = detail.parts.indices.contains(selectedRouteIndex) ? detail.parts[selectedRouteIndex] : detail.parts.first {
                AnimeEpisodeMatrix(
                    episodes: currentRoute.part,
                    activeEpisode: activeEpisode,
                    isDescending: isDescending
                ) { ep in
                    activeEpisode = ep
                    Task { await startPlay(episode: ep, detail: detail) }
                }
            }
        }
    }

    // MARK: - 剧情简介手风琴

    private func synopsisSection(_ detail: AnimeVideoDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("剧情简介")
                .font(.display(14))
                .foregroundStyle(Theme.textPrimary)

            Text(detail.cleanDesc)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(4)
                .lineLimit(isOverviewExpanded ? nil : 3)

            if detail.cleanDesc.count > 60 {
                Button(action: {
                    withAnimation(Motion.snappy) {
                        isOverviewExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 2) {
                        Text(isOverviewExpanded ? "收起" : "展开全文")
                        Image(icon: isOverviewExpanded ? .collapse : .expand)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    // MARK: - 数据加载与播放调用

    private func loadDetail() async {
        isLoading = true
        errorMessage = nil
        do {
            let res = try await AnimeClient.shared.fetchDetail(id: animeId)
            self.detail = res
            self.activeEpisode = res.parts.first?.part.first
        } catch {
            self.errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func startPlay(episode: String, detail: AnimeVideoDetail) async {
        guard let currentRoute = detail.parts.indices.contains(selectedRouteIndex) ? detail.parts[selectedRouteIndex] : detail.parts.first else {
            return
        }

        isResolvingPlay = true

        do {
            // 1. 获取播放凭据
            let cred = try await AnimeClient.shared.fetchPlayCredential(id: detail.id, play: currentRoute.play, part: episode)

            // 2. 自动化解析真实流地址
            let resolved = try await AnimePlaybackResolver.shared.resolve(playCode: cred.url, title: "\(detail.name) \(episode)")

            // 3. 构建 HPlayer 在线播放源（默认最高画质，并携带可选画质列表）
            let source = PlaybackSource.online(
                title: "\(detail.name) \(episode)",
                url: resolved.url,
                headers: resolved.headers,
                qualities: resolved.qualities,
                currentQuality: resolved.qualityTitle
            )

            // 4. 记录观看历史
            RecentStore.shared.record(source)

            // 5. 唤起 HPlayer 原生独立播放器窗口
            self.playingQueue = PlaybackQueue(source: source, items: [source])
        } catch {
            self.errorMessage = "播放解析失败: \(error.localizedDescription)"
        }

        isResolvingPlay = false
    }
}
