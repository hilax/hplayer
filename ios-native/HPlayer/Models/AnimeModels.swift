import Foundation

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
    let gold: Int?
    let oid: Int?
    let pid: Int?

    var displayTitle: String { vname }
    var displayImage: String { img }
    var displayRemarks: String { continu ?? "" }
    var displayDesc: String {
        (content ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
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
        } else if let num = try? c.decodeIfPresent(Double.self, forKey: .stars) {
            stars = String(num)
        } else if let intVal = try? c.decodeIfPresent(Int.self, forKey: .stars) {
            stars = String(intVal)
        } else {
            stars = nil
        }
    }

    var cleanDesc: String {
        (content ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
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

    enum CodingKeys: String, CodingKey {
        case id, name, source, parts, continu, year, area, type, actor, director, content, stars, pic
        case autoPlay = "auto_play"
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
        autoPlay = try c.decodeIfPresent(Int.self, forKey: .autoPlay)
        pic = try c.decodeIfPresent(String.self, forKey: .pic)

        if let str = try? c.decodeIfPresent(String.self, forKey: .stars) {
            stars = str
        } else if let num = try? c.decodeIfPresent(Double.self, forKey: .stars) {
            stars = String(num)
        } else if let intVal = try? c.decodeIfPresent(Int.self, forKey: .stars) {
            stars = String(intVal)
        } else {
            stars = nil
        }
    }

    var cleanDesc: String {
        (content ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
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
}
