import Foundation

/// 在线/动漫播放的可选画质档位
struct PlaybackQualityItem: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let url: URL
}

/// 播放源：既可以直接是一个 URL，也可以是 115 网盘里的文件，或带有画质档位的在线流。
/// 这样播放器本身不依赖 115，115 只是其中一种来源。
enum PlaybackSource: Identifiable, Hashable {
    case direct(title: String, url: URL)
    case online(title: String, url: URL, headers: [String: String], qualities: [PlaybackQualityItem] = [], currentQuality: String = "")
    case p115(title: String, pickCode: String)
    /// 在线动漫的一集。地址带时效签名，打开时才现解析，所以播放列表里存的是集数引用而不是 URL。
    case anime(AnimeEpisodeRef)

    var id: String {
        switch self {
        case .direct(let title, let url):
            return "direct|\(title)|\(url.absoluteString)"
        case .online(let title, let url, _, _, _):
            return "online|\(title)|\(url.absoluteString)"
        case .p115(_, let pickCode):
            return "p115|\(pickCode)"
        case .anime(let ref):
            return ref.id
        }
    }

    var title: String {
        switch self {
        case .direct(let title, _), .online(let title, _, _, _, _):
            return title
        case .p115(let title, _):
            return title
        case .anime(let ref):
            return ref.episodeTitle
        }
    }
}

struct PlaybackQueue: Identifiable {
    let source: PlaybackSource
    let items: [PlaybackSource]
    var id: String { source.id }
}

/// 一条播放记录。直接地址存 url，115 文件存 pickCode；看到的位置和总时长用来续播和画进度条。
struct RecentItem: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var url: String
    var playedAt: Date
    var pickCode: String? = nil
    var position: Double? = nil
    var duration: Double? = nil
    /// 看到片尾被判定为看完。快看完时 position 会被清掉（下次从头播），
    /// 所以「看完」要单独记一个标记，选集格子才能打勾。可选是为了兼容旧记录。
    var finished: Bool? = nil
    /// 动漫集数坐标。存下来才能在「继续观看」里重新解析一个新鲜地址——
    /// 旧记录里的 url 带时效签名，放一会儿就失效了。都可选是为了兼容旧记录。
    var animeId: Int? = nil
    var animePlay: String? = nil
    var animeRoute: Int? = nil
    var animePart: String? = nil

    /// 番剧名从标题里还原（标题固定是「番剧名 第XX集」），不额外存一份。
    var animeRef: AnimeEpisodeRef? {
        guard let animeId, let play = animePlay, let part = animePart, !part.isEmpty else { return nil }
        let suffix = " \(part)"
        let name = title.hasSuffix(suffix) ? String(title.dropLast(suffix.count)) : title
        return AnimeEpisodeRef(animeId: animeId, seriesName: name, play: play,
                               routeIndex: animeRoute ?? 0, part: part)
    }

    /// 看过的比例，没有记录时为空
    var progress: Double? {
        guard let position, let duration, duration > 0 else { return nil }
        return min(max(position / duration, 0), 1)
    }

    var isCloud: Bool { !(pickCode ?? "").isEmpty }
    var isLocalFile: Bool { !isCloud && (URL(string: url)?.isFileURL ?? false) }
    var isAnime: Bool {
        if animeRef != nil { return true }
        // 旧记录只有流地址，按 CDN 域名认
        return !isCloud && !isLocalFile && (url.contains("cenmo.fun") || url.contains("hzhcbkj.cn") || url.contains("xhscdn.com") || url.contains("kechuangai.com") || url.contains("yximgs.com"))
    }
}
