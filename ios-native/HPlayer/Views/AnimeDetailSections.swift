import SwiftUI

// MARK: - 全部选集面板

/// 「全部」选集：底部面板。集数多（一两百集）时按 50 集一段分页，段落胶囊左右滑；
/// 线路（国语 / 粤语…）和正序 / 倒序也在这里。点一集就开始播放并收起面板。
struct AnimeEpisodeSheet: View {
    let detail: AnimeVideoDetail
    @Binding var routeIndex: Int
    let activeEpisode: String?
    let progress: (String) -> Double?
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isDescending = false
    @State private var rangeIndex = 0
    @Namespace private var routeSpace
    @Namespace private var rangeSpace

    static let rangeSize = 50

    private var episodes: [String] {
        detail.parts.indices.contains(routeIndex) ? detail.parts[routeIndex].part : (detail.parts.first?.part ?? [])
    }

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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("选集")
                    .font(.system(size: 18, weight: .bold))
                Text("共 \(episodes.count) 集")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 8)
                orderToggle
            }
            .padding(.horizontal, Theme.contentInset)
            .padding(.top, 20)

            if detail.parts.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(Array(detail.parts.enumerated()), id: \.element.id) { index, route in
                            SelectionPill(title: "\(route.playZh) · \(route.part.count) 集", selected: index == routeIndex,
                                          namespace: routeSpace) {
                                withAnimation(Motion.snappy) { routeIndex = index }
                                rangeIndex = rangeContainingActive()
                            }
                        }
                    }
                    .padding(.horizontal, Theme.contentInset)
                }
                .scrollIndicators(.hidden)
            }

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
                            }
                        }
                        .padding(.horizontal, Theme.contentInset)
                    }
                    .scrollIndicators(.hidden)
                    .onAppear { proxy.scrollTo(rangeIndex, anchor: .center) }
                }
            }

            ScrollView {
                AnimeEpisodeMatrix(episodes: visibleEpisodes, activeEpisode: activeEpisode, progress: progress) { episode in
                    onSelect(episode)
                    dismiss()
                }
                .padding(.horizontal, Theme.contentInset)
                .padding(.bottom, 24)
                .id("range-\(routeIndex)-\(rangeIndex)-\(isDescending)")
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .onAppear { rangeIndex = rangeContainingActive() }
    }

    private var orderToggle: some View {
        HStack(spacing: 0) {
            orderPill("正序", icon: .sortAscending, selected: !isDescending) { setOrder(descending: false) }
            orderPill("倒序", icon: .sortDescending, selected: isDescending) { setOrder(descending: true) }
        }
        .padding(2)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func setOrder(descending: Bool) {
        guard descending != isDescending else { return }
        withAnimation(Motion.snappy) {
            isDescending = descending
            rangeIndex = rangeContainingActive()
        }
    }

    private func orderPill(_ title: String, icon: AppIcon, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.select()
            action()
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
            .hidesTabBar()
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
