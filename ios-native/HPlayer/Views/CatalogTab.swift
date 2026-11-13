import SwiftUI

// MARK: - 筛选条件

enum CatalogSource: String, CaseIterable, Identifiable {
    case library = "library"
    case anime = "anime"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return "我的片库"
        case .anime: return "动漫共和国"
        }
    }
}

enum CatalogKind: String, CaseIterable, Identifiable {
    case all, movie, series, anime, performer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .movie: return "电影"
        case .series: return "剧集"
        case .anime: return "动画"
        case .performer: return "演员合集"
        }
    }
}

enum CatalogRegion: String, CaseIterable, Identifiable {
    case all, chinese, western, eastAsia, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部地区"
        case .chinese: return "华语"
        case .western: return "欧美"
        case .eastAsia: return "日韩"
        case .other: return "其他"
        }
    }

    /// 资料里的产地可能是英文也可能是中文，逐个词匹配。
    static func region(of country: String) -> CatalogRegion {
        let text = country.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        if has(["china", "hong kong", "taiwan", "中国", "香港", "台湾", "大陆"]) { return .chinese }
        if has(["japan", "korea", "日本", "韩国", "朝鲜"]) { return .eastAsia }
        if has(["united states", "usa", "united kingdom", "uk", "canada", "france", "germany", "italy", "spain",
                "australia", "sweden", "denmark", "norway", "ireland", "netherlands", "美国", "英国", "加拿大",
                "法国", "德国", "意大利", "西班牙", "澳大利亚"]) { return .western }
        return .other
    }
}

enum CatalogYear: String, CaseIterable, Identifiable {
    case all, latest, previous, beforePrevious, older

    var id: String { rawValue }

    static var currentYear: Int { Calendar.current.component(.year, from: Date()) }

    var title: String {
        switch self {
        case .all: return "全部年份"
        case .latest: return String(Self.currentYear)
        case .previous: return String(Self.currentYear - 1)
        case .beforePrevious: return String(Self.currentYear - 2)
        case .older: return "更早"
        }
    }

    func matches(_ year: Int?) -> Bool {
        guard self != .all else { return true }
        guard let year else { return false }
        switch self {
        case .all: return true
        case .latest: return year >= Self.currentYear
        case .previous: return year == Self.currentYear - 1
        case .beforePrevious: return year == Self.currentYear - 2
        case .older: return year < Self.currentYear - 2
        }
    }
}

enum CatalogSort: String, CaseIterable, Identifiable {
    case recentlyAdded, recentlyPlayed, topRated, title

    var id: String { rawValue }

    var titleText: String {
        switch self {
        case .recentlyAdded: return "最近添加"
        case .recentlyPlayed: return "最近播放"
        case .topRated: return "评分最高"
        case .title: return "片名"
        }
    }
}

extension CatalogKind {
    var shortcutTitle: String {
        switch self {
        case .all: return "全部"
        case .movie: return "电影"
        case .series: return "剧集"
        case .anime: return "动画"
        case .performer: return "演员"
        }
    }

    var icon: AppIcon {
        switch self {
        case .all: return .library
        case .movie: return .video
        case .series: return .series
        case .anime: return .sparkles
        case .performer: return .people
        }
    }

    var tint: Color {
        switch self {
        case .all: return ShortcutTint.amber
        case .movie: return ShortcutTint.orange
        case .series: return ShortcutTint.purple
        case .anime: return ShortcutTint.blue
        case .performer: return ShortcutTint.green
        }
    }
}

// MARK: - 条目

/// 网格里的一张卡片：电影、一部剧，或一位演员的合集。
struct CatalogEntry: Identifiable {
    enum Payload {
        case movie(HomeMediaItem)
        case series(SeriesGroup)
        case performer(PerformerGroup)
    }

    let id: String
    let payload: Payload
    let title: String
    let year: Int?
    let rating: Double?
    let country: String
    let genres: [String]
    /// 在片库里的先后，越大越晚加入
    let addedOrder: Int
    /// 最近播放的先后，0 是最近一次；没播放过为 nil
    var playedRank: Int?

    var isAnime: Bool {
        genres.contains { $0.contains("动画") || $0.lowercased().contains("animation") || $0.contains("动漫") }
    }

    static func parseYear(_ text: String) -> Int? {
        let digits = text.prefix(4)
        guard digits.count == 4, let value = Int(digits) else { return nil }
        return value
    }
}

// MARK: - 片库页

/// 片库：把整个媒体库铺成海报墙，用类型 / 地区 / 年份 / 排序四行胶囊筛选。
struct CatalogTab: View {
    var onSearch: () -> Void = {}
    /// 从首页分类进入时预设的筛选；用完立即清空，免得下次进来还是旧条件。
    @Binding var preset: CatalogPreset?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mediaLibrary: MediaLibraryStore
    @EnvironmentObject private var localStore: LocalMediaStore
    @EnvironmentObject private var metadataStore: MediaMetadataStore

    /// 分组和网格条目由 HomeView 在后台算好（见 LibrarySnapshotStore），第一次打开片库不用再在主线程重算。
    @EnvironmentObject private var librarySnapshots: LibrarySnapshotStore
    private var snapshot: HomeSnapshot { librarySnapshots.home }
    private var entries: [CatalogEntry] { librarySnapshots.catalogEntries }
    /// 顶部头部「筛选」按一次加一：滚到筛选区
    var filterRequest = 0
    /// 内容从哪里开始（频道容器的固定头部盖在上面）
    @Environment(\.channelPageInsets) private var insets
    @State private var kind: CatalogKind = .all
    @State private var region: CatalogRegion = .all
    @State private var year: CatalogYear = .all
    @State private var sort: CatalogSort = .recentlyAdded
    @State private var playing: PlaybackQueue?
    @State private var matching: MatchRequest?
    @State private var showManagement = false

    init(onSearch: @escaping () -> Void = {}, preset: Binding<CatalogPreset?> = .constant(nil), filterRequest: Int = 0) {
        self.onSearch = onSearch
        _preset = preset
        self.filterRequest = filterRequest
    }

    var body: some View {
        Group {
            libraryPage
                .background(Theme.pageBackground.ignoresSafeArea())
            .onChange(of: preset) { value in
                guard let value else { return }
                apply(value)
                preset = nil
            }
            .onAppear {
                if let value = preset { apply(value); preset = nil }
            }
        }
        .designScreen("catalog")
        .playerWindow(item: $playing) { queue in
            PlayerView(source: queue.source, playlist: queue.items)
                .environmentObject(appState)
        }
        .fullScreenCover(isPresented: $showManagement) { LibraryManagementView() }
        .sheet(item: $matching) { request in
            MetadataMatchView(file: request.file, current: request.current, onMatch: { metadata in
                for target in request.targets { await metadataStore.match(metadata, to: target) }
            }, onClear: request.current == nil ? nil : { () async -> Void in
                for target in request.targets { await metadataStore.unmatch(target) }
            })
        }
    }

    // MARK: 片库页

    /// 片库页：和首页同一套顶部（频道条、搜索框、轮播「最近加入」），下面一排类型快捷入口、
    /// 地区 / 年份 / 排序三个下拉筛选，再下面是海报墙。搜索框右侧「筛选」滚到筛选区。
    private var libraryPage: some View {
        GeometryReader { proxy in
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        AmbientHeroSection(slides: HomeSlide.recentLibrary(snapshot), carouselLabel: "最近加入",
                                           carouselIdentifier: "catalog.carouselPosition",
                                           safeTop: insets.top, width: proxy.size.width) {
                            EmptyView()
                        } hitArea: { slide in
                            librarySlideHitArea(slide)
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            kindShortcuts
                                .id("catalog.filters")
                            filterChips
                            if !snapshot.unmatched.isEmpty { unmatchedBanner }
                            grid(width: proxy.size.width)
                        }
                        .padding(.top, 16)
                    }
                    .padding(.bottom, 32)
                    .tracksPageScroll()
                }
                .pageScrollContainer()
                .scrollIndicators(.hidden)
                .ignoresSafeArea(edges: .top)
                .onChange(of: filterRequest) { _ in
                    // 头部的「筛选」：滚到类型 / 地区 / 年份 / 排序那一块
                    withAnimation(reduceMotion ? nil : Motion.smooth) {
                        reader.scrollTo("catalog.filters", anchor: UnitPoint(x: 0.5, y: 0.22))
                    }
                }
            }
        }
    }

    /// 点轮播：直接播放；长按：播放、匹配封面。
    @ViewBuilder
    private func librarySlideHitArea(_ slide: HomeSlide) -> some View {
        if case .library(let item) = slide.content {
            Button {
                playing = HomeLibrary.queue(for: item, in: snapshot.items)
            } label: {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("播放 \(item.title)")
            .accessibilityIdentifier("catalog.slide.\(item.id)")
            .contextMenu {
                Button("播放", systemImage: AppIcon.play.name) {
                    playing = HomeLibrary.queue(for: item, in: snapshot.items)
                }
                Button("匹配封面", systemImage: AppIcon.poster.name) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { matching = MatchRequest(item: item) }
                }
            } preview: {
                HomeSlidePreview(slide: slide)
            }
        }
    }

    private func apply(_ value: CatalogPreset) {
        withAnimation(reduceMotion ? nil : Motion.smooth) {
            kind = value.kind
            sort = value.sort
            region = .all
            year = .all
        }
    }

    // MARK: 数据

    /// 网格条目由 LibrarySnapshotStore 在后台调用生成。
    nonisolated static func makeEntries(_ snapshot: HomeSnapshot, recents: [RecentItem]) -> [CatalogEntry] {
        // 最近播放的先后：按记录顺序给每个片库文件编号
        var rank: [String: Int] = [:]
        let localByName = Dictionary(snapshot.items.filter { $0.media.localURL != nil }.map { ($0.media.name, $0.id) },
                                     uniquingKeysWith: { first, _ in first })
        for (index, recent) in recents.enumerated() {
            if let pickCode = recent.pickCode, !pickCode.isEmpty {
                rank["115|\(pickCode)"] = rank["115|\(pickCode)"] ?? index
            } else if let url = URL(string: recent.url), let id = localByName[url.lastPathComponent] {
                rank[id] = rank[id] ?? index
            }
        }
        let order = Dictionary(snapshot.items.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })

        var result: [CatalogEntry] = []
        for item in snapshot.movies {
            guard let metadata = item.metadata else { continue }
            result.append(CatalogEntry(
                id: "movie|\(item.id)", payload: .movie(item), title: item.title,
                year: CatalogEntry.parseYear(metadata.year), rating: Double(metadata.rating),
                country: metadata.country, genres: metadata.genres,
                addedOrder: order[item.id] ?? 0, playedRank: rank[item.id]
            ))
        }
        for group in snapshot.series {
            let ranks = group.episodes.compactMap { rank[$0.id] }
            result.append(CatalogEntry(
                id: "series|\(group.id)", payload: .series(group), title: group.title,
                year: CatalogEntry.parseYear(group.year), rating: Double(group.rating),
                country: group.metadata.country, genres: group.metadata.genres,
                addedOrder: group.episodes.compactMap { order[$0.id] }.max() ?? 0, playedRank: ranks.min()
            ))
        }
        for group in snapshot.performers {
            result.append(CatalogEntry(
                id: "performer|\(group.id)", payload: .performer(group), title: group.name,
                year: nil, rating: nil, country: "", genres: [],
                addedOrder: group.collectionItems.compactMap { order[$0.id] }.max() ?? 0, playedRank: nil
            ))
        }
        return result
    }

    /// 当前筛选和排序后的结果
    private var visible: [CatalogEntry] {
        var list = entries.filter { entry in
            switch kind {
            case .all:
                if case .performer = entry.payload { return false }
            case .movie:
                guard case .movie = entry.payload else { return false }
            case .series:
                guard case .series = entry.payload else { return false }
            case .anime:
                if case .performer = entry.payload { return false }
                if !entry.isAnime { return false }
            case .performer:
                guard case .performer = entry.payload else { return false }
            }
            if kind != .performer {
                if region != .all, CatalogRegion.region(of: entry.country) != region { return false }
                if !year.matches(entry.year) { return false }
            }
            return true
        }
        switch sort {
        case .recentlyAdded:
            list.sort { $0.addedOrder > $1.addedOrder }
        case .recentlyPlayed:
            list.sort {
                switch ($0.playedRank, $1.playedRank) {
                case let (a?, b?): return a < b
                case (_?, nil): return true
                case (nil, _?): return false
                default: return $0.addedOrder > $1.addedOrder
                }
            }
        case .topRated:
            list.sort { ($0.rating ?? -1) > ($1.rating ?? -1) }
        case .title:
            list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        return list
    }

    private var subtitle: String {
        let movies = snapshot.movies.count
        let series = snapshot.series.count
        guard movies + series > 0 else { return "" }
        var text = "共 \(movies + series) 部"
        if !snapshot.performers.isEmpty { text += " · 演员 \(snapshot.performers.count) 位" }
        return text
    }

    // MARK: 筛选

    /// 类型快捷入口：全部 / 电影 / 剧集 / 动画 / 演员，选中的实心。
    private var kindShortcuts: some View {
        HStack(spacing: 4) {
            ForEach(CatalogKind.allCases) { option in
                ChannelShortcut(title: option.shortcutTitle, icon: option.icon, tint: option.tint, selected: kind == option) {
                    withAnimation(reduceMotion ? nil : Motion.snappy) { kind = option }
                }
                .accessibilityIdentifier("catalog.kind.\(option.id)")
            }
        }
        .padding(.horizontal, 10)
    }

    /// 地区、年份（演员合集不适用，不显示）和排序三个下拉胶囊；右边是数量。
    private var filterChips: some View {
        HStack(spacing: 6) {
            if kind != .performer {
                FilterMenuChip(options: CatalogRegion.allCases, selection: animated($region), defaultValue: .all,
                               title: { $0.title }, identifier: "catalog.region")
                FilterMenuChip(options: CatalogYear.allCases, selection: animated($year), defaultValue: .all,
                               title: { $0.title }, identifier: "catalog.year")
            }
            FilterMenuChip(options: CatalogSort.allCases, selection: animated($sort), defaultValue: .recentlyAdded,
                           title: { $0.titleText }, identifier: "catalog.sort")
            Spacer(minLength: 8)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.contentInset)
    }

    private func animated<Value>(_ binding: Binding<Value>) -> Binding<Value> {
        Binding(get: { binding.wrappedValue }, set: { value in
            withAnimation(reduceMotion ? nil : Motion.snappy) { binding.wrappedValue = value }
        })
    }

    private var unmatchedBanner: some View {
        Button { showManagement = true } label: {
            HStack(spacing: 10) {
                Circle().fill(Theme.gold).frame(width: 8, height: 8)
                Text("\(snapshot.unmatched.count) 个视频还没配上封面").font(.system(size: 13))
                Spacer(minLength: 8)
                Text("去处理 ›").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            .padding(.horizontal, Theme.contentInset)
        }
        .buttonStyle(.pressable(scale: 0.98))
        .accessibilityIdentifier("catalog.unmatched")
    }

    // MARK: 网格

    @ViewBuilder
    private func grid(width: CGFloat) -> some View {
        let list = visible
        if !librarySnapshots.catalogReady {
            // 条目还在后台准备（刚启动就切过来时），先留出位置，不闪「片库还是空的」
            Color.clear.frame(height: 320)
        } else if list.isEmpty {
            EmptyStateView(
                icon: AppIcon.library.name,
                title: entries.isEmpty ? "片库还是空的" : "没有符合条件的影片",
                message: entries.isEmpty ? "在首页添加 115 文件夹或导入本机视频，影片配上封面后会出现在这里。" : "换一个筛选条件试试。"
            )
            .frame(minHeight: 320)
        } else {
            // 演员卡是两张海报拼在一起，三列时每张只剩一半宽，挤成碎条；演员分类改成两列（宽屏按 170pt 一格往上加）
            let performers = kind == .performer
            let spacing: CGFloat = performers ? 14 : 10
            let available = max(width - Theme.contentInset * 2, 200)
            let columns = performers
                ? max(2, Int((available + spacing) / (170 + spacing)))
                : max(3, Int((available + spacing) / (118 + spacing)))
            let cell = floor((available - spacing * CGFloat(columns - 1)) / CGFloat(columns))
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(cell), spacing: spacing, alignment: .top), count: columns),
                alignment: .leading, spacing: performers ? 20 : 16
            ) {
                ForEach(Array(list.enumerated()), id: \.element.id) { index, entry in
                    card(entry, width: cell)
                        .reveal(index, id: entry.id)
                        .prefetchArtwork(after: index, in: list, count: columns * 3) { Self.posterURL(of: $0) }
                        .gridCardEntrance()
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
            // 换筛选时的增删动画由筛选胶囊的 withAnimation 带出来；这里不再对整个 id 列表做隐式动画，
            // 否则第一次填进上千张卡片时每张都要做一次插入动画，标签栏的液态玻璃也跟着卡在半路。
            .padding(.horizontal, Theme.contentInset)
        }
    }

    @ViewBuilder
    private func card(_ entry: CatalogEntry, width: CGFloat) -> some View {
        switch entry.payload {
        case .movie(let item):
            PosterCard(item: item, width: width) {
                playing = HomeLibrary.queue(for: item, in: snapshot.items)
            } onDelete: {
                delete(item)
            } onMatch: {
                matching = MatchRequest(item: item)
            }
        case .series(let group):
            NavigationLink {
                SeriesDetailView(seriesID: group.id)
            } label: {
                SeriesPosterCard(group: group, width: width)
            }
            .buttonStyle(PosterButtonStyle())
            .accessibilityIdentifier("catalog.series.\(group.id)")
            .contextMenu {
                Button("匹配封面", systemImage: AppIcon.poster.name) { matching = MatchRequest(group: group) }
            }
        case .performer(let group):
            PerformerNavigationLink(group: group) {
                PerformerCollageCard(group: group, width: width)
            }
            .buttonStyle(PosterButtonStyle())
            .accessibilityIdentifier("catalog.performer.\(group.id)")
        }
    }

    /// 卡片上显示的那张海报的地址（用于提前取图）。
    private static func posterURL(of entry: CatalogEntry) -> String {
        switch entry.payload {
        case .movie(let item): return item.posterURL
        case .series(let group): return group.posterURL
        case .performer(let group): return group.posterURL
        }
    }

    private func delete(_ item: HomeMediaItem) {
        if let local = localStore.files.first(where: { $0.id == item.id }) {
            localStore.delete(local)
        } else {
            mediaLibrary.remove(pickCode: item.media.pickCode, for: appState)
        }
    }
}

/// 从首页分类进入片库时预设的条件
struct CatalogPreset: Equatable {
    var kind: CatalogKind = .all
    var sort: CatalogSort = .recentlyAdded
}
