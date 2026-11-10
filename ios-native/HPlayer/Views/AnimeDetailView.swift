import SwiftUI

struct AnimeDetailView: View {
    let animeId: Int

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var watchlist = AnimeWatchlistStore.shared

    @State private var detail: AnimeVideoDetail?
    @State private var selectedRouteIndex = 0
    @State private var activeEpisode: String?
    @State private var lastPosition: Double? = nil
    @State private var hasWatchedBefore: Bool = false
    @State private var isDescending = false
    @State private var isOverviewExpanded = false
    @State private var isLoading = true
    @State private var errorMessage: String? = nil

    @State private var playingQueue: PlaybackQueue?
    @Namespace private var routeNamespace

    private static let scrollSpace = "anime.detail.scroll"
    private let backdropHeight: CGFloat = 260

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()

            if let detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        backdropView(detail)

                        // 顺序与剧集详情页一致：抬头 → 简介 → 主按钮 → 选集
                        VStack(alignment: .leading, spacing: 22) {
                            headerView(detail)
                            synopsisSection(detail)
                            primaryPlayButton(detail)
                            routesAndEpisodesSection(detail)
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

        }
        .designScreen("anime-detail")
        .hidesTabBar()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
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
        .onAppear {
            if let detail {
                restoreLastWatched(detail: detail)
            }
        }
        .onChange(of: playingQueue == nil) { isClosed in
            if isClosed, let detail {
                restoreLastWatched(detail: detail)
            }
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)

                // 分类胶囊：与剧集页 chip 同规格（11pt、22pt 高）
                HStack(spacing: 6) {
                    ForEach(detail.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 9)
                            .frame(height: 22)
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
        let isContinuing = hasWatchedBefore || (lastPosition != nil && lastPosition! > 5)

        let title: String
        if isContinuing, let pos = lastPosition, pos > 5 {
            title = "续播 \(ep) · 看到 \(formatTime(pos))"
        } else if isContinuing {
            title = "续播 \(ep)"
        } else {
            title = "播放 \(ep)"
        }

        // 与剧集页主按钮同规格：胶囊、48pt 高、Label + 播放图标
        return Button(action: {
            startPlay(episode: ep, detail: detail)
        }) {
            Label(title, systemImage: AppIcon.play.name)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.onPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Theme.primaryAction, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.pressable(scale: 0.97))
        .accessibilityIdentifier("anime.play")
    }

    private func formatTime(_ seconds: Double) -> String {
        let val = Int(max(0, seconds))
        let m = val / 60
        let s = val % 60
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - 线路切换与选集矩阵

    private func routesAndEpisodesSection(_ detail: AnimeVideoDetail) -> some View {
        let route = detail.parts.indices.contains(selectedRouteIndex) ? detail.parts[selectedRouteIndex] : detail.parts.first
        let episodes = route?.part ?? []

        return VStack(alignment: .leading, spacing: 12) {
            // 选集标题行：与剧集页同一套（ShelfHeader + 共 N 集）
            ShelfHeader(title: "选集", inset: 0) {
                HStack(spacing: 10) {
                    Text("共 \(episodes.count) 集")
                        .font(.system(size: 12))
                        .tertiaryTextStyle()
                    HStack(spacing: 0) {
                        orderPill(title: "正序", icon: .sortAscending, selected: !isDescending) {
                            withAnimation(Motion.snappy) { isDescending = false }
                        }
                        orderPill(title: "倒序", icon: .sortDescending, selected: isDescending) {
                            withAnimation(Motion.snappy) { isDescending = true }
                        }
                    }
                    .padding(2)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            // 线路胶囊：对应剧集页的「季」，用同一个 SelectionPill
            if !detail.parts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(detail.parts.enumerated()), id: \.element.id) { index, item in
                            SelectionPill(
                                title: "\(item.playZh) · \(item.part.count) 集",
                                selected: index == selectedRouteIndex,
                                namespace: routeNamespace
                            ) {
                                withAnimation(Motion.snappy) { selectedRouteIndex = index }
                                UserDefaults.standard.set(index, forKey: "anime.last_route.\(animeId)")
                                restoreLastWatched(detail: detail)
                            }
                        }
                    }
                }
            }

            if !episodes.isEmpty {
                AnimeEpisodeMatrix(
                    episodes: episodes,
                    activeEpisode: activeEpisode,
                    isDescending: isDescending,
                    progress: { episodeProgress($0, detail: detail) }
                ) { ep in
                    activeEpisode = ep
                    startPlay(episode: ep, detail: detail)
                }

                if let ep = activeEpisode, let line = episodeDetailLine(ep, detail: detail) {
                    Text(line)
                        .font(.system(size: 12))
                        .tertiaryTextStyle()
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
        }
    }

    /// 单集进度：流地址带时效签名不能用 URL 查，按稳定标题「番剧名 第XX集」找最近一条记录。
    private func episodeProgress(_ episode: String, detail: AnimeVideoDetail) -> Double? {
        guard let item = RecentStore.shared.animeEpisode(title: "\(detail.name) \(episode)") else { return nil }
        if item.finished == true { return 1 }
        return item.progress
    }

    private func episodeDetailLine(_ episode: String, detail: AnimeVideoDetail) -> String? {
        guard let item = RecentStore.shared.animeEpisode(title: "\(detail.name) \(episode)") else { return nil }
        if item.finished == true { return "\(episode) · 已看完" }
        guard let position = item.position, position > 5 else { return nil }
        return "\(episode) · 看到 \(formatTime(position))"
    }

    private func orderPill(title: String, icon: AppIcon, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: {
            Haptics.select()
            action()
        }) {
            HStack(spacing: 3) {
                Image(icon: icon)
                    .iconStyle(size: 11, color: selected ? Theme.onPrimary : Theme.textSecondary)
                Text(title)
                    .font(.system(size: 11, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? Theme.onPrimary : Theme.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                selected ? Theme.primaryAction : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.pressable)
    }

    // MARK: - 剧情简介手风琴

    /// 简介：与剧集页一致，直接铺在页面上，不再包一张卡片；14pt、默认 3 行、「更多/收起」。
    @ViewBuilder
    private func synopsisSection(_ detail: AnimeVideoDetail) -> some View {
        let text = detail.cleanDesc
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(4)
                    .lineLimit(isOverviewExpanded ? nil : 3)
                if text.count > 60 {
                    Button(isOverviewExpanded ? "收起" : "更多") {
                        withAnimation(Motion.snappy) { isOverviewExpanded.toggle() }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.pressable(scale: 0.94))
                }
            }
        }
    }

    // MARK: - 数据加载与播放调用

    private func loadDetail() async {
        isLoading = true
        errorMessage = nil
        do {
            let res = try await AnimeClient.shared.fetchDetail(id: animeId)
            self.detail = res
            restoreLastWatched(detail: res)
        } catch {
            self.errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func restoreLastWatched(detail: AnimeVideoDetail) {
        let savedRoute = UserDefaults.standard.integer(forKey: "anime.last_route.\(animeId)")
        if detail.parts.indices.contains(savedRoute) {
            self.selectedRouteIndex = savedRoute
        }

        let currentRoute = detail.parts.indices.contains(selectedRouteIndex) ? detail.parts[selectedRouteIndex] : detail.parts.first

        // 1. 优先读取持久化的上次播放集数
        if let savedEpisode = UserDefaults.standard.string(forKey: "anime.last_episode.\(animeId)"),
           let currentRoute, currentRoute.part.contains(savedEpisode) {
            self.activeEpisode = savedEpisode
            self.hasWatchedBefore = true
            self.lastPosition = RecentStore.shared
                .animeEpisode(title: "\(detail.name) \(savedEpisode)")?.position
            return
        }

        // 2. 从播放历史找最近看过的一集（按完整标题精确匹配，避免「第1集」误配「第10集」）
        if let currentRoute {
            let titles = Dictionary(currentRoute.part.map { ("\(detail.name) \($0)", $0) },
                                    uniquingKeysWith: { first, _ in first })
            for recent in RecentStore.shared.items {
                if let matchedEp = titles[recent.title] {
                    self.activeEpisode = matchedEp
                    self.lastPosition = recent.position
                    self.hasWatchedBefore = true
                    return
                }
            }
        }

        // 3. 首次观看：默认第一集
        if self.activeEpisode == nil {
            self.activeEpisode = currentRoute?.part.first
            self.lastPosition = nil
            self.hasWatchedBefore = false
        }
    }

    /// 打开播放器：把整条线路的集数都交给它，解析放到播放器里现做。
    ///
    /// 之前这里先解析出这一集的地址、只把这一集塞进播放列表，播放器的选集就只有「共 1 集」，
    /// 切集、上一集/下一集、自动连播全都无从谈起。现在传的是集数引用（见 AnimeEpisodeRef），
    /// 播放器要播哪集就现解析哪集——和 115 网盘按 pickCode 取地址是同一个模式。
    /// 顺带也不再用详情页上的解析遮罩：播放器窗口立刻打开，转圈在播放器自己的画面里。
    private func startPlay(episode: String, detail: AnimeVideoDetail) {
        let episodes = detail.episodeRefs(routeIndex: selectedRouteIndex)
        guard let ref = episodes.first(where: { $0.part == episode }) else { return }

        ref.rememberAsLastWatched()
        self.activeEpisode = episode
        self.hasWatchedBefore = true

        self.playingQueue = PlaybackQueue(source: .anime(ref), items: episodes.map { PlaybackSource.anime($0) })
    }
}
