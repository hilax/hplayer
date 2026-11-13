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
    /// 通过实际网盘入口检查目录路由，沿用 DirectoryView 的初始文件接口。
    static func cloudFiles(cid: String) -> [P115File]? {
        guard active else { return nil }
        func file(_ id: String, _ name: String, folder: Bool = true) -> P115File {
            P115File(id: id, parentId: cid, name: name, isDir: folder,
                     kind: folder ? "folder" : "video", size: folder ? 0 : 1_000_000,
                     pickCode: folder ? "" : "preview-" + id, sha1: "", updatedAt: "", thumbUrl: "")
        }
        switch cid {
        case "0": return [file("100", "电影"), file("200", "剧集")]
        case "100": return [file("101", "科幻"), file("movie", "电影.mp4", folder: false)]
        case "101": return [file("science-fiction", "科幻电影.mp4", folder: false)]
        case "200": return [file("episode", "剧集.S01E01.mp4", folder: false)]
        default: return []
        }
    }

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
