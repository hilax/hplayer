import SwiftUI

// MARK: - 展开的选集面板

/// 点「全部」后在选集栏里原地展开：集数多（一两百集）时按 50 集一段，段落胶囊左右滑；下面是五列选集格子。
/// 正序 / 倒序由详情页的标题行控制（展开时才出现）。
struct AnimeEpisodePanel: View {
    let episodes: [String]
    let activeEpisode: String?
    let isDescending: Bool
    let progress: (String) -> Double?
    let onSelect: (String) -> Void

    @State private var rangeIndex = 0
    @Namespace private var rangeSpace

    static let rangeSize = 50

    /// 50 集一段：「1-50」「51-100」…；倒序时段落也倒过来
    private var ranges: [Range<Int>] {
        let count = episodes.count
        guard count > 0 else { return [] }
        let list = stride(from: 0, to: count, by: Self.rangeSize).map { $0..<min($0 + Self.rangeSize, count) }
        return isDescending ? list.reversed() : list
    }

    private var visibleEpisodes: [String] {
        guard ranges.indices.contains(rangeIndex) else { return [] }
        let slice = Array(episodes[ranges[rangeIndex]])
        return isDescending ? slice.reversed() : slice
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if ranges.count > 1 {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(Array(ranges.enumerated()), id: \.offset) { index, range in
                                SelectionPill(title: "\(range.lowerBound + 1)-\(range.upperBound)", selected: index == rangeIndex,
                                              namespace: rangeSpace) {
                                    withAnimation(Motion.snappy) { rangeIndex = index }
                                }
                                .id(index)
                                .accessibilityIdentifier("anime.episodes.range.\(range.lowerBound + 1)")
                            }
                        }
                        .padding(.horizontal, Theme.contentInset - 4)
                    }
                    .scrollIndicators(.hidden)
                    .padding(.horizontal, -Theme.contentInset)
                    .onAppear { proxy.scrollTo(rangeIndex, anchor: .center) }
                    .onChange(of: rangeIndex) { index in
                        withAnimation(Motion.smooth) { proxy.scrollTo(index, anchor: .center) }
                    }
                }
            }

            AnimeEpisodeMatrix(episodes: visibleEpisodes, activeEpisode: activeEpisode, progress: progress) { episode in
                onSelect(episode)
            }
            .id("range-\(rangeIndex)-\(isDescending)-\(episodes.count)")
        }
        .onAppear { rangeIndex = rangeContainingActive() }
        .onChange(of: isDescending) { _ in rangeIndex = rangeContainingActive() }
        .onChange(of: episodes) { _ in rangeIndex = rangeContainingActive() }
    }

    /// 当前在看的那一集落在哪一段（没有就第一段）
    private func rangeContainingActive() -> Int {
        guard let activeEpisode, let position = episodes.firstIndex(of: activeEpisode) else { return 0 }
        return ranges.firstIndex { $0.contains(position) } ?? 0
    }
}

// MARK: - 评论页

/// 详情页「评论 · 全部」推进来的整页评论：最热 / 最新切换、置顶在前、最新可以一直往下翻。
struct AnimeCommentsPage: View {
    let vid: Int
    let title: String

    var body: some View {
        AnimeCommentsView(vid: vid)
            .background(Theme.pageBackground.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// 详情页里的评论预览：置顶和热评里取前三条。
struct AnimeCommentPreview {
    static func load(vid: Int) async -> [AnimeComment]? {
        guard !InterfacePreview.active else { return [] }
        async let top = try? AnimeClient.shared.fetchComments(.top, vid: vid)
        async let hot = try? AnimeClient.shared.fetchComments(.hot, vid: vid)
        let (pinned, hotPage) = await (top, hot)
        var list = (pinned?.items ?? []) + (hotPage?.items ?? [])
        if list.isEmpty {
            guard let latest = try? await AnimeClient.shared.fetchComments(.list, vid: vid, page: 1) else {
                return pinned == nil && hotPage == nil ? nil : []
            }
            list = latest.items
        }
        var seen = Set<String>()
        return Array(list.filter { seen.insert($0.id).inserted }.prefix(3))
    }
}

/// 大数字写成「14.1万」
func compactCount(_ value: Int) -> String {
    if value >= 100_000_000 { return String(format: "%.1f亿", Double(value) / 100_000_000) }
    if value >= 10_000 { return String(format: "%.1f万", Double(value) / 10_000) }
    return "\(value)"
}
