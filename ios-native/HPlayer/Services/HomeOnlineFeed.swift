import Foundation
import Combine

/// 首页「推荐」里的在线内容：顶部轮播的热播横图、热门新番（最多播放）、最新更新（最新上架）。
/// 和动漫频道共用 AnimeClient；数据只在内存里，进首页时按需拉取。
@MainActor
final class HomeOnlineFeed: ObservableObject {
    static let shared = HomeOnlineFeed()

    /// 热播横图（/app/banners），约 1700×920 的 16:9 图，和片库精选一起放进首页轮播
    @Published private(set) var banners: [AnimeBanner] = []
    /// 热门新番：按播放量排（sort=hits）。接口的 weight 排序和 addtime 一模一样，不能拿来当「热门」。
    @Published private(set) var trending: [AnimeVideoItem] = []
    /// 最新更新：按上架时间排（sort=addtime）
    @Published private(set) var latest: [AnimeVideoItem] = []
    private var loadedAt: Date?
    private var loading = false

    private init() {
        if InterfacePreview.active { trending = Self.previewTrending }
    }

    /// 下拉刷新：不管十分钟的间隔，重新拉一遍
    func refresh() async {
        loadedAt = nil
        await loadIfNeeded()
    }

    /// 进入首页时调用；十分钟内不重复拉。界面截图（InterfacePreview）不联网。
    func loadIfNeeded() async {
        // 单元测试把 App 当宿主启动，这时不去请求真实的动漫接口，免得和测试里的网络桩抢资源
        let hostedUnitTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        guard !InterfacePreview.active, !hostedUnitTest, !loading else { return }
        // 十分钟内不重复拉；但轮播还空着（上次没拉到）就单独补拉一次
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 600, !trending.isEmpty {
            if banners.isEmpty { await loadBanners() }
            return
        }
        loading = true
        defer { loading = false }
        async let hot = try? AnimeClient.shared.fetchVideoList(sort: "hits", limit: 12, page: 1)
        async let fresh = try? AnimeClient.shared.fetchVideoList(sort: "addtime", limit: 12, page: 1)
        async let heroes = try? AnimeClient.shared.fetchBanners()
        let (hotResult, freshResult, bannerResult) = await (hot, fresh, heroes)
        if let items = hotResult?.items, !items.isEmpty { trending = items }
        if let items = freshResult?.items, !items.isEmpty { latest = items }
        if let bannerResult, !bannerResult.isEmpty { banners = bannerResult.filter { !$0.img.isEmpty } }
        if hotResult != nil || freshResult != nil { loadedAt = Date() }
        AnimeWatchlistStore.shared.refreshUpdates(from: trending + latest)
    }

    private func loadBanners() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        if let result = try? await AnimeClient.shared.fetchBanners(), !result.isEmpty {
            banners = result.filter { !$0.img.isEmpty }
        }
    }

    /// 界面截图里的热门新番：没有封面地址，卡片画占位海报，不联网。
    private static let previewTrending: [AnimeVideoItem] = [
        AnimeVideoItem(id: 900001, name: "雪王来了！", continu: "28|周四五11:00更", total: 28, isend: 0, type: "搞笑,日常"),
        AnimeVideoItem(id: 900002, name: "东大高武学院", continu: "更新至26集", total: 52, isend: 0, type: "热血,玄幻"),
        AnimeVideoItem(id: 900003, name: "大夏守墓人", continu: "更新至18集", total: 40, isend: 0, type: "国创,玄幻"),
        AnimeVideoItem(id: 900004, name: "逆天邪神 年番", continu: "全52集", total: 52, isend: 1, type: "国创,热血"),
        AnimeVideoItem(id: 900005, name: "黑色五叶草 第二季", continu: "6#周六23:00更", total: 12, isend: 0, type: "战斗,奇幻"),
        AnimeVideoItem(id: 900006, name: "新网球王子 U-17 世界杯", continu: "7#周四00:30更", total: 12, isend: 0, type: "运动,漫画改"),
    ]
}
