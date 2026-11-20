import SwiftUI

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
            .toolbar(.visible, for: .navigationBar)
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
