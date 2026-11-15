import SwiftUI
import WebKit

struct MissAVRoute: Hashable {
    let id: String
    let title: String
    let cover: String
    var url: String = ""
}

// MARK: - 列表数据缓存

@MainActor
final class MissAVFeed: ObservableObject {
    struct Shelf {
        var items: [MissAVVideoCard] = []
        var page = 0
        var hasMore = true
        var loading = false
        var error = ""
    }

    @Published private(set) var shelves: [MissAVCategory: Shelf] = [:]

    func shelf(_ category: MissAVCategory) -> Shelf { shelves[category] ?? Shelf() }

    /// 第一次打开这个分类：先把上次缓存的第一页摆出来，再去取最新的（取到后整页替换）
    func loadFirstIfNeeded(_ category: MissAVCategory) async {
        guard shelf(category).page == 0 else { return }
        if shelf(category).items.isEmpty, let cached = ChannelListCache.load(Self.cacheKey(category), as: MissAVVideoCard.self) {
            var state = Shelf()
            state.items = cached
            shelves[category] = state
        }
        await loadMore(category)
    }

    /// 下拉刷新：列表先留着，取到新的第一页再整页替换，不会先清空成转圈
    func reload(_ category: MissAVCategory) async {
        var state = shelf(category)
        state.page = 0
        state.hasMore = true
        state.error = ""
        shelves[category] = state
        await loadMore(category)
    }

    private static func cacheKey(_ category: MissAVCategory) -> String { "missav." + category.rawValue }

    func loadMore(_ category: MissAVCategory) async {
        var state = shelf(category)
        guard !state.loading, state.hasMore, !InterfacePreview.active else { return }
        state.loading = true
        state.error = ""
        shelves[category] = state

        do {
            let nextPage = state.page + 1
            let fresh = try await MissAVClient.shared.list(category: category, page: nextPage)
            var updated = shelf(category)
            if nextPage == 1 {
                // 第一页：整页替换（顶掉缓存里旧的那一页），并存成新的缓存
                updated.items = fresh
                updated.page = 1
                updated.hasMore = !fresh.isEmpty
                updated.loading = false
                shelves[category] = updated
                ChannelListCache.save(fresh, key: Self.cacheKey(category))
                return
            }
            let known = Set(updated.items.map(\.id))
            let filtered = fresh.filter { !known.contains($0.id) }
            updated.items += filtered
            updated.page = nextPage
            updated.hasMore = !filtered.isEmpty
            updated.loading = false
            shelves[category] = updated
        } catch {
            var updated = shelf(category)
            updated.loading = false
            if !(error is CancellationError) {
                updated.error = error.localizedDescription
            }
            shelves[category] = updated
        }
    }
}

// MARK: - 视频卡片

struct MissAVPosterCard: View {
    let item: MissAVVideoCard

    private var hasChineseSubtitle: Bool {
        let lower = item.title.lowercased()
        return lower.contains("-c") || lower.contains("中文字幕") || lower.contains("中字")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        if let url = URL(string: item.coverUrl) {
                            PipelineImage(url: url, maxPixel: ArtworkSize.hero) { phase in
                                switch phase {
                                case let .loaded(image):
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                case .loading:
                                    Rectangle().fill(Theme.surfaceRaised)
                                case .failed:
                                    Rectangle()
                                        .fill(Theme.surfaceRaised)
                                        .overlay {
                                            Image(systemName: AppIcon.video.name)
                                                .foregroundStyle(Theme.textTertiary)
                                        }
                                }
                            }
                        } else {
                            Rectangle()
                                .fill(Theme.surfaceRaised)
                                .overlay {
                                    Image(systemName: AppIcon.video.name)
                                        .foregroundStyle(Theme.textTertiary)
                                }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

                // 中字角标
                if hasChineseSubtitle {
                    VStack {
                        HStack {
                            Text("中字")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.onPrimary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.prismGradient, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .padding(5)
                            Spacer()
                        }
                        Spacer()
                    }
                }

                // 时长角标
                if !item.duration.isEmpty {
                    // 角标底是深色半透明，字固定用白色：以前用主文字色，浅色模式下是深灰，压在深色底上看不清
                    Text(item.duration)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(5)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if !item.views.isEmpty {
                    Text(item.views)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - MissAV 频道主页面

struct MissAVTab: View {
    @StateObject private var feed = MissAVFeed()
    @State private var category: MissAVCategory = .todayHot
    @Namespace private var pills
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.channelPageInsets) private var insets

    private let columns = [
        GridItem(.flexible(), spacing: 12, alignment: .top),
        GridItem(.flexible(), spacing: 12, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                categoryBar
                    .padding(.top, insets.top + 4)
                    .padding(.bottom, 12)

                content
                    .transaction { $0.animation = nil }
            }
            .tracksPageScroll()
        }
        .pageScrollContainer()
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
        .refreshable {
            await feed.reload(category)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .designScreen("missav")
        .task(id: category) {
            await feed.loadFirstIfNeeded(category)
        }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MissAVCategory.allCases) { item in
                    SelectionPill(title: item.title, selected: category == item, namespace: pills) {
                        withAnimation(reduceMotion ? nil : Motion.snappy) {
                            category = item
                        }
                    }
                    .accessibilityIdentifier("missav.category.\(item.rawValue)")
                }
            }
            .padding(.horizontal, Theme.contentInset)
        }
    }

    @ViewBuilder
    private var content: some View {
        let shelf = feed.shelf(category)
        if shelf.items.isEmpty {
            Group {
                if !shelf.error.isEmpty {
                    EmptyStateView(
                        icon: AppIcon.alert.name,
                        title: "视频列表加载失败",
                        message: shelf.error,
                        actionTitle: "重新加载"
                    ) {
                        Task { await feed.reload(category) }
                    }
                } else if shelf.loading || shelf.page == 0 {
                    ProgressView()
                        .tint(Theme.textSecondary)
                } else {
                    EmptyStateView(
                        icon: AppIcon.video.name,
                        title: "暂无内容",
                        message: "当前分类暂无视频，稍后再来看看。"
                    )
                }
            }
            .frame(maxWidth: .infinity, minHeight: 360)
        } else {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(Array(shelf.items.enumerated()), id: \.element.id) { index, item in
                    NavigationLink(value: MissAVRoute(id: item.id, title: item.title, cover: item.coverUrl, url: item.url)) {
                        MissAVPosterCard(item: item)
                    }
                    .buttonStyle(PosterButtonStyle())
                    .accessibilityIdentifier("missav.poster.\(item.id)")
                    .gridCardEntrance()
                    .onAppear {
                        if index >= shelf.items.count - 4 {
                            Task { await feed.loadMore(category) }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.contentInset)
            .padding(.bottom, 48)

            if shelf.loading {
                HStack {
                    Spacer()
                    ProgressView().tint(Theme.textSecondary)
                    Spacer()
                }
                .padding(.vertical, 16)
            }
        }
    }
}

// MARK: - MissAV 视频详情页

struct MissAVDetailView: View {
    let route: MissAVRoute
    @ObservedObject private var recents = RecentStore.shared

    @State private var detail: MissAVVideoDetail?
    @State private var loading = true
    @State private var error = ""
    @State private var playingQueue: PlaybackQueue?
    @State private var copiedNotice = false

    private let columns = [
        GridItem(.flexible(), spacing: 12, alignment: .top),
        GridItem(.flexible(), spacing: 12, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                previewHero
                infoSection
                if let detail, !detail.related.isEmpty {
                    relatedSection(detail.related)
                }
            }
            .padding(.horizontal, Theme.contentInset)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle(route.id.uppercased())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .designScreen("missav-detail")
        .task { await load() }
        .playerWindow(item: $playingQueue) { queue in
            PlayerView(source: queue.source, playlist: queue.items)
        }
    }

    private var previewHero: some View {
        Button {
            play()
        } label: {
            ZStack {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        let coverUrlString = detail?.coverUrl.isEmpty == false ? detail!.coverUrl : route.cover
                        if let url = URL(string: coverUrlString) {
                            PipelineImage(url: url, maxPixel: ArtworkSize.hero) { phase in
                                switch phase {
                                case let .loaded(image):
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                case .loading, .failed:
                                    Rectangle().fill(Theme.surfaceRaised)
                                }
                            }
                        } else {
                            Rectangle().fill(Theme.surfaceRaised)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

                // 播放遮罩与图标
                Circle()
                    .fill(Color.black.opacity(0.6))
                    .frame(width: 56, height: 56)
                    .overlay {
                        Image(systemName: AppIcon.play.name)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .offset(x: 2)
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("立即播放")
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(detail?.title.isEmpty == false ? detail!.title : route.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // 番号与复制
            HStack(spacing: 10) {
                Text(route.id.uppercased())
                    .font(.subheadline.weight(.semibold).monospaced())
                    .foregroundStyle(Theme.accent)

                Button {
                    UIPasteboard.general.string = route.id.uppercased()
                    Haptics.select()
                    withAnimation(Motion.snappy) {
                        copiedNotice = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(Motion.snappy) { copiedNotice = false }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: AppIcon.copy.name)
                        Text(copiedNotice ? "已复制" : "复制番号")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(copiedNotice ? Theme.accent : Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.surface, in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer()
            }

            // 播放按钮
            Button {
                play()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: AppIcon.play.name)
                    Text("立即播放")
                }
            }
            .buttonStyle(PrimaryActionStyle())
            .accessibilityIdentifier("missav.play")

            // 女优/演员
            if let detail, !detail.models.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("出演女优")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(detail.models, id: \.self) { model in
                                Text(model)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.textPrimary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Theme.surface, in: Capsule())
                            }
                        }
                    }
                }
            }

            // 标签
            if let detail, !detail.tags.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("相关标签")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)

                    MissAVFlowLayout(spacing: 8) {
                        ForEach(detail.tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                    }
                }
            }

            if loading {
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.textSecondary)
                    Text("正在获取视频播放流及详细信息…")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 8)
            } else if !error.isEmpty {
                EmptyStateView(
                    icon: AppIcon.alert.name,
                    title: "详情加载失败",
                    message: error,
                    actionTitle: "重新加载"
                ) {
                    Task { await load() }
                }
            }
        }
    }

    private func relatedSection(_ related: [MissAVVideoCard]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("相关推荐")
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 8)

            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(related) { item in
                    NavigationLink(value: MissAVRoute(id: item.id, title: item.title, cover: item.coverUrl, url: item.url)) {
                        MissAVPosterCard(item: item)
                    }
                    .buttonStyle(PosterButtonStyle())
                }
            }
        }
    }

    private func play() {
        Haptics.tap()
        let ref = MissAVVideoRef(videoId: route.id, title: detail?.title.isEmpty == false ? detail!.title : route.title, coverUrl: detail?.coverUrl.isEmpty == false ? detail!.coverUrl : route.cover)
        let source = PlaybackSource.missav(ref)
        playingQueue = PlaybackQueue(source: source, items: [source])
    }

    private func load() async {
        guard detail == nil, !InterfacePreview.active else { loading = false; return }
        loading = true
        error = ""
        do {
            detail = try await MissAVClient.shared.detail(videoId: route.id, pageUrl: route.url)
        } catch {
            if !(error is CancellationError) {
                self.error = error.localizedDescription
            }
        }
        loading = false
    }
}

// MARK: - 流式标签布局

private struct MissAVFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var maxHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width, currentX > 0 {
                currentX = 0
                currentY += maxHeight + spacing
                maxHeight = 0
            }
            maxHeight = max(maxHeight, size.height)
            currentX += size.width + spacing
            widest = max(widest, currentX - spacing)
        }

        return CGSize(width: proposal.width ?? widest, height: currentY + maxHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var maxHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX, currentX > bounds.minX {
                currentX = bounds.minX
                currentY += maxHeight + spacing
                maxHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
            maxHeight = max(maxHeight, size.height)
            currentX += size.width + spacing
        }
    }
}
