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
    @State private var isOverviewExpanded = false
    /// 选集栏展开成完整网格（点「全部」）
    @State private var episodesExpanded = false
    @State private var isDescending = false
    /// 评论预览（前三条）；nil = 还没拉到 / 拉失败
    @State private var commentPreview: [AnimeComment]?
    @State private var commentsLoading = false
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

                        // 抬头 → 数据（播放 / 评论 / 弹幕）→ 简介 → 主按钮 → 选集（横排）→ 评论预览
                        VStack(alignment: .leading, spacing: 22) {
                            headerView(detail)
                            statsLine(detail)
                            synopsisSection(detail)
                            primaryPlayButton(detail)
                            routesAndEpisodesSection(detail)
                            commentsSection(detail)
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
                ProgressView()
                    .tint(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("正在加载番剧详情")
            } else {
                EmptyStateView(icon: AppIcon.alert.name, title: "番剧详情没有加载出来",
                               message: errorMessage ?? "网络不太稳定，稍后再试。",
                               actionTitle: "重新加载") {
                    Task { await loadDetail() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                            .foregroundStyle(watchlist.isWatched(id: detail.id) ? Theme.accent : Theme.textPrimary)
                    }
                    // 加入追番时爱心轻轻一跳并飘出几颗小心；取消时不动
                    .successPop(watchlist.isWatched(id: detail.id), particle: .heartFill)
                    .accessibilityLabel(watchlist.isWatched(id: detail.id) ? "取消追番" : "追番")
                    .accessibilityIdentifier("anime.watchlist.\(detail.id)")
                }
            }
        }
        .task {
            watchlist.markUpdateChecked(id: animeId)
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
        .task(id: animeId) { await loadComments() }
        .onChange(of: selectedRouteIndex) { index in
            UserDefaults.standard.set(index, forKey: "anime.last_route.\(animeId)")
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
                        .foregroundStyle(Theme.accent)
                }

                HStack(spacing: 6) {
                    if let year = detail.year, !year.isEmpty { Text(year) }
                    if let area = detail.area, !area.isEmpty { Text(area) }
                    if let stars = detail.stars, !stars.isEmpty {
                        HStack(spacing: 2) {
                            Image(icon: .rating)
                                .iconStyle(size: 10, color: Theme.rating)
                            Text(stars)
                        }
                        .foregroundStyle(Theme.rating)
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

    // MARK: - 数据行

    /// 「14.1万次播放 · 173 条评论 · 1000 条弹幕」：详情接口有才显示
    @ViewBuilder
    private func statsLine(_ detail: AnimeVideoDetail) -> some View {
        let parts = [
            detail.hits.flatMap { $0 > 0 ? "\(compactCount($0)) 次播放" : nil },
            detail.commentTotal.flatMap { $0 > 0 ? "\(compactCount($0)) 条评论" : nil },
            detail.danmuCount.flatMap { $0 > 0 ? "\(compactCount($0)) 条弹幕" : nil },
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, -10)
        }
    }

    // MARK: - 选集：线路 + 一行横排（自动滚到在看的那集），「全部」打开分段面板

    private func routesAndEpisodesSection(_ detail: AnimeVideoDetail) -> some View {
        let route = detail.parts.indices.contains(selectedRouteIndex) ? detail.parts[selectedRouteIndex] : detail.parts.first
        let episodes = route?.part ?? []

        return VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: "选集", inset: 0) {
                HStack(spacing: 10) {
                    if episodesExpanded {
                        orderToggle
                    } else {
                        Text(episodeSummary(detail, route: route))
                            .font(.system(size: 12))
                            .tertiaryTextStyle()
                            .lineLimit(1)
                    }
                    if episodes.count > 1 {
                        Button {
                            Haptics.select()
                            // 不做过渡动画：展开的网格很高，边淡入边挤开下面的内容时会和评论区叠在一起
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) { episodesExpanded.toggle() }
                        } label: {
                            HStack(spacing: 3) {
                                Text(episodesExpanded ? "收起" : "全部")
                                    .font(.system(size: 13))
                                Image(icon: episodesExpanded ? .collapse : .expand)
                                    .iconStyle(size: 10, color: Theme.textSecondary)
                            }
                            .foregroundStyle(Theme.textSecondary)
                            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable(scale: 0.92))
                        .accessibilityIdentifier("anime.episodes.all")
                    }
                }
            }

            // 线路胶囊：只有一条线路时不占一行（线路名已经写在标题右边）
            if detail.parts.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(detail.parts.enumerated()), id: \.element.id) { index, item in
                            SelectionPill(
                                title: "\(item.playZh) · \(item.part.count) 集",
                                selected: index == selectedRouteIndex,
                                namespace: routeNamespace
                            ) {
                                withAnimation(Motion.snappy) { selectedRouteIndex = index }
                                restoreLastWatched(detail: detail)
                            }
                        }
                    }
                }
            }

            if !episodes.isEmpty {
                if episodesExpanded {
                    // 「全部」：在选集栏里原地展开成五列网格，超过 50 集分段
                    AnimeEpisodePanel(episodes: episodes, activeEpisode: activeEpisode, isDescending: isDescending,
                                      progress: { episodeProgress($0, detail: detail) }) { episode in
                        activeEpisode = episode
                        startPlay(episode: episode, detail: detail)
                    }
                } else {
                    episodeStrip(episodes, detail: detail)
                }

                if let ep = activeEpisode, let line = episodeDetailLine(ep, detail: detail) {
                    Text(line)
                        .font(.system(size: 12))
                        .tertiaryTextStyle()
                        .lineLimit(2)
                }
            }
        }
    }

    /// 正序 / 倒序（展开时才显示）
    private var orderToggle: some View {
        HStack(spacing: 0) {
            orderPill("正序", icon: .sortAscending, selected: !isDescending) { isDescending = false }
            orderPill("倒序", icon: .sortDescending, selected: isDescending) { isDescending = true }
        }
        .padding(2)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func orderPill(_ title: String, icon: AppIcon, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.select()
            withAnimation(Motion.snappy) { action() }
        } label: {
            HStack(spacing: 3) {
                Image(icon: icon)
                    .iconStyle(size: 11, color: selected ? Theme.onPrimary : Theme.textSecondary)
                Text(title)
                    .font(.system(size: 11, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? Theme.onPrimary : Theme.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selected ? Theme.primaryAction : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.pressable)
    }

    /// 「国语 · 更新至 166 集」「共 12 集」
    private func episodeSummary(_ detail: AnimeVideoDetail, route: AnimePlayRoute?) -> String {
        let count = route?.part.count ?? 0
        let finished = (detail.continu ?? "").contains("全") || (detail.continu ?? "").contains("完结")
        let countText = finished ? "共 \(count) 集" : "更新至 \(count) 集"
        if detail.parts.count == 1, let name = route?.playZh, !name.isEmpty { return "\(name) · \(countText)" }
        return countText
    }

    /// 一行横排的选集格子，打开时滚到在看的那一集；集数再多也只占一行。
    private func episodeStrip(_ episodes: [String], detail: AnimeVideoDetail) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(episodes, id: \.self) { episode in
                        AnimeEpisodeCell(title: episode, isCurrent: episode == activeEpisode,
                                         progress: episodeProgress(episode, detail: detail) ?? 0) {
                            activeEpisode = episode
                            startPlay(episode: episode, detail: detail)
                        }
                        .frame(width: 64)
                        .id(episode)
                    }
                }
                .padding(.horizontal, Theme.contentInset)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, -Theme.contentInset)
            .onAppear { scrollStrip(proxy, animated: false) }
            .onChange(of: activeEpisode) { _ in scrollStrip(proxy, animated: true) }
            .onChange(of: selectedRouteIndex) { _ in scrollStrip(proxy, animated: false) }
        }
    }

    private func scrollStrip(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let activeEpisode else { return }
        DispatchQueue.main.async {
            withAnimation(animated ? Motion.smooth : nil) { proxy.scrollTo(activeEpisode, anchor: .center) }
        }
    }

    // MARK: - 评论预览

    private func commentsSection(_ detail: AnimeVideoDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ShelfHeader(title: "评论", inset: 0) {
                HStack(spacing: 10) {
                    if let total = detail.commentTotal, total > 0 {
                        Text("\(compactCount(total)) 条")
                            .font(.system(size: 12))
                            .tertiaryTextStyle()
                    }
                    NavigationLink {
                        AnimeCommentsPage(vid: detail.id, title: "\(detail.name) · 评论")
                    } label: {
                        ShelfLinkLabel(text: "全部")
                            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    }
                    .buttonStyle(.pressable(scale: 0.92))
                    .accessibilityIdentifier("anime.comments.all")
                }
            }

            if let comments = commentPreview, !comments.isEmpty {
                ForEach(comments) { comment in
                    AnimeCommentRow(comment: comment)
                }
            } else if commentsLoading {
                HStack {
                    Spacer()
                    ProgressView().tint(Theme.textSecondary)
                    Spacer()
                }
                .frame(height: 80)
            } else {
                HStack(spacing: 8) {
                    Image(icon: .comment).iconStyle(size: 14, color: Theme.textTertiary)
                    Text(commentPreview == nil ? "评论没有加载出来，点「全部」再试一次" : "还没有评论")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            }
        }
    }

    private func loadComments() async {
        guard commentPreview == nil else { return }
        commentsLoading = true
        commentPreview = await AnimeCommentPreview.load(vid: animeId)
        commentsLoading = false
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
