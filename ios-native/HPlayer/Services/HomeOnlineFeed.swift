import Foundation
import Combine

/// 首页「推荐」频道里的在线内容：热门新番与最新更新。
/// 只拉两页列表，失败时安静地留空（不影响片库货架）；顺便用结果给「我的追番」标更新。
@MainActor
final class HomeOnlineFeed: ObservableObject {
    static let shared = HomeOnlineFeed()

    @Published private(set) var trending: [AnimeVideoItem] = []
    @Published private(set) var latest: [AnimeVideoItem] = []
    private var loadedAt: Date?
    private var loading = false

    private init() {}

    /// 进入首页时调用；十分钟内不重复拉。界面截图（InterfacePreview）不联网。
    func loadIfNeeded() async {
        guard !InterfacePreview.active, !loading else { return }
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 600, !trending.isEmpty { return }
        loading = true
        defer { loading = false }
        async let hot = try? AnimeClient.shared.fetchVideoList(sort: "weight", limit: 12, page: 1)
        async let fresh = try? AnimeClient.shared.fetchVideoList(sort: "addtime", limit: 12, page: 1)
        let (hotResult, freshResult) = await (hot, fresh)
        if let items = hotResult?.items, !items.isEmpty { trending = items }
        if let items = freshResult?.items, !items.isEmpty { latest = items }
        if hotResult != nil || freshResult != nil { loadedAt = Date() }
        AnimeWatchlistStore.shared.refreshUpdates(from: trending + latest)
    }
}
