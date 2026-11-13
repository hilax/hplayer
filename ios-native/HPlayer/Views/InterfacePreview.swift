import Foundation

/// A launch-only switch for simulator screenshots. Fixture data is compiled only in Debug.
enum InterfacePreview {
    static var screen: String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["HPLAYER_DESIGN_SCREEN"]
        #else
        return nil
        #endif
    }
    static var active: Bool { screen != nil }

    #if DEBUG
    /// 从真实首页海报进入详情的界面测试，不访问外部动漫服务。
    static func animeDetail(id: Int) async throws -> AnimeVideoDetail? {
        guard active else { return nil }
        let environment = ProcessInfo.processInfo.environment
        if environment["HPLAYER_ANIME_DETAIL_DELAY"] == "1" {
            try await Task.sleep(nanoseconds: 8_000_000_000)
        }
        if environment["HPLAYER_ANIME_DETAIL_FAILURE"] == "1" {
            throw AnimeClientError.networkError("详情加载测试")
        }
        return AnimeVideoDetail(
            id: id, name: "雪王来了！",
            parts: [AnimePlayRoute(play: "preview", playZh: "国语", singleClarityDisplay: nil,
                                  part: ["第01集", "第02集", "第03集"])],
            continu: "更新至3集", year: "2026", area: "大陆", type: "搞笑,日常",
            content: "动漫详情导航回归使用的离线数据。"
        )
    }
    #endif
}
