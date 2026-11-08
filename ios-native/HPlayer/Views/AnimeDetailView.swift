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
        let isContinuing = hasWatchedBefore || (lastPosition != nil && lastPosition! > 5)

        return Button(action: {
            Task { await startPlay(episode: ep, detail: detail) }
        }) {
            HStack(spacing: 8) {
                Image(icon: .play)
                    .iconStyle(size: 14, color: Theme.onPrimary)
                if isContinuing, let pos = lastPosition, pos > 5 {
                    Text("续播：\(ep)（看到 \(formatTime(pos))）")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.onPrimary)
                } else if isContinuing {
                    Text("续播：\(ep)")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.onPrimary)
                } else {
                    Text("立即播放：\(ep)")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.onPrimary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Theme.primaryAction, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Theme.gold.opacity(0.3), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.pressable)
    }

    private func formatTime(_ seconds: Double) -> String {
        let val = Int(max(0, seconds))
        let m = val / 60
        let s = val % 60
        return String(format: "%02d:%02d", m, s)
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
                            UserDefaults.standard.set(index, forKey: "anime.last_route.\(animeId)")
                            restoreLastWatched(detail: detail)
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

                // 正序 / 倒序 双胶囊切换器：明确显示两种状态，点哪个就切到哪个
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
            if let recent = RecentStore.shared.items.first(where: { $0.title.contains(detail.name) && $0.title.contains(savedEpisode) }) {
                self.lastPosition = recent.position
            }
            return
        }

        // 2. 从 RecentStore 全局播放历史寻找匹配
        if let currentRoute {
            for recent in RecentStore.shared.items {
                guard recent.title.contains(detail.name) else { continue }
                if let matchedEp = currentRoute.part.first(where: { recent.title.contains($0) }) {
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

    private func startPlay(episode: String, detail: AnimeVideoDetail) async {
        guard let currentRoute = detail.parts.indices.contains(selectedRouteIndex) ? detail.parts[selectedRouteIndex] : detail.parts.first else {
            return
        }

        // 持久化当前选集与线路
        UserDefaults.standard.set(episode, forKey: "anime.last_episode.\(animeId)")
        UserDefaults.standard.set(selectedRouteIndex, forKey: "anime.last_route.\(animeId)")
        self.activeEpisode = episode
        self.hasWatchedBefore = true

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
