import SwiftUI

struct AnimeCatalogView: View {
    var onSearch: () -> Void

    @State private var channels: [AnimeChannel] = []
    @State private var banners: [AnimeBanner] = []
    @State private var trendingItems: [AnimeVideoItem] = []
    @State private var waterfallItems: [AnimeVideoItem] = []

    @State private var selectedChannelId: Int? = nil
    @State private var currentPage = 1
    @State private var totalCount = 0
    @State private var isLoading = false
    @State private var initialLoaded = false
    @State private var errorMessage: String? = nil

    @State private var selectedAnimeId: Int? = nil

    var body: some View {
        VStack(spacing: 0) {
            // 顶部分类胶囊栏
            AnimeChannelBar(
                channels: channels,
                selectedChannelId: $selectedChannelId,
                onSelect: { channelId in
                    Task {
                        await reloadForChannel(channelId)
                    }
                }
            )

            // 主滚动视图
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 今日轮播
                    if selectedChannelId == nil && !banners.isEmpty {
                        AnimeHeroBanner(banners: banners) { banner in
                            if let vid = banner.vid {
                                selectedAnimeId = vid
                            }
                        }
                        .padding(.top, 4)
                    }

                    // 热门新番横滑货架
                    if selectedChannelId == nil && !trendingItems.isEmpty {
                        trendingSection
                    }

                    // 分类作品两列瀑布流
                    waterfallSection
                }
                .padding(.bottom, 80)
            }
            .refreshable {
                await loadAllData()
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .task {
            if !initialLoaded {
                initialLoaded = true
                await loadAllData()
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { selectedAnimeId != nil },
            set: { if !$0 { selectedAnimeId = nil } }
        )) {
            if let id = selectedAnimeId {
                AnimeDetailView(animeId: id)
            }
        }
    }

    // MARK: - 热门新番横滑货架

    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("🔥 热门新番")
                    .font(.display(16))
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                Text("共 \(totalCount) 部")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, Theme.contentInset)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(trendingItems) { item in
                        AnimePosterCard(item: item, width: 108)
                            .onTapGesture {
                                Haptics.tap()
                                selectedAnimeId = item.id
                            }
                    }
                }
                .padding(.horizontal, Theme.contentInset)
            }
        }
    }

    // MARK: - 分类更新两列海报网格

    private var waterfallSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                let title = channels.first(where: { $0.id == selectedChannelId })?.name ?? "连载更新"
                Text(title)
                    .font(.display(16))
                    .foregroundStyle(Theme.textPrimary)

                Spacer()
            }
            .padding(.horizontal, Theme.contentInset)

            if waterfallItems.isEmpty && !isLoading {
                VStack(spacing: 12) {
                    Image(icon: .video)
                        .iconStyle(size: 36, color: Theme.textTertiary)
                    Text("暂无番剧内容")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ],
                    spacing: 16
                ) {
                    ForEach(waterfallItems) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            ZStack(alignment: .bottomTrailing) {
                                AsyncImage(url: URL(string: item.pic ?? "")) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .scaledToFill()
                                    case .failure, .empty:
                                        Theme.surfaceRaised
                                    @unknown default:
                                        Theme.surfaceRaised
                                    }
                                }
                                .aspectRatio(3/4, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))

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

                            Text(item.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)

                            Text(item.tags.prefix(2).joined(separator: ", ") + (item.year.map { " · \($0)" } ?? ""))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                        .onTapGesture {
                            Haptics.tap()
                            selectedAnimeId = item.id
                        }
                        .onAppear {
                            if item.id == waterfallItems.last?.id {
                                Task { await loadNextPage() }
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.contentInset)

                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                            .tint(Theme.accent)
                        Spacer()
                    }
                    .padding(.vertical, 16)
                }
            }
        }
    }

    // MARK: - 数据加载流水线

    private func loadAllData() async {
        isLoading = true
        errorMessage = nil

        // 独立安全拉取各个板块，避免单个接口异常导致全屏空白
        if let c = try? await AnimeClient.shared.fetchChannels() {
            self.channels = c
        }

        if let b = try? await AnimeClient.shared.fetchBanners() {
            self.banners = b
        }

        if let t = try? await AnimeClient.shared.fetchVideoList(sort: "weight", limit: 12, page: 1) {
            self.trendingItems = t.items
        }

        do {
            let l = try await AnimeClient.shared.fetchVideoList(sort: "addtime", limit: 18, page: 1)
            self.waterfallItems = l.items
            self.totalCount = l.total
            self.currentPage = 1
        } catch {
            print("[AnimeCatalogView] fetchVideoList addtime error: \(error)")
            // 兜底重试：若全库 addtime 异常，拉取日漫频道内容
            if let fallback = try? await AnimeClient.shared.fetchVideoList(channel: 20, sort: "weight", limit: 18, page: 1) {
                self.waterfallItems = fallback.items
                self.totalCount = fallback.total
                self.currentPage = 1
            } else {
                self.errorMessage = error.localizedDescription
            }
        }

        isLoading = false
    }

    private func reloadForChannel(_ channelId: Int?) async {
        isLoading = true
        currentPage = 1
        do {
            let res = try await AnimeClient.shared.fetchVideoList(channel: channelId, sort: "addtime", limit: 18, page: 1)
            self.waterfallItems = res.items
            self.totalCount = res.total
        } catch {
            self.errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadNextPage() async {
        guard !isLoading, waterfallItems.count < totalCount else { return }
        isLoading = true
        let nextPage = currentPage + 1

        do {
            let res = try await AnimeClient.shared.fetchVideoList(channel: selectedChannelId, sort: "addtime", limit: 18, page: nextPage)
            self.waterfallItems.append(contentsOf: res.items)
            self.currentPage = nextPage
        } catch {
            // 加载下一页失败
        }

        isLoading = false
    }
}
