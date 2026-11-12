import Foundation

// MARK: - 导航路由
//
// 用值类型路由而不是 `navigationDestination(isPresented:)`：后者的布尔绑定
// 在 SwiftUI 重建视图时容易被重置，点击后看起来「没反应」。
struct AnimeDetailRoute: Hashable {
    let animeId: Int
}

// MARK: - 统一 API 响应包装外壳

struct AnimeAPIResponse<T: Codable>: Codable {
    let code: Int
    let message: String
    let data: T?
}

// MARK: - 分类与频道模型

struct AnimeChannel: Identifiable, Codable, Hashable {
    let id: Int
    let name: String
    let types: [String]?
    let years: [String]?
    let areas: [String]?
    let oid: Int?
    let pid: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, types, years, areas, oid, pid
    }
}

// MARK: - 轮播 Banner

struct AnimeBanner: Identifiable, Codable, Hashable {
    let id: Int
    let vid: Int?
    let img: String
    let vname: String
    let continu: String?
    let content: String?
    /// 评分。接口里有整数也有小数（实测 2026-11-12 出现过 9.5），按 Double 读
    let gold: Double?
    let oid: Int?
    let pid: Int?

    var displayTitle: String { vname }
    var displayImage: String { img }
    var safePicURLString: String {
        if img.hasPrefix("http://") {
            return "https://" + img.dropFirst(7)
        }
        return img
    }
    var displayRemarks: String { continu ?? "" }
    var displayDesc: String {
        (content ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}

extension AnimeBanner {
    enum CodingKeys: String, CodingKey {
        case id, vid, img, vname, continu, content, gold, oid, pid
    }

    /// 宽松解码：数字字段可能是整数、小数或字符串，单个字段类型不对只丢这个字段，不让整组轮播解码失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        vid = Self.int(c, .vid)
        img = (try? c.decode(String.self, forKey: .img)) ?? ""
        vname = (try? c.decode(String.self, forKey: .vname)) ?? ""
        continu = try? c.decodeIfPresent(String.self, forKey: .continu)
        content = try? c.decodeIfPresent(String.self, forKey: .content)
        if let value = try? c.decodeIfPresent(Double.self, forKey: .gold) {
            gold = value
        } else if let text = try? c.decodeIfPresent(String.self, forKey: .gold) {
            gold = Double(text)
        } else {
            gold = nil
        }
        oid = Self.int(c, .oid)
        pid = Self.int(c, .pid)
    }

    private static func int(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? c.decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let text = try? c.decodeIfPresent(String.self, forKey: key) { return Int(text) }
        return nil
    }
}

// MARK: - 视频条目模型（列表与搜索）

struct AnimeVideoListResult: Codable {
    let total: Int
    let items: [AnimeVideoItem]
}

struct AnimeVideoItem: Identifiable, Codable, Hashable {
    let id: Int
    let cid: Int?
    let name: String
    let ename: String?
    let pic: String?
    let year: String?
    let area: String?
    let continu: String?
    let total: Int?
    let isend: Int?
    let type: String?
    let actor: String?
    let director: String?
    let content: String?
    let updatedAt: String?
    let stars: String?

    enum CodingKeys: String, CodingKey {
        case id, cid, name, ename, pic, year, area, continu, total, isend, type, actor, director, content
        case updatedAt = "updated_at"
        case stars
    }

    init(id: Int, cid: Int? = nil, name: String, ename: String? = nil, pic: String? = nil,
         year: String? = nil, area: String? = nil, continu: String? = nil, total: Int? = nil,
         isend: Int? = nil, type: String? = nil, actor: String? = nil, director: String? = nil,
         content: String? = nil, updatedAt: String? = nil, stars: String? = nil) {
        self.id = id
        self.cid = cid
        self.name = name
        self.ename = ename
        self.pic = pic
        self.year = year
        self.area = area
        self.continu = continu
        self.total = total
        self.isend = isend
        self.type = type
        self.actor = actor
        self.director = director
        self.content = content
        self.updatedAt = updatedAt
        self.stars = stars
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        cid = try c.decodeIfPresent(Int.self, forKey: .cid)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        ename = try c.decodeIfPresent(String.self, forKey: .ename)
        pic = try c.decodeIfPresent(String.self, forKey: .pic)
        year = try c.decodeIfPresent(String.self, forKey: .year)
        area = try c.decodeIfPresent(String.self, forKey: .area)
        continu = try c.decodeIfPresent(String.self, forKey: .continu)
        total = try c.decodeIfPresent(Int.self, forKey: .total)
        isend = try c.decodeIfPresent(Int.self, forKey: .isend)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        actor = try c.decodeIfPresent(String.self, forKey: .actor)
        director = try c.decodeIfPresent(String.self, forKey: .director)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)

        if let str = try? c.decodeIfPresent(String.self, forKey: .stars) {
            stars = str
        } else if let intVal = try? c.decodeIfPresent(Int.self, forKey: .stars) {
            stars = String(intVal)
        } else if let num = try? c.decodeIfPresent(Double.self, forKey: .stars) {
            stars = String(num)
        } else {
            stars = nil
        }
    }

    var cleanDesc: String {
        (content ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    var safePicURLString: String {
        guard let raw = pic, !raw.isEmpty else { return "" }
        if raw.hasPrefix("http://") {
            return "https://" + raw.dropFirst(7)
        }
        return raw
    }

    var tags: [String] {
        (type ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - 详情与选集模型

struct AnimeVideoDetail: Identifiable, Codable, Hashable {
    let id: Int
    let name: String
    let source: String?
    let parts: [AnimePlayRoute]
    let continu: String?
    let year: String?
    let area: String?
    let type: String?
    let actor: String?
    let director: String?
    let content: String?
    let stars: String?
    let autoPlay: Int?
    let pic: String?
    /// 播放量、评论数、弹幕数（详情接口有，列表没有；旧缓存里可能缺）
    var hits: Int? = nil
    var commentTotal: Int? = nil
    var danmuCount: Int? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, source, parts, continu, year, area, type, actor, director, content, stars, pic, hits
        case autoPlay = "auto_play"
        case commentTotal = "comment_total"
        case danmuCount = "danmu_count"
    }

    init(id: Int, name: String, source: String? = nil, parts: [AnimePlayRoute] = [],
         continu: String? = nil, year: String? = nil, area: String? = nil, type: String? = nil,
         actor: String? = nil, director: String? = nil, content: String? = nil,
         stars: String? = nil, autoPlay: Int? = nil, pic: String? = nil) {
        self.id = id
        self.name = name
        self.source = source
        self.parts = parts
        self.continu = continu
        self.year = year
        self.area = area
        self.type = type
        self.actor = actor
        self.director = director
        self.content = content
        self.stars = stars
        self.autoPlay = autoPlay
        self.pic = pic
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source)
        parts = (try? c.decodeIfPresent([AnimePlayRoute].self, forKey: .parts)) ?? []
        continu = try c.decodeIfPresent(String.self, forKey: .continu)
        year = try c.decodeIfPresent(String.self, forKey: .year)
        area = try c.decodeIfPresent(String.self, forKey: .area)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        actor = try c.decodeIfPresent(String.self, forKey: .actor)
        director = try c.decodeIfPresent(String.self, forKey: .director)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        autoPlay = try? c.decodeIfPresent(Int.self, forKey: .autoPlay)
        pic = try c.decodeIfPresent(String.self, forKey: .pic)
        hits = Self.lenientInt(c, .hits)
        commentTotal = Self.lenientInt(c, .commentTotal)
        danmuCount = Self.lenientInt(c, .danmuCount)

        if let str = try? c.decodeIfPresent(String.self, forKey: .stars) {
            stars = str
        } else if let intVal = try? c.decodeIfPresent(Int.self, forKey: .stars) {
            stars = String(intVal)
        } else if let num = try? c.decodeIfPresent(Double.self, forKey: .stars) {
            stars = String(num)
        } else {
            stars = nil
        }
    }

    private static func lenientInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? c.decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let text = try? c.decodeIfPresent(String.self, forKey: key) { return Int(text) }
        return nil
    }

    var cleanDesc: String {
        (content ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    var safePicURLString: String {
        guard let raw = pic, !raw.isEmpty else { return "" }
        if raw.hasPrefix("http://") {
            return "https://" + raw.dropFirst(7)
        }
        return raw
    }

    var tags: [String] {
        (type ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

struct AnimePlayRoute: Identifiable, Codable, Hashable {
    var id: String { play }
    let play: String
    let playZh: String
    let singleClarityDisplay: Int?
    let part: [String]

    enum CodingKeys: String, CodingKey {
        case play
        case playZh = "play_zh"
        case singleClarityDisplay = "single_clarity_display"
        case part
    }
}

// MARK: - 播放凭证响应模型

struct AnimePlayResponse: Codable {
    let url: String
    let parse: String?
    let play: String?
    let playZh: String?
    let part: String?
    let resolution: String?
    let singleClarityDisplay: Int?

    enum CodingKeys: String, CodingKey {
        case url, parse, play
        case playZh = "play_zh"
        case part, resolution
        case singleClarityDisplay = "single_clarity_display"
    }
}

// MARK: - 解析后的最终可用流地址

struct AnimeResolvedStream: Equatable {
    let url: URL
    let headers: [String: String]
    let format: String // "hls", "mp4", etc.
    let title: String
    let qualityTitle: String
    let qualities: [PlaybackQualityItem]
}

// MARK: - 选集身份

/// 一集动漫的稳定身份。
///
/// 解析出的流地址带时效签名，每次解析都不一样，不能拿它当身份：选集会认不出当前这一集，
/// 播放记录也会每播一次多一条。所以播放列表里存的是这个引用，真地址在播放器里现取
/// ——和 115 用 pickCode 当播放源是同一个套路。
struct AnimeEpisodeRef: Identifiable, Hashable, Codable {
    let animeId: Int
    let seriesName: String
    /// 线路代码，例如 newup-jp
    let play: String
    let routeIndex: Int
    /// 集数原文，例如「第01集」
    let part: String

    var id: String { "anime|\(animeId)|\(play)|\(part)" }
    var episodeTitle: String { "\(seriesName) \(part)" }

    /// 记下最后看的一集和线路，回到详情页时选中它。播放器里切集也走这里，
    /// 否则在播放器里连播了几集、退出后详情页还停在最初那一集。
    func rememberAsLastWatched() {
        let defaults = UserDefaults.standard
        defaults.set(part, forKey: "anime.last_episode.\(animeId)")
        defaults.set(routeIndex, forKey: "anime.last_route.\(animeId)")
    }
}

extension AnimeVideoDetail {
    /// 一条线路下的全部集数，按接口给的正序。播放器的选集、上一集/下一集、自动连播都用这一份，
    /// 不受详情页「正序/倒序」显示开关影响——播放器里的格子是按序号标的。
    /// 集数去重：接口偶尔返回重名的一集，重名会让选集列表的 id 撞车、整列表渲染错乱。
    func episodeRefs(routeIndex: Int) -> [AnimeEpisodeRef] {
        let index = parts.indices.contains(routeIndex) ? routeIndex : 0
        guard parts.indices.contains(index) else { return [] }
        let route = parts[index]
        var seen: Set<String> = []
        return route.part.compactMap { part in
            guard !part.isEmpty, seen.insert(part).inserted else { return nil }
            return AnimeEpisodeRef(animeId: id, seriesName: name, play: route.play, routeIndex: index, part: part)
        }
    }
}
