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
    /// 点开某条评论的全部回复（或点「回复」直接回复它）
    @State private var repliesRequest: AnimeRepliesRequest?
    @State private var showSignIn = false
    @State private var isLoading = true
    @State private var errorMessage: String? = nil

    @State private var playingQueue: PlaybackQueue?
    @Namespace private var routeNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private static let scrollSpace = "anime.detail.scroll"
    private let backdropHeight: CGFloat = 280

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()

            if let detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        backdropView(detail)

                        // 海报抬头 → 播放 + 追番主操作栏 → 精简简介 → 无框统一选集 → 评论预览
                        VStack(alignment: .leading, spacing: Theme.Space.xl) {
                            headerView(detail)
                            actionBar(detail)
                            synopsisSection(detail)
                            routesAndEpisodesSection(detail)
                            commentsSection(detail)
                        }
                        .padding(.horizontal, Theme.contentInset)
                        .padding(.top, -74)
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
                    .accessibilityIdentifier("anime.loading")
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
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // 首页隐藏了导航栏；详情页从加载的第一帧起就固定显示，且右上角不再塞孤立图标，
        // 导航栏尺寸和返回键位置在加载 / 成功 / 失败全程完全稳定。
        .toolbar(.visible, for: .navigationBar)
        .modifier(TransparentNavigationBar())
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
        .sheet(item: $repliesRequest) { request in
            AnimeRepliesSheet(vid: animeId, request: request)
        }
        .animeSignInSheet(isPresented: $showSignIn)
    }

    // MARK: - 氛围拉伸大图背景

    private func backdropView(_ detail: AnimeVideoDetail) -> some View {
        GeometryReader { proxy in
            let minY = proxy.frame(in: .named(Self.scrollSpace)).minY
            let stretch = max(minY, 0)
            let height = backdropHeight + stretch

            ZStack {
                Theme.pageBackground

                ArtworkView(urlString: detail.safePicURLString, title: detail.name, maxPixel: ArtworkSize.hero, loading: .clear, drawsFallback: false)
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: height)
                    .clipped()
                    // 图片的加载缩放也必须经过同一个蒙版；底部留 2pt 全透明区，
                    // 避免合成、裁剪边界的像素取样露出一条原图色边。
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0.25),
                                .init(color: .black.opacity(Theme.Opacity.soft), location: 0.72),
                                .init(color: .clear, location: 1 - 2 / height),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }

                // 深色模式下封面顶部偏亮时压柔一点，保证导航栏返回键对比度
                if colorScheme == .dark {
                    LinearGradient(
                        colors: [Color.black.opacity(Theme.Opacity.medium), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: min(116, height))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: proxy.size.width, height: height)
            .compositingGroup()
            .clipped()
            .offset(y: -stretch)
        }
        .frame(height: backdropHeight)
    }

    // MARK: - 海报与元信息抬头

    private func headerView(_ detail: AnimeVideoDetail) -> some View {
        let continu = detail.continu?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let finished = continu.contains("全") || continu.contains("完结")

        return HStack(alignment: .bottom, spacing: Theme.Space.lg) {
            PosterArtwork(urlString: detail.safePicURLString, title: detail.name, width: 106)
                .shadow(color: Color.black.opacity(Theme.Opacity.medium), radius: 12, x: 0, y: 6)

            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                if !continu.isEmpty {
                    TagBadge(text: continu, style: finished ? .neutral : .accent)
                }

                Text(detail.name)
                    .font(Theme.Typo.detailTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)

                metaLine(detail)

                if !detail.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(detail.tags.prefix(3), id: \.self) { tag in
                            Text(tag)
                                .font(Theme.Typo.badge)
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 8)
                                .frame(height: 22)
                                .background(Theme.surface, in: Capsule())
                                .overlay {
                                    Capsule().strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline)
                                }
                        }
                    }
                    .lineLimit(1)
                }
            }
            .padding(.bottom, Theme.Space.xs)
        }
    }

    @ViewBuilder
    private func metaLine(_ detail: AnimeVideoDetail) -> some View {
        let year = detail.year?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let area = detail.area?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stars = detail.stars?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let textParts = [year, area].filter { !$0.isEmpty }

        if !stars.isEmpty || !textParts.isEmpty {
            HStack(spacing: 6) {
                if !stars.isEmpty {
                    HStack(spacing: 3) {
                        Image(icon: .rating)
                            .iconStyle(size: 11, color: Theme.rating)
                        Text(stars)
                            .font(Theme.Typo.meta.weight(.semibold).monospacedDigit())
                    }
                    .foregroundStyle(Theme.rating)
                }
                if !stars.isEmpty && !textParts.isEmpty {
                    Text("·")
                        .foregroundStyle(Theme.textMuted)
                }
                if !textParts.isEmpty {
                    Text(textParts.joined(separator: " · "))
                        .font(Theme.Typo.meta.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - 主操作栏：播放 + 追番收藏并排置顶

    private func actionBar(_ detail: AnimeVideoDetail) -> some View {
        HStack(spacing: 10) {
            primaryPlayButton(detail)
            watchlistButton(detail)
        }
    }

    private func primaryPlayButton(_ detail: AnimeVideoDetail) -> some View {
        let currentRoute = detail.parts.indices.contains(selectedRouteIndex) ? detail.parts[selectedRouteIndex] : detail.parts.first
        let ep = activeEpisode ?? currentRoute?.part.first ?? "第01集"
        let isContinuing = hasWatchedBefore || (lastPosition != nil && lastPosition! > 5)

        let title: String
        if isContinuing, let pos = lastPosition, pos > 5 {
            title = "续播 \(ep) · \(formatTime(pos))"
        } else if isContinuing {
            title = "续播 \(ep)"
        } else {
            title = "播放 \(ep)"
        }

        return Button {
            startPlay(episode: ep, detail: detail)
        } label: {
            Label(title, icon: .play)
                .font(Theme.Typo.button)
                .foregroundStyle(Theme.onPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .padding(.horizontal, Theme.Space.md)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Theme.primaryAction, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.pressable(scale: 0.97))
        .accessibilityIdentifier("anime.play")
    }

    /// 显眼的追番收藏按钮：紧挨播放主按钮，48pt 等高胶囊；
    /// 未追番为石墨描边胶囊 + 书签加号，已追番切换为琥珀淡底 + 实心书签对勾。
    private func watchlistButton(_ detail: AnimeVideoDetail) -> some View {
        let watched = watchlist.isWatched(id: animeId)
        return Button {
            if watched {
                Haptics.select()
            } else {
                Haptics.success()
            }
            withAnimation(Motion.resolved(Motion.snappy, reduceMotion: reduceMotion)) {
                watchlist.toggle(detail: detail)
            }
        } label: {
            HStack(spacing: 6) {
                Image(icon: watched ? .followFill : .follow)
                    .font(.scaled(16, weight: .semibold))
                    .bounceSymbol(on: watched)
                Text(watched ? "已追番" : "追番")
                    .font(Theme.Typo.button)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .foregroundStyle(watched ? Theme.accentAlt : Theme.textPrimary)
            .padding(.horizontal, Theme.Space.lg)
            .frame(minWidth: 108, minHeight: 48)
            .background(watched ? Theme.accentWash : Theme.surface, in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    watched ? Theme.accent.opacity(0.45) : Theme.rule,
                    lineWidth: Theme.Stroke.rule
                )
            }
            .contentShape(Capsule())
            .hoverEffect(.highlight)
        }
        .buttonStyle(.pressable(scale: 0.96))
        .accessibilityLabel(watched ? "取消追番" : "追番")
        .accessibilityIdentifier("anime.watchlist.\(animeId)")
        .accessibilityAddTraits(watched ? .isSelected : [])
    }

    private func formatTime(_ seconds: Double) -> String {
        let val = Int(max(0, seconds))
        let m = val / 60
        let s = val % 60
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - 选集（与片库详情页、竖屏播放器共用 UnifiedEpisodeShelf）

    private func routesAndEpisodesSection(_ detail: AnimeVideoDetail) -> some View {
        let route = detail.parts.indices.contains(selectedRouteIndex) ? detail.parts[selectedRouteIndex] : detail.parts.first
        let episodes = route?.part ?? []
        let shelfItems = episodes.map { ep in
            let progress = episodeProgress(ep, detail: detail)
            let finished = (progress ?? 0) >= 0.92
            let detailValue = finished ? "已看完" : (episodeDetailLine(ep, detail: detail) ?? "")
            return EpisodeShelfItem(
                id: ep,
                shortTitle: EpisodeShelfItem.shortAnimeTitle(ep),
                accessibilityTitle: ep,
                progress: progress,
                accessibilityValue: detailValue
            )
        }

        return UnifiedEpisodeShelf(
            items: shelfItems,
            currentID: activeEpisode,
            summary: episodeSummary(detail, route: route),
            isExpanded: $episodesExpanded,
            isDescending: $isDescending,
            identifiers: EpisodeShelfIdentifiers(
                toggle: "anime.episodes.all",
                ascending: "anime.episodes.ascending",
                descending: "anime.episodes.descending",
                rangePrefix: "anime.episodes.range"
            ),
            caption: activeEpisode.flatMap { episodeDetailLine($0, detail: detail) },
            onSelect: { item in
                activeEpisode = item.id
                startPlay(episode: item.id, detail: detail)
            },
            topAccessory: {
            // 线路胶囊：只有一条线路时不占一行（线路名已经写在标题旁）
            if detail.parts.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(detail.parts.enumerated()), id: \.element.id) { index, item in
                            SelectionPill(
                                title: "\(item.playZh) · \(item.part.count) 集",
                                selected: index == selectedRouteIndex,
                                namespace: routeNamespace
                            ) {
                                withAnimation(Motion.resolved(Motion.snappy, reduceMotion: reduceMotion)) {
                                    selectedRouteIndex = index
                                }
                                restoreLastWatched(detail: detail)
                            }
                        }
                    }
                }
            }
            }
        )
    }

    /// 「国语 · 更新至 166 集」「共 12 集」
    private func episodeSummary(_ detail: AnimeVideoDetail, route: AnimePlayRoute?) -> String {
        let count = route?.part.count ?? 0
        let finished = (detail.continu ?? "").contains("全") || (detail.continu ?? "").contains("完结")
        let countText = finished ? "共 \(count) 集" : "更新至 \(count) 集"
        if detail.parts.count == 1, let name = route?.playZh, !name.isEmpty { return "\(name) · \(countText)" }
        return countText
    }

    // MARK: - 剧情简介与演职信息（紧贴主操作栏，默认精简 2 行，与片库详情页节奏一致）

    @ViewBuilder
    private func synopsisSection(_ detail: AnimeVideoDetail) -> some View {
        let text = detail.cleanDesc.trimmingCharacters(in: .whitespacesAndNewlines)
        let director = detail.director?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let actor = detail.actor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasCredits = !director.isEmpty || !actor.isEmpty

        if !text.isEmpty || hasCredits {
            VStack(alignment: .leading, spacing: 6) {
                if !text.isEmpty {
                    Text(text)
                        .font(Theme.Typo.row)
                        .foregroundStyle(Theme.textSecondary)
                        .lineSpacing(4)
                        .lineLimit(isOverviewExpanded ? nil : 2)
                }

                if hasCredits && (isOverviewExpanded || text.count <= 44) {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        if !director.isEmpty {
                            creditLine(label: "导演", value: director)
                        }
                        if !actor.isEmpty {
                            creditLine(label: "主演", value: actor)
                        }
                    }
                    .padding(.top, Theme.Space.xs)
                }

                if text.count > 44 || (hasCredits && !text.isEmpty) {
                    Button(isOverviewExpanded ? "收起" : "更多") {
                        Haptics.select()
                        withAnimation(Motion.resolved(Motion.snappy, reduceMotion: reduceMotion)) {
                            isOverviewExpanded.toggle()
                        }
                    }
                    .font(Theme.Typo.meta.weight(.semibold))
                    .foregroundStyle(Theme.accentAlt)
                    .buttonStyle(.pressable(scale: 0.94))
                }
            }
        }
    }

    private func creditLine(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Text(label)
                .font(Theme.Typo.caption.weight(.medium))
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
        }
    }

    // MARK: - 评论预览

    private func commentsSection(_ detail: AnimeVideoDetail) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ShelfHeader(title: "评论", inset: 0) {
                HStack(spacing: 10) {
                    if let total = detail.commentTotal, total > 0 {
                        Text("\(compactCount(total)) 条")
                            .font(Theme.Typo.caption.monospacedDigit())
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
                    AnimeCommentRow(comment: comment,
                                    onReply: { repliesRequest = AnimeRepliesRequest(root: $0, startsReplying: true) },
                                    onLike: { likeComment($0) },
                                    onOpenReplies: { repliesRequest = AnimeRepliesRequest(root: $0) })
                }
            } else if commentsLoading {
                HStack {
                    Spacer()
                    ProgressView().tint(Theme.textSecondary)
                    Spacer()
                }
                .frame(height: 80)
            } else {
                HStack(spacing: Theme.Space.sm) {
                    Image(icon: .comment).iconStyle(size: 14, color: Theme.textTertiary)
                    Text(commentPreview == nil ? "评论没有加载出来，点「全部」再试一次" : "还没有评论")
                        .font(Theme.Typo.meta)
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 64)
                .surfaceCard(cornerRadius: Theme.Radius.tile)
            }
        }
    }

    private func loadComments() async {
        guard commentPreview == nil else { return }
        commentsLoading = true
        commentPreview = await AnimeCommentPreview.load(vid: animeId)
        commentsLoading = false
    }

    private func likeComment(_ comment: AnimeComment) {
        guard AnimeAccount.shared.isSignedIn else { showSignIn = true; return }
        Task {
            do {
                try await AnimeLikeStore.shared.toggle(comment, vid: animeId)
            } catch {
                HUD.show(error.userMessage, .error)
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

    // MARK: - 数据加载与播放调用

    private func loadDetail() async {
        isLoading = true
        errorMessage = nil
        do {
            let res = try await AnimeClient.shared.fetchDetail(id: animeId)
            self.detail = res
            restoreLastWatched(detail: res)
        } catch {
            self.errorMessage = error.userMessage
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
    private func startPlay(episode: String, detail: AnimeVideoDetail) {
        let episodes = detail.episodeRefs(routeIndex: selectedRouteIndex)
        guard let ref = episodes.first(where: { $0.part == episode }) else { return }

        ref.rememberAsLastWatched()
        self.activeEpisode = episode
        self.hasWatchedBefore = true

        self.playingQueue = PlaybackQueue(source: .anime(ref), items: episodes.map { PlaybackSource.anime($0) })
    }
}
